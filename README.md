# FolderWarden

> Reemplaza `<RUTA_SCRIPT>` por la carpeta donde tengas los archivos
> (ej. `D:\VSworkplace\FolderWarden`) y `<RUTA_LOG>` por tu carpeta B.

## Qué es esto
Vigila la carpeta A en tiempo real. Cuando aparece un archivo nuevo, crea
un acceso directo (`.lnk`) en la carpeta B, agrupado en una subcarpeta por
serie/película/obra. Corre siempre en segundo plano (tarea programada al
iniciar sesión) — no hay que ejecutarlo a mano.

## Comandos esenciales

| Qué quiero hacer | Comando |
|---|---|
| Ver si está corriendo | `Get-ScheduledTask -TaskName "WatchFolderToShortcuts" \| Get-ScheduledTaskInfo` |
| Arrancarlo ya (sin reiniciar sesión) | `Start-ScheduledTask -TaskName "WatchFolderToShortcuts"` |
| Detenerlo | `Stop-ScheduledTask -TaskName "WatchFolderToShortcuts"` |
| Probar manualmente (ver errores en vivo) | `powershell.exe -ExecutionPolicy Bypass -File "<RUTA_SCRIPT>\Watch-FolderToShortcuts.ps1"` (para con `Ctrl+C`) |
| Reinstalar la tarea (como Admin) | `powershell.exe -ExecutionPolicy Bypass -File "<RUTA_SCRIPT>\Register-WatcherTask.ps1"` |
| Desinstalar del todo | `Unregister-ScheduledTask -TaskName "WatchFolderToShortcuts" -Confirm:$false` |

### Cómo leer `LastTaskResult`
- `267009` (`0x41301`) → normal, significa "se está ejecutando ahora mismo".
- `0` → se detuvo limpiamente (normal justo tras un `Stop-ScheduledTask`).
- Cualquier otro número → algo falló; ejecuta el comando de "Probar manualmente" para ver el error.

## Archivos importantes

| Archivo | Para qué sirve |
|---|---|
| `Watch-FolderToShortcuts.ps1` | El script principal. Editar arriba del todo `$FolderA` / `$FolderB` si cambian las rutas. |
| `Register-WatcherTask.ps1` | Solo se ejecuta una vez, para crear la tarea programada. |
| `title-aliases.json` | Aquí se enseñan equivalencias de título que el script no puede deducir solo (ver abajo). |
| `_watcher.log` (dentro de la carpeta B) | Registro de actividad: qué se creó, qué se ignoró, avisos de posibles duplicados. |
| `Launch-Hidden.vbs` / `Restart-Hidden.vbs` | Lanzadores ocultos generados automáticamente. No los toques a mano. |

## Reinicio automático semanal
Cada domingo a las 04:00, una segunda tarea programada
(`WatchFolderToShortcuts-WeeklyRestart`) para y vuelve a arrancar el
watcher solo, para que recargue `title-aliases.json` sin que tengas que
hacerlo tú. Para desactivarlo: `Unregister-ScheduledTask -TaskName "WatchFolderToShortcuts-WeeklyRestart" -Confirm:$false`

## Mantenimiento: dos series que deberían ser una carpeta

Pasa cuando distintos grupos de release usan nombres muy distintos
(título japonés vs. inglés, mayúsculas/orden distinto, etc.) y el script
no puede deducir que son la misma obra solo con reglas de texto.

1. **Detén** la tarea (`Stop-ScheduledTask`).
2. Abre `title-aliases.json` y añade un bloque:
   ```json
   {
     "canonical": "Nombre de carpeta que quiero conservar",
     "aliases": ["Variante A que aparece en algunos releases", "Variante B"]
   }
   ```
3. **Fusiona a mano, una sola vez**: mueve los `.lnk` de la carpeta sobrante
   a la carpeta que quieres conservar, y borra la carpeta vacía.
4. **Arranca** la tarea de nuevo (`Start-ScheduledTask`). A partir de ahora,
   cualquier capítulo nuevo con cualquiera de esas variantes irá a la
   carpeta correcta automáticamente.

## Si algo no cuadra
Revisa `_watcher.log` primero — casi siempre explica qué pasó (archivo
bloqueado, extensión ignorada, carpeta duplicada detectada, etc.).