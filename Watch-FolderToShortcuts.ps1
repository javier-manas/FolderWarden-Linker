<#
.SYNOPSIS
    Monitoriza en tiempo real una carpeta A (con subcarpetas) y crea automáticamente
    accesos directos (.lnk) en una carpeta B por cada archivo nuevo o copiado,
    sin mover ni modificar el archivo original.

.DESCRIPTION
    - Usa System.IO.FileSystemWatcher (basado en eventos, no en sondeo => bajo consumo de CPU).
    - Detecta: creación, copia, renombrado y eliminación de archivos en la carpeta A.
    - Agrupa los accesos directos por "obra" (película/serie/anime/juego) dentro de carpeta B:
        * Si el archivo está dentro de una subcarpeta de A (A\Naruto\ep01.mkv), se usa el nombre
          de esa subcarpeta de primer nivel, limpiado de tags de resolución/codec/temporada/etc.,
          como nombre de la carpeta de obra en B (sin recrear subcarpetas de temporada).
        * Si el archivo está suelto directamente en A (A\The.Matrix.1999.mkv), se aplica la misma
          limpieza heurística sobre el propio nombre de archivo para deducir el título de la obra.
        * Títulos parecidos pero no idénticos tras la limpieza (ej. "Naruto" vs "Naruto Shippuden")
          se tratan como obras DISTINTAS (carpetas separadas), no se fusionan.
    - Crea un .lnk en la subcarpeta de obra correspondiente, con el mismo nombre base que el archivo original.
    - Evita duplicados: si el acceso directo ya existe y apunta al mismo destino, no lo recrea.
    - Si el archivo es renombrado o movido dentro de A, actualiza el acceso directo (borra el viejo, crea el nuevo).
    - Si el archivo es eliminado de A, elimina el acceso directo correspondiente en B (opcional, configurable),
      y si la carpeta de obra queda vacía, también se elimina.
    - Espera a que el archivo termine de copiarse antes de crear el acceso directo (evita archivos "en uso").
    - Sincroniza al arrancar: crea accesos directos para archivos que ya existían en A antes de iniciar el script.
    - Registra actividad en un log rotativo simple.

.NOTAS DE DISEÑO
    - La detección de título es heurística (basada en expresiones regulares), no usa ninguna base de
      datos externa (TMDB/AniList/IGDB). Funciona bien con nombres de "scene release" habituales, pero
      puede fallar con nombres muy atípicos; en ese caso se usa el nombre original tal cual.
    - Regla clave: se descarta TODO lo que va después del primer " - " del nombre (número de episodio,
      título de episodio o tags técnicos como "CR AAC2.0 H.264"). Así, episodios con título propio en
      vez de número (habitual en anime) se agrupan correctamente con el resto de la serie.
    - Si dentro de una misma carpeta de obra hay archivos con el mismo nombre en distintas subcarpetas
      de A (ej. distintas temporadas), y $FlattenSubfolders = $true, se añade un prefijo con la ruta
      relativa restante para evitar colisiones de nombre del .lnk (ver configuración).
    - El script está pensado para ejecutarse de forma continua (por ejemplo, como tarea programada
      "al iniciar sesión" o "al arrancar el sistema"). Ver instrucciones de instalación al final de este archivo.
#>

# ============================================================
# ============  CONFIGURACIÓN (edítalo a tu gusto) ===========
# ============================================================

# Carpeta de origen a monitorizar (incluye subcarpetas)
$FolderA = "xxx"

# Carpeta donde se crearán los accesos directos
$FolderB = "xxx"

# Archivo de log (se crea automáticamente su carpeta si no existe)
$LogFile = Join-Path $FolderB "_watcher.log"

# Tamaño máximo del log en bytes antes de rotarlo (5 MB por defecto)
$MaxLogSizeBytes = 5MB

# Si $true, cuando se elimine un archivo de A, se elimina también su acceso directo en B.
# Si $false, los accesos directos se conservan aunque el original desaparezca (podrían quedar "rotos").
$RemoveShortcutOnDelete = $true

# Si $true, evita nombres duplicados cuando, DENTRO DE LA MISMA CARPETA DE OBRA, hay archivos con el
# mismo nombre en distintas subcarpetas de A (por ejemplo, distintas temporadas), añadiendo un prefijo
# basado en la ruta relativa restante (ej. "Season 1 - 01.mkv.lnk"). Si $false, el último archivo
# procesado con ese nombre "ganará" el acceso directo (se sobrescribirá el .lnk).
$FlattenSubfolders = $true

# Si $true, cuando se elimina el último acceso directo de una carpeta de obra, se borra también
# esa carpeta (si queda vacía). Si $false, las carpetas de obra vacías se conservan.
$RemoveEmptyWorkFolders = $true

# El criterio PRINCIPAL para deducir el título es buscar el primer marcador de episodio
# (S04E09, 1x01, "Episodio 12"...) y descartar todo lo que va desde ahí en adelante.
# Este ajuste solo controla el criterio de RESERVA para series que numeran episodios con un
# guion en vez de SxxEyy (ej. "Naruto - 001" o "Serie - Título del episodio"), o si el
# marcador de episodio no aparece. Si $true (recomendado), se descarta también todo lo que
# va tras el primer " - ". Si tienes películas sueltas con subtítulo real que SÍ quieres
# conservar completo (p. ej. "Blade Runner - The Final Cut") y no tienen marcador de episodio,
# pon esto en $false.
$SplitTitleAtFirstDash = $true

# Ruta del archivo de alias manuales de títulos (JSON). Aquí defines equivalencias que NINGUNA
# regex puede deducir por sí sola: título japonés/romaji vs. título oficial en inglés, títulos con
# puntuación muy distinta entre grupos de release, etc. Si el archivo no existe, se crea
# automáticamente con un ejemplo (Re:Zero) la primera vez que se ejecuta el script.
# Los cambios en este archivo solo se aplican a partir del siguiente arranque del script.
$TitleAliasMapPath = Join-Path $PSScriptRoot "title-aliases.json"

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

# ---------- Limpia un nombre de archivo/carpeta de "scene release" para deducir el título de la obra ----------
# Heurística basada en expresiones regulares (sin consultas externas). No es infalible: nombres muy
# atípicos pueden no limpiarse del todo, en cuyo caso se devuelve el nombre original.
function Get-CleanTitle {
    param([string]$RawName)

    $name = $RawName

    # Normaliza separadores típicos de "scene naming" (puntos, guiones bajos) a espacios
    $name = $name -replace '[\._]', ' '

    # Elimina contenido entre corchetes/llaves (hashes, grupos de release, tags de audio, etc.)
    $name = $name -replace '\[[^\]]*\]', ' '
    $name = $name -replace '\{[^\}]*\}', ' '
    $name = $name -replace '\([^\)]*\)', ' '   # paréntesis: suelen contener año/tags, no forman parte del título

    # ---- CORTE PRINCIPAL: se busca el primer marcador de episodio (S04E09, 1x01, Episodio 12...) ----
    # y se descarta TODO lo que hay desde ahí en adelante (número/título de episodio + tags técnicos).
    # Esto es muchísimo más fiable que cortar por un guion, porque en el naming tipo scene-release
    # (con puntos como separador: "Serie.S03E06.Titulo.Episodio.1080p...") no hay ningún " - ".
    # Ejemplos reales:
    #   "Jujutsu Kaisen S03E06 Cog 1080p NF WEB-DL..."      -> corta en "S03E06" -> "Jujutsu Kaisen"
    #   "Jujutsu Kaisen S03E01 Execution 1080p NF WEB-DL..." -> corta en "S03E01" -> "Jujutsu Kaisen"
    # Ambos dan el MISMO título, así que acaban en la misma carpeta de obra.
    $episodeMarkerPattern = '(?i)\bS\d{1,2}\s*E\d{1,3}\b|\b\d{1,2}x\d{2,3}\b|\b(Episodio|Episode|Ep\.?|Cap[ií]tulo|Cap\.?)\s*\d{1,4}\b'
    $marker = [regex]::Match($name, $episodeMarkerPattern)

    if ($marker.Success -and $marker.Index -gt 0) {
        $name = $name.Substring(0, $marker.Index)
    }
    elseif ($SplitTitleAtFirstDash -and $name -match '^(.+?)\s-\s.+$') {
        # Fallback para series que numeran episodios sin SxxEyy, tipo "Naruto - 001" o
        # "Serie - Título del episodio" (convención con guion en vez de marcador de temporada).
        $name = $Matches[1]
    }

    # A partir de aquí, limpieza adicional como red de seguridad para nombres SIN marcador de episodio
    # NI guion (ej. películas sueltas: "The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv").

    # Por si ha quedado algún marcador de temporada/episodio suelto (nombres atípicos, o carpetas ya limpias)
    $name = $name -replace '(?i)\bS\d{1,2}\s*E\d{1,3}\b', ' '
    $name = $name -replace '(?i)\b\d{1,2}x\d{1,3}\b', ' '
    $name = $name -replace '(?i)\bSeason\s*\d{1,2}\b', ' '
    $name = $name -replace '(?i)\bTemporada\s*\d{1,2}\b', ' '
    $name = $name -replace '(?i)\b(Episodio|Episode|Ep\.?|Cap[ií]tulo|Cap\.?)\s*\d{1,4}\b', ' '
    $name = $name -replace '(?i)\bE\d{2,4}\b', ' '

    # Elimina sufijos de "entrega" de una misma obra (habituales en anime: distintas temporadas
    # anunciadas con texto en vez de con SxxEyy). Esto es lo que fusiona, por ejemplo,
    # "Re Zero kara Hajimeru Isekai Seikatsu" y "Re Zero kara Hajimeru Isekai Seikatsu 4th Season"
    # en la MISMA carpeta de obra.
    $name = $name -replace '(?i)\b(\d+(st|nd|rd|th)|final|first|second|third|last|new)\s+season\b', ' '
    $name = $name -replace '(?i)\bpart\s*\d{1,2}\b', ' '
    $name = $name -replace '(?i)\bcour\s*\d{1,2}\b', ' '

    # Elimina un número "suelto" al final (típico marcador de episodio: "Naruto 001")
    $name = $name -replace '(?:^|\s|-)\d{1,4}\s*$', ' '

    # Elimina año entre paréntesis o suelto (1900-2099)
    $name = $name -replace '\(?(19|20)\d{2}\)?', ' '

    # Elimina calidad / resolución
    $name = $name -replace '(?i)\b(480p|720p|1080p|1440p|2160p|4k|8k|uhd|hdr10?|sdr)\b', ' '

    # Elimina fuente de vídeo / plataformas de streaming habituales en releases
    $name = $name -replace '(?i)\b(blu-?ray|bdrip|brrip|webrip|web-?dl|hdtv|dvdrip|hdrip|camrip|hdcam|dvdscr)\b', ' '
    $name = $name -replace '(?i)\b(CR|Crunchyroll|Funi(mation)?|NF|Netflix|AMZN|Amazon|DSNP|Disney\+?|HULU|HMAX|ATVP|AppleTV\+?|PCOK|Peacock|iP|iPlayer)\b', ' '

    # Elimina códecs de vídeo/audio y bit depth (tolerante a puntos/espacios: "H.264", "H 264", "AAC2.0", "AAC2 0")
    $name = $name -replace '(?i)\b(x264|x265|h\.?264|h\.?265|hevc|avc|xvid|divx)\b', ' '
    $name = $name -replace '(?i)\b(e-?ac-?3|ddp?[\s]?5[\s.]?1|dts(-?hd)?|aac(\s?\d(\s?[.\s]?\d)?)?|ac3|mp3|flac(\s?\d(\s?[.\s]?\d)?)?)\b', ' '
    $name = $name -replace '(?i)\b(10\s?bit|8\s?bit)\b', ' '

    # Elimina indicadores de idioma/subtítulos/doblaje comunes
    $name = $name -replace '(?i)\b(dual( audio)?|latino|castellano|subtitulado|subs?|vose|vost|dubbed|multi)\b', ' '

    # Elimina lo que quede tras un guion final (normalmente el grupo de release, ej. "-NTG", "-RARBG")
    $name = $name -replace '-\s*[A-Za-z0-9]{2,15}\s*$', ' '

    # Colapsa espacios múltiples y recorta separadores sueltos en los extremos
    $name = $name -replace '\s{2,}', ' '
    $name = $name.Trim(' ', '-', '_', '.')

    if ([string]::IsNullOrWhiteSpace($name)) {
        return $RawName.Trim()
    }
    return $name
}

# ---------- Quita caracteres no válidos para nombres de carpeta/archivo en Windows ----------
function Get-SafeName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [System.Text.RegularExpressions.Regex]::Escape($invalid)
    $safe = $Name -replace $pattern, ' '
    $safe = ($safe -replace '\s{2,}', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { return "Sin titulo" }
    return $safe
}

# ---------- Normaliza un título a una "clave de comparación": minúsculas y solo letras/números ----------
# Ignora mayúsculas, espacios, guiones, dos puntos, apóstrofos, etc. Esto es lo que permite que
# "ReZero Starting Life in Another World" y "ReZERO -Starting Life in Another World" se
# reconozcan como EL MISMO título aunque su escritura difiera.
function Get-NormalizedKey {
    param([string]$Text)
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# ---------- Carga (o crea) el archivo de alias manuales de títulos ----------
# Devuelve un hashtable: clave normalizada de cada alias -> nombre canónico de carpeta.
function Import-TitleAliasMap {
    param([string]$Path)

    $map = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        # Primera ejecución: se crea el archivo con un ejemplo real y funcional (caso Re:Zero),
        # para que sirva de plantilla y quede documentado el formato esperado.
        $example = @(
            @{
                canonical = "Re Zero kara Hajimeru Isekai Seikatsu"
                aliases   = @(
                    "Re Zero kara Hajimeru Isekai Seikatsu",
                    "ReZero Starting Life in Another World",
                    "ReZERO Starting Life in Another World",
                    "ReZERO -Starting Life in Another World-",
                    "Re Zero Starting Life in Another World"
                )
            }
        )
        try {
            $example | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
            Write-Log "Archivo de alias de títulos creado con un ejemplo en '$Path'."
        } catch {
            Write-Log "No se pudo crear el archivo de alias '$Path': $($_.Exception.Message)" 'WARN'
            return $map
        }
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $json) {
            $canonical = $entry.canonical
            if ([string]::IsNullOrWhiteSpace($canonical)) { continue }
            foreach ($alias in $entry.aliases) {
                if ([string]::IsNullOrWhiteSpace($alias)) { continue }
                $key = Get-NormalizedKey -Text $alias
                if ($key) { $map[$key] = $canonical }
            }
            # El propio nombre canónico también cuenta como alias de sí mismo
            $map[(Get-NormalizedKey -Text $canonical)] = $canonical
        }
        Write-Log "Mapa de alias de títulos cargado: $($map.Count) claves desde '$Path'."
    } catch {
        Write-Log "ERROR leyendo el archivo de alias '$Path' (¿JSON mal formado?): $($_.Exception.Message)" 'ERROR'
    }

    return $map
}

# ---------- Decide el nombre DEFINITIVO de la carpeta de obra a partir del título ya limpiado ----------
# Orden de prioridad:
#   1. Alias manual (title-aliases.json) - para variantes que ninguna regex puede deducir
#      (ej. título romaji vs. título oficial en inglés).
#   2. Carpeta de obra YA EXISTENTE en B cuya versión normalizada coincide (ej. diferencias de
#      mayúsculas/espacios/guiones) - se reutiliza esa carpeta en vez de crear una nueva.
#   3. Si no hay coincidencia en ninguno de los dos casos anteriores, se usa el título limpio
#      tal cual y se registra como nueva entrada en la caché para futuras comparaciones.
function Get-CanonicalWorkFolderName {
    param([string]$CleanTitle)

    $key = Get-NormalizedKey -Text $CleanTitle

    if ($script:TitleAliasMap.ContainsKey($key)) {
        return $script:TitleAliasMap[$key]
    }

    if ($script:WorkFolderCache.ContainsKey($key)) {
        return $script:WorkFolderCache[$key]
    }

    $script:WorkFolderCache[$key] = $CleanTitle
    return $CleanTitle
}

# ---------- Escanea las carpetas de obra YA existentes en B para poblar la caché de normalización ----------
# Así, si el script se reinicia, sigue reconociendo y reutilizando las carpetas que ya creó antes,
# en vez de generar una nueva variante con la primera diferencia de mayúsculas/espacios que vea.
function Initialize-WorkFolderCache {
    param([string]$RootPath)

    $cache = @{}
    if (-not (Test-Path -LiteralPath $RootPath)) { return $cache }

    $existingDirs = Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name  # orden alfabético: determinismo si hay colisiones entre carpetas ya existentes

    foreach ($dir in $existingDirs) {
        $key = Get-NormalizedKey -Text $dir.Name
        if ($cache.ContainsKey($key)) {
            Write-Log "AVISO: las carpetas '$($cache[$key])' y '$($dir.Name)' parecen ser la misma obra (normalizan igual). Revísalas y fusiónalas manualmente; el script seguirá usando '$($cache[$key])' a partir de ahora." 'WARN'
        } else {
            $cache[$key] = $dir.Name
        }
    }
    return $cache
}

# ---------- Calcula la ruta del .lnk correspondiente a un archivo de origen, agrupado por obra ----------
function Get-ShortcutPath {
    param([string]$SourcePath)

    $relative = $SourcePath.Substring($FolderA.Length).TrimStart('\','/')
    $segments = $relative -split '[\\/]'

    if ($segments.Count -gt 1) {
        # El archivo está dentro de una subcarpeta de A: el nombre de esa subcarpeta de primer
        # nivel se limpia y se usa como carpeta de obra (no se recrean subcarpetas de temporada).
        $rawTitle = $segments[0]
        $cleanTitle = Get-CleanTitle -RawName $rawTitle
        if ([string]::IsNullOrWhiteSpace($cleanTitle)) { $cleanTitle = $rawTitle }
        $workFolderName = Get-CanonicalWorkFolderName -CleanTitle $cleanTitle

        $subSegments = $segments[1..($segments.Count - 1)]
        $baseName = $subSegments[-1]

        if ($subSegments.Count -gt 1 -and $FlattenSubfolders) {
            # Hay niveles intermedios (ej. carpetas de temporada) que se aplanan como prefijo
            # del nombre del .lnk para evitar colisiones, sin crear subcarpetas reales.
            $prefixParts = $subSegments[0..($subSegments.Count - 2)]
            $prefix = ($prefixParts -join ' - ')
            $lnkBase = "$prefix - $baseName"
        } else {
            $lnkBase = $baseName
        }
    } else {
        # Archivo suelto directamente en A: se deduce el título limpiando el propio nombre de archivo
        $rawTitle = [System.IO.Path]::GetFileNameWithoutExtension($segments[0])
        $cleanTitle = Get-CleanTitle -RawName $rawTitle
        if ([string]::IsNullOrWhiteSpace($cleanTitle)) { $cleanTitle = $rawTitle }
        $workFolderName = Get-CanonicalWorkFolderName -CleanTitle $cleanTitle
        $lnkBase = $segments[0]
    }

    $workFolderName = Get-SafeName -Name $workFolderName
    $workFolderPath = Join-Path $FolderB $workFolderName

    if (-not (Test-Path -LiteralPath $workFolderPath)) {
        New-Item -ItemType Directory -Path $workFolderPath -Force | Out-Null
    }

    $lnkName = [System.IO.Path]::GetFileNameWithoutExtension($lnkBase) + `
               [System.IO.Path]::GetExtension($lnkBase) + ".lnk"
    $lnkName = Get-SafeName -Name $lnkName

    return (Join-Path $workFolderPath $lnkName)
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
            return
        }

        if ($RemoveEmptyWorkFolders) {
            $workFolderPath = [System.IO.Path]::GetDirectoryName($lnkPath)
            try {
                # Solo se borra si está realmente vacía y es una subcarpeta directa de FolderB (seguridad)
                $parentOfWorkFolder = [System.IO.Path]::GetDirectoryName($workFolderPath)
                $isDirectChildOfB = ($parentOfWorkFolder.TrimEnd('\','/')) -eq ($FolderB.TrimEnd('\','/'))
                if ($isDirectChildOfB -and (Test-Path -LiteralPath $workFolderPath)) {
                    $itemsLeft = Get-ChildItem -LiteralPath $workFolderPath -Force -ErrorAction SilentlyContinue
                    if (-not $itemsLeft) {
                        Remove-Item -LiteralPath $workFolderPath -Force
                        Write-Log "Carpeta de obra vacía eliminada: '$workFolderPath'"
                    }
                }
            } catch {
                Write-Log "ERROR eliminando carpeta de obra vacía '$workFolderPath': $($_.Exception.Message)" 'WARN'
            }
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

# Cargar alias manuales y detectar carpetas de obra ya existentes (para reutilizarlas y no
# crear variantes duplicadas por diferencias de mayúsculas/espacios/guiones)
$script:TitleAliasMap   = Import-TitleAliasMap -Path $TitleAliasMapPath
$script:WorkFolderCache = Initialize-WorkFolderCache -RootPath $FolderB

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