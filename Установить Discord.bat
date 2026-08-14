@echo off
setlocal enabledelayedexpansion
title Diskord Setup
cd /d "%~dp0"

rem If discord_app.py isn't sitting next to this script, it's probably
rem running standalone next to a still-zipped GitHub download (e.g. someone
rem saved just this .bat plus the project zip into the same folder, instead
rem of extracting the whole zip first). Auto-unpack that zip so people don't
rem have to extract it by hand before they can run this.
if not exist "discord_app.py" (
    echo Project files not found next to this script -- looking for a zip to unpack...
    set "SRC_ZIP="
    for %%f in ("%~dp0*.zip") do if not defined SRC_ZIP set "SRC_ZIP=%%~ff"
    if not defined SRC_ZIP (
        echo Could not find discord_app.py or a project .zip next to this script.
        echo Put the project's .zip ^(downloaded from GitHub^) in the same
        echo folder as this .bat file and run it again.
        pause
        exit /b 1
    )
    echo Found: !SRC_ZIP!
    set "UNZIP_DIR=%TEMP%\diskord_unzip"
    if exist "!UNZIP_DIR!" rmdir /s /q "!UNZIP_DIR!" >nul 2>nul
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '!SRC_ZIP!' -DestinationPath '!UNZIP_DIR!' -Force"
    if errorlevel 1 (
        echo.
        echo Failed to unpack the zip. See the output above.
        pause
        exit /b 1
    )
    rem A GitHub zip contains one top-level folder (e.g. Discord-WebView2-main\)
    rem -- copy its contents up next to this script so everything below,
    rem which expects discord_app.py etc. right here, keeps working unchanged.
    rem Excludes this .bat's own filename: cmd.exe reads a running batch file
    rem by byte offset as it goes, so overwriting it mid-run can corrupt the
    rem rest of this very script.
    set "XCOPY_EXCLUDE=%TEMP%\diskord_xcopy_exclude.txt"
    > "!XCOPY_EXCLUDE!" echo %~nx0
    for /d %%d in ("!UNZIP_DIR!\*") do xcopy "%%d\*" "%~dp0" /e /i /y /exclude:"!XCOPY_EXCLUDE!" >nul
    del "!XCOPY_EXCLUDE!" >nul 2>nul
    rmdir /s /q "!UNZIP_DIR!" >nul 2>nul
    if not exist "discord_app.py" (
        echo Unpacking the zip did not produce discord_app.py -- aborting.
        pause
        exit /b 1
    )
    echo Unpacked project files next to this script.
    echo.
)

set "INSTALL_DIR=%LOCALAPPDATA%\Discord_v2"
set "WORK_DIR=%TEMP%\diskord_build"

echo === Diskord: setup ===
echo Install folder: %INSTALL_DIR%
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo Python not found. Install it from https://python.org
    echo ^(check "Add python.exe to PATH"^) and run this file again.
    pause
    exit /b 1
)

echo Installing dependencies (pywebview, pythonnet, pyinstaller)...
python -m pip install --upgrade pip >nul
python -m pip install -r requirements.txt pyinstaller
if errorlevel 1 (
    echo.
    echo Dependency installation failed. See the output above.
    pause
    exit /b 1
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
python -m PyInstaller --windowed --noconfirm --name Discord --icon "%~dp0icon.ico" --distpath "%INSTALL_DIR%" --workpath "%WORK_DIR%" --specpath "%WORK_DIR%" "%~dp0discord_app.py"
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
