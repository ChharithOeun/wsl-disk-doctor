@echo off
REM =========================================================================
REM  FIX-WSL-DISK.bat - One-click fix for WSL2 "No space left on device"
REM
REM  WHAT THIS DOES:
REM    1. Elevates to Administrator automatically (UAC prompt)
REM    2. Installs WSL2 if not present (with restart prompt)
REM    3. Runs resize2fs via wsl --manage (no Linux tools needed)
REM    4. Installs Python + JAX inside WSL2 via wsl-bootstrap.sh
REM    5. Verifies everything works
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
echo [1/5] Checking WSL2 installation...
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
echo [2/5] Checking WSL2 filesystem...
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

REM -- Step 3: Resize using wsl --manage (best method, no Linux tools needed) -
echo [3/5] Resizing WSL2 filesystem...
echo [STEP3] Resizing >> "%LOGFILE%"

REM Get distro name
for /f %%D in ('wsl --list --quiet 2^>nul') do (
    if not defined WSL_DISTRO (
        REM Strip BOM/non-printable chars that wsl --list emits on older Windows
        set "RAW_NAME=%%D"
        set WSL_DISTRO=%%D
    )
)

if not defined WSL_DISTRO (
    echo [WARN] Could not detect distro name. Using wsl-expand-disk.ps1 fallback...
    echo [WARN] Distro name not detected >> "%LOGFILE%"
    goto :ps1_fallback
)

echo   Distro: !WSL_DISTRO!
echo [INFO] Distro: !WSL_DISTRO! >> "%LOGFILE%"

REM Try wsl --manage (WSL 2.5+, handles VHDX + filesystem from Windows)
echo   Trying: wsl --manage "!WSL_DISTRO!" --resize 20480
wsl --manage "!WSL_DISTRO!" --resize 20480 2>&1
set MANAGE_ERR=%errorlevel%
echo [INFO] wsl --manage exit: %MANAGE_ERR% >> "%LOGFILE%"

if %MANAGE_ERR% equ 0 (
    echo   [OK] Resize complete via wsl --manage.
    echo [OK] wsl --manage succeeded >> "%LOGFILE%"
    goto :verify_space
)

echo   [WARN] wsl --manage not available on this version. Falling back...
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
powershell -ExecutionPolicy Bypass -File "!PS1_PATH!" -TargetGB 20 -Auto
echo [INFO] wsl-expand-disk.ps1 exit: %errorlevel% >> "%LOGFILE%"

:verify_space
REM Restart WSL2 and check actual free space
echo.
echo   Waiting 3 seconds for WSL2 to restart...
timeout /t 3 /nobreak >nul

for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB2=%%F
if not defined FS_FREE_KB2 set FS_FREE_KB2=0
set /a FS_FREE_MB2=%FS_FREE_KB2% / 1024
echo   Free space now: !FS_FREE_MB2! MB
echo [INFO] Free after resize: !FS_FREE_MB2! MB >> "%LOGFILE%"
wsl -- df -h / 2>nul
echo.

if !FS_FREE_MB2! LSS 200 (
    echo [ERROR] Still too little free space after resize ^(!FS_FREE_MB2! MB^).
    echo.
    echo   Manual fix -- open WSL2 terminal and run:
    echo     apk add e2fsprogs
    echo     sudo resize2fs /dev/sdd
    echo     df -h /
    echo.
    echo   OR run with a larger target:
    echo     powershell -File wsl-expand-disk.ps1 -TargetGB 40 -Auto
    echo [ERROR] Still low after resize >> "%LOGFILE%"
    pause
    exit /b 1
)

:bootstrap
REM -- Step 4: Run bootstrap inside WSL2 ------------------------------------
echo [4/5] Installing Python + JAX inside WSL2...
echo       (2-5 minutes -- do not close this window)
echo.
echo [STEP4] Bootstrap >> "%LOGFILE%"

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
echo [STEP4] exit: %BOOT_ERR% >> "%LOGFILE%"

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

REM -- Step 5: Verify -------------------------------------------------------
echo.
echo [5/5] Verifying Python + JAX...
echo.
echo [STEP5] Verifying >> "%LOGFILE%"

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
