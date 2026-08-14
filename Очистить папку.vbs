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
appDataLocal = oShell.ExpandEnvironmentStrings("%LOCALAPPDATA%")

failures = ""

Sub DeleteFileIfExists(p)
    If fso.FileExists(p) Then
        On Error Resume Next
        fso.DeleteFile p, True
        If Err.Number <> 0 Then
            failures = failures & vbCrLf & "  " & p
            Err.Clear
        End If
        On Error Goto 0
    End If
End Sub

Sub DeleteFolderIfExists(p)
    If fso.FolderExists(p) Then
        On Error Resume Next
        fso.DeleteFolder p, True
        If Err.Number <> 0 Then
            failures = failures & vbCrLf & "  " & p
            Err.Clear
        End If
        On Error Goto 0
    End If
End Sub

' --- 1. Stray build artifacts (in case someone built without the .bat) ---
DeleteFileIfExists scriptDir & "\Discord.spec"
DeleteFileIfExists scriptDir & "\diskord_error.log"
DeleteFolderIfExists scriptDir & "\build"
DeleteFolderIfExists scriptDir & "\dist"

' --- 2. Installed app in AppData ---
' If Discord.exe is still running, Windows keeps its files locked and the
' DeleteFolder call below fails with "Permission denied" -- that's the
' error this used to crash with. Force-close it first, but ONLY a process
' whose exe path is exactly our own install -- this must never touch a
' *different* Discord.exe, e.g. the official Discord desktop client if
' that's separately installed on this machine.
installedExe = appDataLocal & "\Discord_v2\Discord\Discord.exe"
On Error Resume Next
Set colProcesses = GetObject("winmgmts:").ExecQuery("Select * from Win32_Process Where Name='Discord.exe'")
If Not colProcesses Is Nothing Then
    For Each objProcess In colProcesses
        If LCase(objProcess.ExecutablePath) = LCase(installedExe) Then
            objProcess.Terminate()
        End If
    Next
End If
Err.Clear
On Error Goto 0
WScript.Sleep 800

DeleteFolderIfExists appDataLocal & "\Discord_v2"

' --- 3. Desktop shortcut ---
' oShell.SpecialFolders("Desktop") resolves the *real* Desktop path via
' Windows itself, so it's correct even when OneDrive has redirected it
' elsewhere -- unlike guessing %USERPROFILE%\Desktop.
desktopPath = oShell.SpecialFolders("Desktop")
DeleteFileIfExists desktopPath & "\Discord.lnk"

If failures = "" Then
    MsgBox "Cleanup done." & vbCrLf & vbCrLf & _
        "- Removed stray build files from this project folder." & vbCrLf & _
        "- Removed the installed app folder in AppData\Local\Discord_v2." & vbCrLf & _
        "- Removed the Discord shortcut from the Desktop." & vbCrLf & vbCrLf & _
        "To reinstall, just run the install .bat script in this folder again.", _
        vbInformation, "Diskord"
Else
    MsgBox "Cleanup finished, but could not remove:" & failures & vbCrLf & vbCrLf & _
        "This usually means Discord (or a leftover background process) was " & _
        "still running and had these files locked. Close Discord completely " & _
        "and run this script again to remove the rest.", _
        vbExclamation, "Diskord"
End If
