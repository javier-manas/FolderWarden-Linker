Set objShell = CreateObject("WScript.Shell")
objShell.Run "C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""D:\VSworkplace\FolderWarden\Restart-WatcherTask.ps1""", 0, True
