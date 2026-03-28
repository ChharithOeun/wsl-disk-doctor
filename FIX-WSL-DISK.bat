@echo off
REM =========================================================================
REM  FIX-WSL-DISK.bat - One-click fix for WSL2 "No space left on device"
REM
REM  WHAT THIS DOES:
REM    1. Elevates to Administrator automatically (UAC prompt)
REM    2. Installs WSL2 if not present (with restart prompt)
REM    3. Gets distro name from Windows registry (avoids UTF-16 encoding bug)
REM    4. Updates WSL to 2.5+ so wsl --manage is available
REM    5. Resizes disk via wsl --manage (handles VHDX + filesystem together)
REM    6. Falls back to wsl-expand-disk.ps1 if wsl --manage unavailable
REM    7. Installs Python + JAX inside WSL2 via wsl-bootstrap.sh
REM    8. Verifies everything works
REM
REM  HOW TO USE:
REM    Double-click this file. Click Yes on the UAC prompt.
REM =========================================================================

setlocal EnableDelayedExpansion
set LOGFILE=%~dp0fix-wsl-disk.log
echo [START] %DATE% %TIME% > "%LOGFILE%"

REM -- Self-elevate to Administrator -----------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Requesting Administrator rights...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo.
echo  =====================================================
echo   WSL2 Disk Doctor - Automatic Fix
echo   Log: %LOGFILE%
echo  =====================================================
echo.
echo [OK] Administrator >> "%LOGFILE%"

REM -- Step 1: Install WSL2 if not present ----------------------------------
echo [1/6] Checking WSL2 installation...
echo [STEP1] Checking WSL2 >> "%LOGFILE%"

where wsl >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [INFO] WSL2 is not installed. Installing now...
    echo [INFO] This requires a restart after installation.
    echo.
    echo [WSL-INSTALL] Running wsl --install >> "%LOGFILE%"
    wsl --install
    if %errorlevel% neq 0 (
        echo.
        echo [ERROR] WSL2 installation failed.
        echo.
        echo   Manual install:
        echo     1. Open PowerShell as Administrator
        echo     2. Run: wsl --install
        echo     3. Restart your computer
        echo     4. Open WSL2 from Start Menu to set up a distro
        echo     5. Re-run this script
        echo [ERROR] wsl --install failed >> "%LOGFILE%"
        pause
        exit /b 1
    )
    echo.
    echo [INFO] WSL2 installed. A restart may be required.
    echo        After restart, open WSL2 from Start Menu ONCE to finish setup.
    echo        Then re-run this script.
    echo [OK] WSL2 installed >> "%LOGFILE%"
    pause
    exit /b 0
)
echo [OK] WSL2 found. >> "%LOGFILE%"

REM -- Step 2: Check current disk state -------------------------------------
echo [2/6] Checking WSL2 filesystem...
echo [STEP2] Checking disk >> "%LOGFILE%"

wsl -- df -h / 2>nul
echo.

for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB=%%F
if not defined FS_FREE_KB set FS_FREE_KB=0
set /a FS_FREE_MB=%FS_FREE_KB% / 1024
echo [INFO] Filesystem free: %FS_FREE_MB% MB >> "%LOGFILE%"
echo   Filesystem free: %FS_FREE_MB% MB
echo.

if %FS_FREE_MB% GEQ 500 (
    echo [INFO] Disk has %FS_FREE_MB% MB free -- no resize needed.
    echo [INFO] Skipping expand, jumping to bootstrap. >> "%LOGFILE%"
    goto :bootstrap
)

REM -- Step 3: Get distro name from registry (avoids UTF-16LE encoding bug) -
echo [3/6] Getting distro name from Windows registry...
echo [STEP3] Registry distro lookup >> "%LOGFILE%"

REM PowerShell reads DistributionName + BasePath from HKCU Lxss registry key
REM Filters out docker-* distros (Docker Desktop manages its own, cannot resize)
REM Uses DefaultDistribution GUID to prefer the default distro

for /f "delims=" %%D in ('powershell -NoProfile -Command "$k=\"HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\"; $defaultGuid=(Get-ItemProperty $k -ErrorAction SilentlyContinue).DefaultDistribution; $distros=Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object { $p=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue; if($p.DistributionName -and $p.DistributionName -notlike \"docker-*\"){[PSCustomObject]@{Name=$p.DistributionName;IsDefault=($_.PSChildName -eq $defaultGuid)}} }; $sel=$distros|Where-Object{$_.IsDefault}|Select-Object -First 1; if(-not $sel){$sel=$distros|Select-Object -First 1}; if($sel){$sel.Name}" 2^>nul') do set WSL_DISTRO=%%D

if not defined WSL_DISTRO (
    echo [WARN] Could not detect distro name from registry. Falling back to wsl-expand-disk.ps1...
    echo [WARN] Registry distro lookup failed >> "%LOGFILE%"
    goto :ps1_fallback
)

echo   Distro: !WSL_DISTRO!
echo [INFO] Distro from registry: !WSL_DISTRO! >> "%LOGFILE%"

REM -- Step 4: Update WSL to 2.5+ and resize --------------------------------
echo [4/6] Updating WSL and resizing filesystem...
echo [STEP4] wsl --update and resize >> "%LOGFILE%"

echo   Updating WSL (ensures wsl --manage is available)...
wsl --update 2>&1
echo [INFO] wsl --update done >> "%LOGFILE%"

wsl --shutdown
timeout /t 3 /nobreak >nul

REM Try wsl --manage (WSL 2.5+, handles VHDX + filesystem from Windows)
REM Target 51200 MB (50 GB) -- must be LARGER than current VHDX virtual size.
REM If the distro VHDX virtual disk is already >50 GB, bump this higher.
echo   Trying: wsl --manage "!WSL_DISTRO!" --resize 51200
wsl --manage "!WSL_DISTRO!" --resize 51200 2>&1
set MANAGE_ERR=%errorlevel%
echo [INFO] wsl --manage exit: %MANAGE_ERR% >> "%LOGFILE%"

if %MANAGE_ERR% equ 0 (
    echo   [OK] Resize complete via wsl --manage.
    echo [OK] wsl --manage succeeded >> "%LOGFILE%"
    goto :verify_space
)

echo   [WARN] wsl --manage failed (exit %MANAGE_ERR%). Falling back to ps1...
echo [WARN] wsl --manage failed, trying ps1 >> "%LOGFILE%"

:ps1_fallback
REM Run the PowerShell expander as fallback
set PS1_PATH=%~dp0wsl-expand-disk.ps1
if not exist "!PS1_PATH!" (
    echo [ERROR] wsl-expand-disk.ps1 not found.
    echo         Make sure all files are in the same folder as FIX-WSL-DISK.bat
    echo [ERROR] wsl-expand-disk.ps1 missing >> "%LOGFILE%"
    pause
    exit /b 1
)

echo   Running wsl-expand-disk.ps1...
powershell -ExecutionPolicy Bypass -File "!PS1_PATH!" -TargetGB 50 -Auto
echo [INFO] wsl-expand-disk.ps1 exit: %errorlevel% >> "%LOGFILE%"

:verify_space
REM Restart WSL2 and check actual free space
echo.
echo   Waiting 3 seconds for WSL2 to restart...
timeout /t 3 /nobreak >nul

wsl -- df -h / 2>nul
echo.

for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB2=%%F
if not defined FS_FREE_KB2 set FS_FREE_KB2=0
set /a FS_FREE_MB2=%FS_FREE_KB2% / 1024
echo   Free space now: !FS_FREE_MB2! MB
echo [INFO] Free after resize: !FS_FREE_MB2! MB >> "%LOGFILE%"

if !FS_FREE_MB2! LSS 200 (
    echo [ERROR] Still too little free space after resize ^(!FS_FREE_MB2! MB^).
    echo.
    echo   Manual fix -- open WSL2 terminal and run:
    echo     apk add e2fsprogs
    echo     sudo resize2fs /dev/sdd
    echo     df -h /
    echo.
    echo   OR run with a larger target:
    echo     powershell -File wsl-expand-disk.ps1 -TargetGB 80 -Auto
    echo [ERROR] Still low after resize >> "%LOGFILE%"
    pause
    exit /b 1
)

:bootstrap
REM -- Step 5: Run bootstrap inside WSL2 ------------------------------------
echo [5/6] Installing Python + JAX inside WSL2...
echo       (2-5 minutes -- do not close this window)
echo.
echo [STEP5] Bootstrap >> "%LOGFILE%"

set SH_PATH=%~dp0wsl-bootstrap.sh
if not exist "%SH_PATH%" (
    echo [ERROR] wsl-bootstrap.sh not found: %SH_PATH%
    echo [ERROR] wsl-bootstrap.sh missing >> "%LOGFILE%"
    pause
    exit /b 1
)

for /f "delims=" %%P in ('wsl -- wslpath -u "%SH_PATH%" 2^>nul') do set WSL_SH=%%P
echo [INFO] Bootstrap: !WSL_SH! >> "%LOGFILE%"

wsl -- sh "!WSL_SH!" 2>&1
set BOOT_ERR=%errorlevel%
echo [STEP5] exit: %BOOT_ERR% >> "%LOGFILE%"

if %BOOT_ERR% neq 0 (
    echo.
    echo [ERROR] Bootstrap failed ^(exit %BOOT_ERR%^).
    echo   Check log: %LOGFILE%
    echo   Then re-run this script.
    echo [ERROR] Bootstrap failed >> "%LOGFILE%"
    pause
    exit /b 1
)
echo [OK] Bootstrap complete. >> "%LOGFILE%"

REM -- Step 6: Verify -------------------------------------------------------
echo.
echo [6/6] Verifying Python + JAX...
echo.
echo [STEP6] Verifying >> "%LOGFILE%"

wsl -- python3 --version 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] python3 not found. Re-run this script.
    echo [ERROR] python3 verify failed >> "%LOGFILE%"
    pause
    exit /b 1
)

wsl -- python3 -c "import jax; print('JAX', jax.__version__, '| Devices:', jax.devices())" 2>nul
if %errorlevel% neq 0 (
    echo [WARN] JAX not working. Run: wsl -- pip install jax jaxlib --no-cache-dir
    echo [WARN] JAX verify failed >> "%LOGFILE%"
) else (
    echo [OK] JAX verified. >> "%LOGFILE%"
)

echo.
echo  =====================================================
echo   DONE! WSL2 is fixed and ready.
echo   Double-click RUN-BENCHMARK.bat to run benchmark.
echo   Log: %LOGFILE%
echo  =====================================================
echo.
echo [DONE] %DATE% %TIME% >> "%LOGFILE%"
pause
