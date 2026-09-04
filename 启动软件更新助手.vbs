' SoftUpdater launcher: hide console, start the WPF UI (the script self-elevates via UAC).
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "D:\software\SoftUpdater"
sh.Run "pwsh -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ""D:\software\SoftUpdater\SoftUpdater.ps1""", 0, False
