@echo off
REM =========================================================================
REM  FIX-WSL-DISK.bat - One-click fix for WSL2 "No space left on device"
REM
REM  WHAT THIS DOES (automatically, in order):
REM   Step 1: Elevates to Administrator if needed
REM   Step 2: Expands your WSL2 virtual disk to 20GB
REM   Step 3: Runs wsl-bootstrap.sh inside WSL2 to install Python + JAX
REM   Step 4: Verifies Python and JAX are working
REM
REM  HOW TO USE:
REM   Double-click this file. That is all.
REM   If Windows asks "Do you want to allow this app to make changes?" -> Yes
REM =========================================================================

setlocal EnableDelayedExpansion
set LOGFILE=%~dp0fix-wsl-disk.log
echo [START] %DATE% %TIME% > "%LOGFILE%"

REM -- Self-elevate to Administrator if not already --------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Not running as Administrator. Requesting elevation...
    echo [INFO] Requesting elevation >> "%LOGFILE%"
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo.
echo  =====================================================
echo   WSL2 Disk Doctor - Automatic Fix
echo   Step 1/3: Expand disk
echo   Step 2/3: Install Python + JAX
echo   Step 3/3: Verify
echo  =====================================================
echo.
echo  Log: %LOGFILE%
echo.
echo [OK] Running as Administrator >> "%LOGFILE%"

REM -- Check WSL2 is installed -----------------------------------------------
where wsl >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] WSL2 is not installed.
    echo.
    echo  Install WSL2 first:
    echo    1. Open PowerShell as Administrator
    echo    2. Run: wsl --install
    echo    3. Restart your computer
    echo    4. Re-run this script
    echo [ERROR] WSL2 not found >> "%LOGFILE%"
    pause
    exit /b 1
)
echo [OK] WSL2 found. >> "%LOGFILE%"

REM -- Check disk space before expanding ------------------------------------
echo [1/3] Checking WSL2 distros...
wsl -- df -h / 2>nul
echo.
echo [1/3] Checking WSL2 disk space... >> "%LOGFILE%"

REM -- Step 1: Run PowerShell expander --------------------------------------
echo [1/3] Expanding WSL2 virtual disk to 20GB...
echo       (Automatically expanding - no action needed)
echo.
echo [STEP1] Running wsl-expand-disk.ps1 >> "%LOGFILE%"

set PS1_PATH=%~dp0wsl-expand-disk.ps1
if not exist "%PS1_PATH%" (
    echo [ERROR] wsl-expand-disk.ps1 not found at: %PS1_PATH%
    echo         Make sure FIX-WSL-DISK.bat is in the same folder as wsl-expand-disk.ps1
    echo [ERROR] wsl-expand-disk.ps1 not found >> "%LOGFILE%"
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%PS1_PATH%" -TargetGB 20 -Auto
if %errorlevel% neq 0 (
    echo.
    echo [WARN] Disk expansion step had issues. Continuing anyway...
    echo        Check if WSL2 disk is already large enough: wsl -- df -h /
    echo [WARN] wsl-expand-disk.ps1 returned non-zero >> "%LOGFILE%"
) else (
    echo [OK] Disk expansion complete. >> "%LOGFILE%"
)

echo.
echo  Step 1 complete. Waiting 3 seconds for WSL2 to restart...
timeout /t 3 /nobreak >nul

REM -- Step 2: Run bootstrap inside WSL2 -----------------------------------
echo [2/3] Installing Python + JAX inside WSL2...
echo       (This takes 2-5 minutes - do not close this window)
echo.
echo [STEP2] Running wsl-bootstrap.sh >> "%LOGFILE%"

set SH_PATH=%~dp0wsl-bootstrap.sh
if not exist "%SH_PATH%" (
    echo [ERROR] wsl-bootstrap.sh not found at: %SH_PATH%
    echo [ERROR] wsl-bootstrap.sh not found >> "%LOGFILE%"
    pause
    exit /b 1
)

REM Convert Windows path to WSL2 path
for /f "delims=" %%P in ('wsl -- wslpath -u "%SH_PATH%" 2^>nul') do set WSL_SH=%%P
echo [INFO] WSL path: !WSL_SH! >> "%LOGFILE%"

wsl -- sh "!WSL_SH!" 2>&1
set BOOTSTRAP_ERR=%errorlevel%
echo [STEP2] Bootstrap exit code: %BOOTSTRAP_ERR% >> "%LOGFILE%"

if %BOOTSTRAP_ERR% neq 0 (
    echo.
    echo [ERROR] Bootstrap failed (exit code: %BOOTSTRAP_ERR%)
    echo.
    echo  Most likely cause: disk still too full even after expansion.
    echo  Fix:
    echo    1. Open WSL2 and run: df -h /
    echo    2. If still full, run this script again with larger size:
    echo       powershell -File wsl-expand-disk.ps1 -TargetGB 40 -Auto
    echo    3. Then re-run this script
    echo [ERROR] Bootstrap failed >> "%LOGFILE%"
    pause
    exit /b 1
)
echo [OK] Bootstrap complete. >> "%LOGFILE%"

REM -- Step 3: Verify Python and JAX work ----------------------------------
echo.
echo [3/3] Verifying Python + JAX...
echo.

wsl -- python3 --version 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] python3 still not found after bootstrap.
    echo         Try running this script again.
    echo [ERROR] python3 verify failed >> "%LOGFILE%"
    pause
    exit /b 1
)

wsl -- python3 -c "import jax; print('JAX:', jax.__version__); print('Devices:', jax.devices())" 2>nul
if %errorlevel% neq 0 (
    echo [WARN] JAX import failed. Try:
    echo   wsl -- pip install jax jaxlib --no-cache-dir
    echo [WARN] JAX verify failed >> "%LOGFILE%"
) else (
    echo [OK] JAX working! >> "%LOGFILE%"
)

echo.
echo  =====================================================
echo   DONE! WSL2 is now ready.
echo.
echo   You can now:
echo     - Double-click RUN-BENCHMARK.bat
echo     - Run any Python/JAX script inside WSL2
echo.
echo   Log saved to: %LOGFILE%
echo  =====================================================
echo.
echo [DONE] %DATE% %TIME% >> "%LOGFILE%"
pause
