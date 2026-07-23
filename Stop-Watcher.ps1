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

# 1. Mata el proceso registrado en watcher.pid (forma principal y mÃ¡s precisa)
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

# 2. Red de seguridad: por si quedÃ³ alguna instancia suelta de ejecuciones manuales anteriores
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
    Write-Host "No se encontrÃ³ ningÃºn proceso del watcher corriendo (ya estaba parado)." -ForegroundColor Green
}
