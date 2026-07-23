<#
.SYNOPSIS
    Registra una Tarea Programada de Windows que ejecuta Watch-FolderToShortcuts.ps1
    de forma REALMENTE oculta cada vez que el usuario inicia sesión, y la mantiene
    reiniciándose si por algún motivo se detiene.

.NOTAS SOBRE VENTANA OCULTA vs. PROCESOS ZOMBI
    Hay una tensión real entre estas dos cosas en Windows:
      - "-WindowStyle Hidden" pasado directamente a powershell.exe NO oculta nada si tienes
        Windows Terminal como terminal predeterminada (ignora ese parámetro).
      - Lanzar powershell.exe a través de un intermediario .vbs (WScript.Shell.Run con estilo
        de ventana 0) SÍ oculta la ventana de verdad, pero el proceso de PowerShell resultante
        se "escapa" del Job Object que Task Scheduler usa para controlar la tarea — así que
        Stop-ScheduledTask ya NO puede detenerlo por sí solo (queda como "zombi").
    Aquí se prioriza la ventana oculta (vía .vbs) y se soluciona el problema de los zombis de
    otra forma: Watch-FolderToShortcuts.ps1 escribe su propio PID en "watcher.pid" nada más
    arrancar, y el script "Stop-Watcher.ps1" (generado aquí también) usa ese PID para matar el
    proceso real de forma explícita. A partir de ahora, usa SIEMPRE Stop-Watcher.ps1 para parar
    el watcher, no Stop-ScheduledTask a secas.

.USO
    1. Copia este archivo y "Watch-FolderToShortcuts.ps1" a la misma carpeta.
    2. Ejecuta este script UNA VEZ desde una consola de PowerShell como Administrador:
           powershell.exe -ExecutionPolicy Bypass -File .\Register-WatcherTask.ps1
    3. Verifica en el "Programador de tareas" de Windows que la tarea "WatchFolderToShortcuts"
       se creó correctamente.
#>

# Ruta donde se encuentra el script principal (ajústala si es necesario)
$ScriptPath = Join-Path $PSScriptRoot "Watch-FolderToShortcuts.ps1"
$VbsPath    = Join-Path $PSScriptRoot "Launch-Hidden.vbs"
$PidFile    = Join-Path $PSScriptRoot "watcher.pid"
$TaskName   = "WatchFolderToShortcuts"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "No se encuentra '$ScriptPath'. Coloca este script en la misma carpeta que Watch-FolderToShortcuts.ps1 o ajusta la variable `$ScriptPath."
}

$pwshExe = (Get-Command powershell.exe).Source

# Lanzador .vbs: objShell.Run(comando, 0, True) -> 0 = ventana oculta; True = esperar a que
# termine (así wscript.exe se queda "vivo" mientras el watcher corra, y la tarea programada
# se mantiene en estado "en ejecución" en vez de darse por completada al instante).
$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$ScriptPath""", 0, True
"@
Set-Content -LiteralPath $VbsPath -Value $vbsContent -Encoding ASCII

# Genera también Stop-Watcher.ps1: la forma FIABLE de parar el watcher a partir de ahora.
$stopScriptContent = @'
<#
.SYNOPSIS
    Detiene el watcher de forma fiable: para la tarea programada Y mata el proceso real
    de PowerShell (que el lanzador .vbs hace que se escape del control de Task Scheduler).
.USO
    powershell.exe -ExecutionPolicy Bypass -File .\Stop-Watcher.ps1
#>
$TaskName = "WatchFolderToShortcuts"
$PidFile  = Join-Path $PSScriptRoot "watcher.pid"

Write-Host "Deteniendo la tarea programada..." -ForegroundColor Yellow
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 500

$killedAny = $false

# 1. Mata el proceso registrado en watcher.pid (forma principal y más precisa)
if (Test-Path -LiteralPath $PidFile) {
    $storedPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
    if ($storedPid) {
        $proc = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Matando proceso real del watcher (PID $storedPid)..." -ForegroundColor Yellow
            Stop-Process -Id $storedPid -Force -ErrorAction SilentlyContinue
            $killedAny = $true
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

# 2. Red de seguridad: por si quedó alguna instancia suelta de ejecuciones manuales anteriores
$strays = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*Watch-FolderToShortcuts.ps1*" }
foreach ($s in $strays) {
    Write-Host "Matando instancia suelta encontrada (PID $($s.ProcessId))..." -ForegroundColor Yellow
    Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue
    $killedAny = $true
}

if ($killedAny) {
    Write-Host "Watcher detenido completamente, sin procesos residuales." -ForegroundColor Green
} else {
    Write-Host "No se encontró ningún proceso del watcher corriendo (ya estaba parado)." -ForegroundColor Green
}
'@
$StopScriptPath = Join-Path $PSScriptRoot "Stop-Watcher.ps1"
Set-Content -LiteralPath $StopScriptPath -Value $stopScriptContent -Encoding UTF8

# Acción: ejecutar el lanzador .vbs (mediante wscript.exe) en vez de powershell.exe directamente
$wscriptExe = (Get-Command wscript.exe).Source
$action = New-ScheduledTaskAction -Execute $wscriptExe -Argument "`"$VbsPath`""

# Disparador: al iniciar sesión el usuario actual
$trigger = New-ScheduledTaskTrigger -AtLogOn

# Configuración: reintentar si falla, no detener si pasa mucho tiempo (tarea de larga duración)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)   # sin límite de tiempo de ejecución

# Principal: se ejecuta con los privilegios del usuario que inicia sesión (no requiere ser Admin para correr)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

# Registrar (o actualizar si ya existe)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description "Monitoriza carpeta A y crea accesos directos en carpeta B" `
    -Force

Write-Host "Tarea programada '$TaskName' registrada correctamente (lanzador oculto: $VbsPath)." -ForegroundColor Green
Write-Host "A PARTIR DE AHORA, usa Stop-Watcher.ps1 para detenerla (no Stop-ScheduledTask a secas)." -ForegroundColor Cyan
Write-Host ""
Write-Host "Para iniciarla ahora mismo sin reiniciar sesión, ejecuta:" -ForegroundColor Yellow
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Para detenerla de forma fiable (sin dejar zombis):" -ForegroundColor Yellow
Write-Host "    powershell.exe -ExecutionPolicy Bypass -File `"$StopScriptPath`""

# ============================================================
# ======  TAREA 2: reinicio semanal automático  ==============
# ============================================================
$EnableWeeklyRestart = $true
$RestartDayOfWeek    = "Sunday"
$RestartTime         = "04:00"
$RestartTaskName     = "WatchFolderToShortcuts-WeeklyRestart"

if ($EnableWeeklyRestart) {

    # El reinicio semanal usa el propio Stop-Watcher.ps1 (fiable) en vez de solo Stop-ScheduledTask
    $RestartScriptPath = Join-Path $PSScriptRoot "Restart-WatcherTask.ps1"
    $restartScriptContent = @"
# Generado automáticamente por Register-WatcherTask.ps1.
& "$StopScriptPath"
Start-Sleep -Seconds 5
Start-ScheduledTask -TaskName "$TaskName"
"@
    Set-Content -LiteralPath $RestartScriptPath -Value $restartScriptContent -Encoding UTF8

    $RestartVbsPath = Join-Path $PSScriptRoot "Restart-Hidden.vbs"
    $restartVbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$RestartScriptPath""", 0, True
"@
    Set-Content -LiteralPath $RestartVbsPath -Value $restartVbsContent -Encoding ASCII

    $restartAction  = New-ScheduledTaskAction -Execute $wscriptExe -Argument "`"$RestartVbsPath`""
    $restartTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $RestartDayOfWeek -At $RestartTime
    $restartSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $RestartTaskName -Action $restartAction -Trigger $restartTrigger `
        -Settings $restartSettings -Principal $principal `
        -Description "Reinicia semanalmente $TaskName para recargar title-aliases.json" `
        -Force | Out-Null

    Write-Host ""
    Write-Host "Reinicio automático semanal configurado: cada $RestartDayOfWeek a las $RestartTime." -ForegroundColor Green
}