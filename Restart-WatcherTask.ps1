# Generado automÃ¡ticamente por Register-WatcherTask.ps1. Para y reinicia la tarea principal
# para que recargue title-aliases.json (y cualquier otro cambio de configuraciÃ³n).
Stop-ScheduledTask -TaskName "WatchFolderToShortcuts" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Start-ScheduledTask -TaskName "WatchFolderToShortcuts"
