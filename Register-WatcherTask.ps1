<#
.SYNOPSIS
    Registra una Tarea Programada de Windows que ejecuta Watch-FolderToShortcuts.ps1
    de forma oculta cada vez que el usuario inicia sesión, y la mantiene reiniciándose
    si por algún motivo se detiene.

.USO
    1. Copia este archivo y "Watch-FolderToShortcuts.ps1" a la misma carpeta,
       por ejemplo: C:\Scripts\
    2. Ajusta $ScriptPath si lo guardas en otra ruta.
    3. Ejecuta este script UNA VEZ desde una consola de PowerShell como Administrador:
           powershell.exe -ExecutionPolicy Bypass -File .\Register-WatcherTask.ps1
    4. Verifica en el "Programador de tareas" de Windows que la tarea "WatchFolderToShortcuts"
       se creó correctamente.
#>

# Ruta donde se encuentra el script principal (ajústala si es necesario)
$ScriptPath = Join-Path $PSScriptRoot "Watch-FolderToShortcuts.ps1"
$TaskName   = "WatchFolderToShortcuts"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "No se encuentra '$ScriptPath'. Coloca este script en la misma carpeta que Watch-FolderToShortcuts.ps1 o ajusta la variable `$ScriptPath."
}

# Acción: ejecutar PowerShell de forma oculta con el script principal
$pwshExe = (Get-Command powershell.exe).Source
$argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$action = New-ScheduledTaskAction -Execute $pwshExe -Argument $argument

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

Write-Host "Tarea programada '$TaskName' registrada correctamente." -ForegroundColor Green
Write-Host "Se ejecutará automáticamente en el próximo inicio de sesión." -ForegroundColor Green
Write-Host ""
Write-Host "Para iniciarla ahora mismo sin reiniciar sesión, ejecuta:" -ForegroundColor Yellow
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
