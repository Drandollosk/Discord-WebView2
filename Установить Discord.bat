@echo off
setlocal enabledelayedexpansion
title Diskord Setup
rem Widen the console -- a narrow default window wraps long lines (error
rem messages especially), which has made a few error reports look cut off.
mode con: cols=110 lines=40 >nul 2>nul
cd /d "%~dp0"

if not exist "discord_app.py" (
    echo discord_app.py not found next to this script. Make sure this .bat
    echo is sitting in the same folder as the rest of the project files
    echo ^(if you downloaded a .zip from GitHub, extract it first^) and run
    echo it again.
    pause
    exit /b 1
)

set "INSTALL_DIR=%LOCALAPPDATA%\Discord_v2"
set "WORK_DIR=%TEMP%\diskord_build"

echo === Diskord: setup ===
echo Install folder: %INSTALL_DIR%
echo.

rem Pinned to 3.12, not "latest": pythonnet (needed for the WebView2 backend)
rem crashes on 3.13/3.14 as of this writing, so grabbing whatever's newest
rem would silently break a brand new install. 3.12.12 is the newest 3.12.x
rem patch release at the time this was written -- bump it here if a newer
rem 3.12.x patch comes out, but don't jump to 3.13+ until pythonnet supports it.
set "PY_VER=3.12.12"

echo Checking for Python...
rem Plain "where python" isn't enough: on a clean Windows 10/11 machine
rem with no real Python installed, PATH still contains a fake python.exe
rem "app execution alias" stub under ...\Microsoft\WindowsApps\ (Windows
rem puts it there so typing "python" in a fresh terminal offers to install
rem it from the Microsoft Store). "where python" happily finds that stub
rem and reports success -- but actually running it can pop up the Store app
rem and just sit there waiting, which is exactly the freeze right after
rem "Checking installed dependencies...". So: look at every match "where"
rem finds and only count it as a real Python if its path is NOT that stub.
set "PYEXE="
for /f "delims=" %%i in ('where python 2^>nul') do (
    echo %%i| findstr /i "WindowsApps" >nul
    if errorlevel 1 (
        if not defined PYEXE set "PYEXE=%%i"
    )
)
if not defined PYEXE (
    echo Python not found -- installing it automatically ^(this is a one-time
    echo step, ~1-2 minutes^)...
    echo.
    set "PY_READY="

    rem Prefer winget when available: it's already on most Windows 10/11
    rem machines, handles the download itself, and Python.Python.3.12 pins
    rem the same 3.12 line as the manual fallback below (not "latest").
    where winget >nul 2>nul
    if not errorlevel 1 (
        echo Trying winget...
        winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements >nul 2>nul
        if not errorlevel 1 set "PY_READY=1"
    )

    if not defined PY_READY (
        echo Downloading the official installer from python.org...
        set "PY_INSTALLER=%TEMP%\diskord_python_installer.exe"
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/!PY_VER!/python-!PY_VER!-amd64.exe' -OutFile '!PY_INSTALLER!'"
        if errorlevel 1 (
            echo.
            echo Could not download the Python installer -- check your internet
            echo connection, or install Python manually from https://python.org
            echo ^(check "Add python.exe to PATH"^) and run this file again.
            pause
            exit /b 1
        )
        echo Installing Python !PY_VER! quietly ^(no windows will pop up^)...
        rem InstallAllUsers=0 -- installs just for this user, under
        rem %LOCALAPPDATA%\Programs\Python, so it doesn't need admin rights.
        "!PY_INSTALLER!" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=0
        set "PY_INSTALL_ERR=!errorlevel!"
        del /q "!PY_INSTALLER!" >nul 2>nul
        if not "!PY_INSTALL_ERR!"=="0" (
            echo.
            echo Python installation failed ^(exit code !PY_INSTALL_ERR!^). Install it
            echo manually from https://python.org and run this file again.
            pause
            exit /b 1
        )
        set "PY_READY=1"
    )

    rem The installer/winget just updated PATH in the registry, but this cmd
    rem window already started with the old PATH and won't pick that change
    rem up on its own -- re-read the real, current User+Machine PATH straight
    rem from the registry (that's what a brand new window would get) and
    rem overwrite this session's PATH with it. This is more reliable than
    rem guessing the install folder name: it works no matter where Python
    rem (or winget) actually put it.
    for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"`) do set "PATH=%%p"

    rem Belt-and-suspenders fallback in case the registry read above didn't
    rem catch it for some reason (e.g. PrependPath didn't run yet) -- look
    rem directly in the two folders Python actually installs into.
    for /d %%p in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
        if exist "%%p\python.exe" set "PATH=%%p;%%p\Scripts;!PATH!"
    )
    for /d %%p in ("%ProgramFiles%\Python3*") do (
        if exist "%%p\python.exe" set "PATH=%%p;%%p\Scripts;!PATH!"
    )

    set "PYEXE="
    for /f "delims=" %%i in ('where python 2^>nul') do (
        echo %%i| findstr /i "WindowsApps" >nul
        if errorlevel 1 (
            if not defined PYEXE set "PYEXE=%%i"
        )
    )
    if not defined PYEXE (
        echo.
        echo Python was installed, but this window still can't see it. Close
        echo this window, open "Установить Discord.bat" again ^(a fresh window
        echo always picks up the updated PATH^), and it'll continue from here
        echo normally -- Python won't need to be installed again.
        pause
        exit /b 1
    )
    echo Python installed successfully.
    echo.
)

rem Installing/upgrading pip + the 3 packages below is the slowest part of
rem a repeat run (re-launching this .bat after every small code change, or
rem after Ochistit papku.vbs + reinstall) even though nothing actually
rem changed. If they're already installed, skip straight to the build --
rem this is what turns a ~10-30s no-op pip step into effectively 0s on
rem every run after the first one on a given machine.
rem
rem Checked purely on disk (dist-info folders under Python's own
rem site-packages), NOT by running "python -m pip show" or "python -c
rem import ...": both of those actually launch python.exe, and on at least
rem one machine that alone either hung with zero output or crashed with an
rem OS-level error -- exactly the freeze/error right after "Checking
rem installed dependencies...". A plain folder check can't hang or crash
rem like that because it never launches Python at all.
echo Checking installed dependencies...
set "DEPS_OK="
if defined PYEXE (
    for %%f in ("!PYEXE!") do set "PY_SITE_PKGS=%%~dpfLib\site-packages"
    set "DEPS_OK=1"
    dir /b "!PY_SITE_PKGS!\pywebview-*.dist-info" >nul 2>nul
    if errorlevel 1 set "DEPS_OK="
    dir /b "!PY_SITE_PKGS!\pythonnet-*.dist-info" >nul 2>nul
    if errorlevel 1 set "DEPS_OK="
    dir /b "!PY_SITE_PKGS!\pyinstaller-*.dist-info" >nul 2>nul
    if errorlevel 1 set "DEPS_OK="
    dir /b "!PY_SITE_PKGS!\pystray-*.dist-info" >nul 2>nul
    if errorlevel 1 set "DEPS_OK="
    dir /b "!PY_SITE_PKGS!\pillow-*.dist-info" >nul 2>nul
    if errorlevel 1 set "DEPS_OK="
)
if not defined DEPS_OK (
    echo Installing dependencies ^(pywebview, pythonnet, pystray, Pillow, pyinstaller^)...
    echo ^(this runs python.exe for real, so if THIS hangs or errors, that
    echo tells us it's Python itself, not this checking step^)
    python -m pip install --upgrade pip
    python -m pip install -r requirements.txt pyinstaller
    if errorlevel 1 (
        echo.
        echo Dependency installation failed. See the output above.
        pause
        exit /b 1
    )
) else (
    echo Dependencies already installed -- skipping.
)

rem Old layout cleanup: earlier versions built into ".\dist" inside this
rem project folder, or a single --onefile Discord.exe directly under
rem %INSTALL_DIR%. Neither is used anymore -- remove them if present.
if exist "dist" rmdir /s /q "dist" >nul 2>nul
if exist "%INSTALL_DIR%\Discord.exe" del /q "%INSTALL_DIR%\Discord.exe" >nul 2>nul

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if exist "%WORK_DIR%" rmdir /s /q "%WORK_DIR%" >nul 2>nul

set "APP_DIR=%INSTALL_DIR%\Discord"
set "APP_EXE=%APP_DIR%\Discord.exe"

echo.
echo Building Discord.exe into %APP_DIR% ...
rem --onedir (no --onefile): launches straight from unpacked files instead
rem of self-extracting the whole Python runtime on every start.
rem --distpath puts the app straight into AppData\Local\Discord_v2;
rem --workpath/--specpath keep build junk out of this project folder.
rem Paths passed as absolute (%~dp0...): with --specpath set, PyInstaller
rem resolves relative paths against the temp spec folder, not this one.
rem --add-data bundles icon.ico as a plain data file too (separate from
rem --icon, which only embeds it as the .exe's own Win32 resource): the
rem tray icon needs to open it as an actual image file at runtime, which it
rem can't do with an icon that only exists baked into the .exe.
python -m PyInstaller --windowed --noconfirm --name Discord --icon "%~dp0icon.ico" --add-data "%~dp0icon.ico;." --distpath "%INSTALL_DIR%" --workpath "%WORK_DIR%" --specpath "%WORK_DIR%" "%~dp0discord_app.py"
if errorlevel 1 (
    echo.
    echo Build failed. See the output above.
    pause
    exit /b 1
)

if not exist "%APP_EXE%" (
    echo Discord.exe was not produced by the build.
    pause
    exit /b 1
)

echo.
echo Cleaning up temporary build files...
rmdir /s /q "%WORK_DIR%" >nul 2>nul

echo Creating a shortcut on the Desktop...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create_shortcut.ps1" -ExePath "%APP_EXE%" -WorkDir "%APP_DIR%"
if errorlevel 1 (
    echo.
    echo Could not create the Desktop shortcut automatically. Discord.exe
    echo still works -- just run it directly from: %APP_EXE%
)

rem Best-effort refresh of Windows' icon cache, so the new icon shows up
rem immediately instead of a stale cached one. Safe to ignore if it fails.
ie4uinit.exe -show >nul 2>nul

echo.
echo ==========================================
echo Done! Discord.exe was installed to:
echo   %APP_EXE%
echo A "Discord" shortcut was added to your Desktop.
echo.
echo This project folder (source code) is only needed
echo to build/rebuild the app. Once installed, you can
echo delete this whole folder -- Discord will keep
echo working from %INSTALL_DIR%.
echo ==========================================
pause
