' Diskord cleanup / uninstall utility.
'
' Deletes:
'  1. stray PyInstaller build artifacts in this project folder
'  2. the installed app folder: %LOCALAPPDATA%\Discord_v2
'  3. the "Discord" shortcut on the Desktop
'
' Never touches discord_app.py, requirements.txt, icon.ico, README.md,
' the install .bat script, or create_shortcut.ps1 in this project folder.
' Double-click to run -- no console window, just one confirmation at the end.
'
' NOTE: this file intentionally has NO Cyrillic text anywhere -- Windows
' Script Host reads .vbs files using the system ANSI codepage rather than
' UTF-8, so Cyrillic saved as UTF-8 shows up as garbled characters (and,
' worse, a Cyrillic string literal used as a file path would silently
' fail to match the real file, so the delete would just do nothing).

Set fso = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

Sub DeleteFileIfExists(p)
    If fso.FileExists(p) Then fso.DeleteFile p, True
End Sub

Sub DeleteFolderIfExists(p)
    If fso.FolderExists(p) Then fso.DeleteFolder p, True
End Sub

' --- 1. Stray build artifacts (in case someone built without the .bat) ---
DeleteFileIfExists scriptDir & "\Discord.spec"
DeleteFileIfExists scriptDir & "\diskord_error.log"
DeleteFolderIfExists scriptDir & "\build"
DeleteFolderIfExists scriptDir & "\dist"

' --- 2. Installed app in AppData ---
appDataLocal = oShell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
DeleteFolderIfExists appDataLocal & "\Discord_v2"

' --- 3. Desktop shortcut ---
' oShell.SpecialFolders("Desktop") resolves the *real* Desktop path via
' Windows itself, so it's correct even when OneDrive has redirected it
' elsewhere -- unlike guessing %USERPROFILE%\Desktop.
desktopPath = oShell.SpecialFolders("Desktop")
DeleteFileIfExists desktopPath & "\Discord.lnk"

MsgBox "Cleanup done." & vbCrLf & vbCrLf & _
    "- Removed stray build files from this project folder." & vbCrLf & _
    "- Removed the installed app folder in AppData\Local\Discord_v2." & vbCrLf & _
    "- Removed the Discord shortcut from the Desktop." & vbCrLf & vbCrLf & _
    "To reinstall, just run the install .bat script in this folder again.", _
    vbInformation, "Diskord"
