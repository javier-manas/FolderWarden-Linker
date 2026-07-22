<#
.SYNOPSIS
    Registra una Tarea Programada de Windows que ejecuta Watch-FolderToShortcuts.ps1
    de forma REALMENTE oculta cada vez que el usuario inicia sesión, y la mantiene
    reiniciándose si por algún motivo se detiene.

.NOTAS SOBRE LA VENTANA OCULTA
    Pasar "-WindowStyle Hidden" directamente a powershell.exe no siempre oculta la ventana:
    si tienes Windows Terminal configurado como terminal predeterminada (habitual en Windows 11
    reciente), Windows Terminal puede ignorar ese parámetro y mostrar la consola igualmente.
    Para evitarlo, aquí se genera un pequeño lanzador "Launch-Hidden.vbs" que usa
    WScript.Shell.Run con estilo de ventana 0 (oculta) — este método sí oculta la ventana
    de verdad, sin depender de la terminal predeterminada del sistema. La tarea programada
    ejecuta ese .vbs (vía wscript.exe) en vez de llamar a powershell.exe directamente.

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
$TaskName   = "WatchFolderToShortcuts"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "No se encuentra '$ScriptPath'. Coloca este script en la misma carpeta que Watch-FolderToShortcuts.ps1 o ajusta la variable `$ScriptPath."
}

# Genera el lanzador .vbs, con la ruta del script ya incrustada.
# objShell.Run(comando, 0, False) -> 0 = ventana oculta; False = no esperar a que termine.
$pwshExe = (Get-Command powershell.exe).Source
$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$ScriptPath""", 0, False
"@
Set-Content -LiteralPath $VbsPath -Value $vbsContent -Encoding ASCII

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
Write-Host "Se ejecutará automáticamente en el próximo inicio de sesión, sin ventana visible." -ForegroundColor Green
Write-Host ""
Write-Host "Para iniciarla ahora mismo sin reiniciar sesión, ejecuta:" -ForegroundColor Yellow
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"

# ============================================================
# ======  TAREA 2: reinicio semanal automático  ==============
# ============================================================
# Objetivo: recargar title-aliases.json sin que tengas que parar/arrancar el script a mano
# cada vez que añades una nueva equivalencia de título.
# Es una tarea aparte, muy corta (para, espera 5s, arranca) y también oculta.

$EnableWeeklyRestart = $true          # Pon en $false si no quieres este reinicio automático
$RestartDayOfWeek    = "Sunday"       # Día de la semana para el reinicio
$RestartTime         = "04:00"        # Hora (poco uso previsible), formato 24h "HH:mm"
$RestartTaskName     = "WatchFolderToShortcuts-WeeklyRestart"

if ($EnableWeeklyRestart) {

    # Pequeño script que para y vuelve a arrancar la tarea principal
    $RestartScriptPath = Join-Path $PSScriptRoot "Restart-WatcherTask.ps1"
    $restartScriptContent = @"
# Generado automáticamente por Register-WatcherTask.ps1. Para y reinicia la tarea principal
# para que recargue title-aliases.json (y cualquier otro cambio de configuración).
Stop-ScheduledTask -TaskName "$TaskName" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Start-ScheduledTask -TaskName "$TaskName"
"@
    Set-Content -LiteralPath $RestartScriptPath -Value $restartScriptContent -Encoding UTF8

    # Lanzador oculto para este script de reinicio (mismo motivo que Launch-Hidden.vbs)
    $RestartVbsPath = Join-Path $PSScriptRoot "Restart-Hidden.vbs"
    $restartVbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$RestartScriptPath""", 0, True
"@
    # Nota: el último parámetro es True (esperar a que termine) para que la tarea programada
    # no se marque como "finalizada" antes de que el reinicio se haya completado de verdad.
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
    Write-Host "Para desactivarlo: Unregister-ScheduledTask -TaskName '$RestartTaskName' -Confirm:`$false" -ForegroundColor Yellow
}