' ==============================================================================
' launch.vbs - Silent Windows Background Launcher
' ==============================================================================
' Purpose:
' When launching PowerShell or Batch files directly, Windows briefly flashes a
' black console/CMD window on the screen.
'
' This VBScript uses WScript.Shell with window mode 0 (hidden) to launch
' scan_wallet.ps1 completely invisibly from the very first millisecond, ensuring
' the monitor starts cleanly straight into the Windows System Tray.
' ==============================================================================

Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\scan_wallet.ps1""", 0, False
