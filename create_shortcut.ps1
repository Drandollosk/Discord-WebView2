# Creates (or refreshes) the "Discord" Desktop shortcut for Diskord.
# Run by "Установить Discord.bat" after a successful build. Kept as its
# own .ps1 (instead of an inline multi-line -Command in the .bat) so the
# quoting stays simple and easy to verify.
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$WorkDir
)

# [Environment]::GetFolderPath('Desktop') resolves the *real* Desktop
# folder, including when OneDrive has redirected it elsewhere (commonly
# C:\Users\<you>\OneDrive\Desktop) -- a hardcoded %USERPROFILE%\Desktop
# path would silently create the shortcut in the wrong place.
$desktop = [Environment]::GetFolderPath('Desktop')
$link = Join-Path $desktop 'Discord.lnk'

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($link)
$shortcut.TargetPath = $ExePath
$shortcut.WorkingDirectory = $WorkDir
# Icon is embedded in the exe itself (built with --icon), so the shortcut
# doesn't depend on any file from the source project folder -- it keeps
# working even if that folder gets deleted later.
$shortcut.IconLocation = "$ExePath,0"
$shortcut.Description = 'Discord (web app in its own window)'
$shortcut.Save()

if (Test-Path $link) {
    Write-Host ('SHORTCUT_OK: ' + $link)
    exit 0
} else {
    Write-Host 'SHORTCUT_FAIL'
    exit 1
}
