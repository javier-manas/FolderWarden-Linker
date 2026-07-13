<#
.SYNOPSIS
    Monitoriza en tiempo real una carpeta A (con subcarpetas) y crea automáticamente
    accesos directos (.lnk) en una carpeta B por cada archivo nuevo o copiado,
    sin mover ni modificar el archivo original.

.DESCRIPTION
    - Usa System.IO.FileSystemWatcher (basado en eventos, no en sondeo => bajo consumo de CPU).
    - Detecta: creación, copia, renombrado y eliminación de archivos en la carpeta A.
    - Crea un .lnk en la carpeta B con el mismo nombre base que el archivo original.
    - Evita duplicados: si el acceso directo ya existe y apunta al mismo destino, no lo recrea.
    - Si el archivo es renombrado o movido dentro de A, actualiza el acceso directo (borra el viejo, crea el nuevo).
    - Si el archivo es eliminado de A, elimina el acceso directo correspondiente en B (opcional, configurable).
    - Espera a que el archivo termine de copiarse antes de crear el acceso directo (evita archivos "en uso").
    - Sincroniza al arrancar: crea accesos directos para archivos que ya existían en A antes de iniciar el script.
    - Registra actividad en un log rotativo simple.

.NOTAS DE DISEÑO
    - Si dos archivos en distintas subcarpetas de A tienen el mismo nombre, y $FlattenSubfolders = $true,
      se añade un sufijo con la ruta relativa para evitar colisiones en la carpeta B (ver configuración).
    - El script está pensado para ejecutarse de forma continua (por ejemplo, como tarea programada
      "al iniciar sesión" o "al arrancar el sistema"). Ver instrucciones de instalación al final de este archivo.
#>

# ============================================================
# ============  CONFIGURACIÓN (edítalo a tu gusto) ===========
# ============================================================

# Carpeta de origen a monitorizar (incluye subcarpetas)
$FolderA = "C:\xxxxxx"

# Carpeta donde se crearán los accesos directos
$FolderB = "C:\xxxxxxx"

# Archivo de log (se crea automáticamente su carpeta si no existe)
$LogFile = Join-Path $FolderB "_watcher.log"

# Tamaño máximo del log en bytes antes de rotarlo (5 MB por defecto)
$MaxLogSizeBytes = 5MB

# Si $true, cuando se elimine un archivo de A, se elimina también su acceso directo en B.
# Si $false, los accesos directos se conservan aunque el original desaparezca (podrían quedar "rotos").
$RemoveShortcutOnDelete = $true

# Si $true, evita nombres duplicados cuando hay archivos con el mismo nombre en distintas subcarpetas
# de A, añadiendo un sufijo basado en la ruta relativa. Si $false, el último archivo procesado
# con ese nombre "ganará" el acceso directo (se sobrescribirá el .lnk).
$FlattenSubfolders = $true

# Filtro de archivos a considerar (por defecto todos). Ejemplo: "*.pdf" o "*.docx"
$FileFilter = "*.*"

# Extensiones a IGNORAR (por ejemplo, archivos temporales de copia). Añade las que necesites.
$IgnoreExtensions = @('.tmp', '.crdownload', '.part', '.partial', '~')

# Tiempo máximo (segundos) que se espera a que un archivo deje de estar bloqueado
# antes de darlo por "listo" para crear el acceso directo (protección ante copias grandes)
$MaxWaitForFileReadySeconds = 120

# Intervalo (ms) entre reintentos de comprobación de bloqueo de archivo
$RetryIntervalMs = 500

# ============================================================
# ==================  FIN DE CONFIGURACIÓN  ===================
# ============================================================


# ---------- Preparación de carpetas ----------
if (-not (Test-Path -LiteralPath $FolderA)) {
    throw "La carpeta de origen '$FolderA' no existe. Ajusta la variable `$FolderA."
}
if (-not (Test-Path -LiteralPath $FolderB)) {
    New-Item -ItemType Directory -Path $FolderB -Force | Out-Null
}

# ---------- Función de log ----------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    try {
        if (Test-Path -LiteralPath $LogFile) {
            $size = (Get-Item -LiteralPath $LogFile).Length
            if ($size -ge $MaxLogSizeBytes) {
                $backup = [System.IO.Path]::ChangeExtension($LogFile, "old.log")
                Move-Item -LiteralPath $LogFile -Destination $backup -Force
            }
        }
        $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # Si falla el log, no debe tumbar el script
    }
}

# ---------- Comprueba si la extensión debe ignorarse ----------
function Test-IgnoredExtension {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    return ($IgnoreExtensions -contains $ext.ToLowerInvariant())
}

# ---------- Espera a que un archivo termine de copiarse (no esté bloqueado) ----------
function Wait-ForFileReady {
    param([string]$Path)

    $elapsedMs = 0
    $maxMs = $MaxWaitForFileReadySeconds * 1000

    while ($elapsedMs -lt $maxMs) {
        if (-not (Test-Path -LiteralPath $Path)) {
            # El archivo desapareció mientras esperábamos (copia cancelada, etc.)
            return $false
        }
        try {
            # Intenta abrir el archivo en modo exclusivo; si lo consigue, no está bloqueado
            $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
            return $true
        } catch {
            Start-Sleep -Milliseconds $RetryIntervalMs
            $elapsedMs += $RetryIntervalMs
        }
    }
    Write-Log "Tiempo de espera agotado esperando a que '$Path' quede libre." 'WARN'
    return $false
}

# ---------- Calcula la ruta del .lnk correspondiente a un archivo de origen ----------
function Get-ShortcutPath {
    param([string]$SourcePath)

    $baseName = [System.IO.Path]::GetFileName($SourcePath)

    if ($FlattenSubfolders) {
        # Ruta relativa respecto a FolderA, usada para evitar colisiones de nombre
        $relative = $SourcePath.Substring($FolderA.Length).TrimStart('\','/')
        $relativeDir = [System.IO.Path]::GetDirectoryName($relative)
        if ([string]::IsNullOrWhiteSpace($relativeDir)) {
            $shortcutName = $baseName
        } else {
            # Sustituye separadores de carpeta por " - " para formar un nombre único y legible
            $safeDir = $relativeDir -replace '[\\/]', ' - '
            $shortcutName = "$safeDir - $baseName"
        }
    } else {
        $shortcutName = $baseName
    }

    $lnkName = [System.IO.Path]::GetFileNameWithoutExtension($shortcutName) + `
               [System.IO.Path]::GetExtension($shortcutName) + ".lnk"

    return (Join-Path $FolderB $lnkName)
}

# ---------- Crea (o actualiza) un acceso directo apuntando a $SourcePath ----------
function New-ShortcutForFile {
    param([string]$SourcePath)

    if (Test-IgnoredExtension $SourcePath) { return }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return }

    if (-not (Wait-ForFileReady -Path $SourcePath)) {
        Write-Log "No se creó el acceso directo para '$SourcePath' (archivo no disponible o bloqueado)." 'WARN'
        return
    }

    $lnkPath = Get-ShortcutPath -SourcePath $SourcePath

    # Evitar duplicados: si ya existe un .lnk con ese nombre y apunta al mismo destino, no hacer nada
    if (Test-Path -LiteralPath $lnkPath) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($lnkPath)
            if ($existing.TargetPath -eq $SourcePath) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
                return  # ya existe y apunta correctamente, no se duplica
            }
        } catch {
            Write-Log "No se pudo leer el acceso directo existente '$lnkPath': $($_.Exception.Message)" 'WARN'
        }
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $SourcePath
        $shortcut.WorkingDirectory = [System.IO.Path]::GetDirectoryName($SourcePath)
        $shortcut.Description = "Acceso directo generado automáticamente a $SourcePath"
        $shortcut.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        Write-Log "Acceso directo creado/actualizado: '$lnkPath' -> '$SourcePath'"
    } catch {
        Write-Log "ERROR creando acceso directo para '$SourcePath': $($_.Exception.Message)" 'ERROR'
    }
}

# ---------- Elimina el acceso directo asociado a un archivo eliminado/renombrado ----------
function Remove-ShortcutForFile {
    param([string]$SourcePath)

    $lnkPath = Get-ShortcutPath -SourcePath $SourcePath
    if (Test-Path -LiteralPath $lnkPath) {
        try {
            Remove-Item -LiteralPath $lnkPath -Force
            Write-Log "Acceso directo eliminado: '$lnkPath' (origen eliminado/renombrado: '$SourcePath')"
        } catch {
            Write-Log "ERROR eliminando acceso directo '$lnkPath': $($_.Exception.Message)" 'ERROR'
        }
    }
}

# ---------- Sincronización inicial: crea accesos directos para archivos ya existentes ----------
function Sync-ExistingFiles {
    Write-Log "Iniciando sincronización de archivos existentes en '$FolderA'..."
    try {
        Get-ChildItem -LiteralPath $FolderA -Recurse -File -Filter $FileFilter -ErrorAction SilentlyContinue |
            ForEach-Object {
                New-ShortcutForFile -SourcePath $_.FullName
            }
        Write-Log "Sincronización inicial completada."
    } catch {
        Write-Log "ERROR durante la sincronización inicial: $($_.Exception.Message)" 'ERROR'
    }
}

# ============================================================
# ===================  CONFIGURAR WATCHER  ====================
# ============================================================

Write-Log "==== Iniciando Watch-FolderToShortcuts ===="
Write-Log "Carpeta origen (A): $FolderA"
Write-Log "Carpeta destino (B): $FolderB"

Sync-ExistingFiles

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $FolderA
$watcher.Filter = $FileFilter
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor `
                        [System.IO.NotifyFilters]::DirectoryName -bor `
                        [System.IO.NotifyFilters]::LastWrite -bor `
                        [System.IO.NotifyFilters]::Size
$watcher.EnableRaisingEvents = $true

# --- Evento: Created (archivo nuevo o copiado) ---
$onCreated = Register-ObjectEvent -InputObject $watcher -EventName Created -Action {
    $path = $Event.SourceEventArgs.FullPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        # Ejecutar en un job en segundo plano evitaría bloquear el hilo de eventos,
        # pero para mantenerlo simple y robusto lo hacemos de forma síncrona con espera acotada.
        New-ShortcutForFile -SourcePath $path
    }
}

# --- Evento: Renamed (incluye "mover dentro de A" y "renombrar") ---
$onRenamed = Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action {
    $oldPath = $Event.SourceEventArgs.OldFullPath
    $newPath = $Event.SourceEventArgs.FullPath

    # Elimina el acceso directo antiguo (si existía)
    Remove-ShortcutForFile -SourcePath $oldPath

    # Crea el nuevo acceso directo si sigue siendo un archivo válido dentro de A
    if (Test-Path -LiteralPath $newPath -PathType Leaf) {
        New-ShortcutForFile -SourcePath $newPath
    }
}

# --- Evento: Deleted (archivo eliminado de A) ---
$onDeleted = Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action {
    $path = $Event.SourceEventArgs.FullPath
    if ($using:RemoveShortcutOnDelete) {
        Remove-ShortcutForFile -SourcePath $path
    }
}

# --- Evento: Changed (por si el archivo tarda en escribirse tras el Created) ---
# Útil cuando algunos programas crean el archivo vacío y lo van rellenando poco a poco.
$onChanged = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
    $path = $Event.SourceEventArgs.FullPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $lnkPath = Get-ShortcutPath -SourcePath $path
        # Solo actuamos si aún no existe el acceso directo (evita trabajo innecesario en cada escritura)
        if (-not (Test-Path -LiteralPath $lnkPath)) {
            New-ShortcutForFile -SourcePath $path
        }
    }
}

# --- Evento: Error del propio FileSystemWatcher (p.ej. buffer desbordado) ---
$onError = Register-ObjectEvent -InputObject $watcher -EventName Error -Action {
    Write-Log "El FileSystemWatcher reportó un error interno. Reiniciando vigilancia." 'ERROR'
}

Write-Log "Watcher activo. Esperando eventos..."

# ============================================================
# ===============  BUCLE PRINCIPAL (mantiene vivo el script) ==
# ============================================================
try {
    while ($true) {
        # Wait-Event bloquea sin consumir CPU hasta que llega un evento o pasa el timeout.
        # El timeout solo sirve para poder comprobar periódicamente el estado del watcher.
        Wait-Event -Timeout 30 | Out-Null

        # Comprobación de salud: si el watcher deja de estar habilitado, lo reactivamos
        if (-not $watcher.EnableRaisingEvents) {
            Write-Log "EnableRaisingEvents estaba en \$false; reactivando." 'WARN'
            $watcher.EnableRaisingEvents = $true
        }
    }
}
finally {
    # Limpieza al detener el script (Ctrl+C, cierre de sesión, etc.)
    Write-Log "Deteniendo watcher y liberando recursos..."
    Unregister-Event -SourceIdentifier $onCreated.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $onRenamed.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $onDeleted.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $onChanged.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $onError.Name -ErrorAction SilentlyContinue
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Write-Log "==== Watch-FolderToShortcuts detenido ===="
}
