@echo off
REM =========================================================================
REM  FIX-WSL-DISK.bat - One-click fix for WSL2 "No space left on device"
REM
REM  HOW TO USE:
REM    Double-click this file. That is all.
REM    If Windows asks "Do you want to allow this app to make changes?" -> Yes
REM
REM  WHAT THIS DOES:
REM    Step 1: Elevates to Administrator automatically
REM    Step 2: Diagnoses whether problem is VHDX size or filesystem size
REM    Step 3: Runs resize2fs to claim any unallocated VHDX space
REM    Step 4: Expands VHDX if filesystem is also too small
REM    Step 5: Installs Python + JAX inside WSL2
REM    Step 6: Verifies everything works
REM =========================================================================

setlocal EnableDelayedExpansion
set LOGFILE=%~dp0fix-wsl-disk.log
echo [START] %DATE% %TIME% > "%LOGFILE%"

REM -- Self-elevate to Administrator if not already --------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Requesting Administrator rights...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo.
echo  =====================================================
echo   WSL2 Disk Doctor - Automatic Fix
echo   Diagnosing and fixing disk space automatically
echo  =====================================================
echo.
echo  Log: %LOGFILE%
echo.
echo [OK] Administrator rights confirmed. >> "%LOGFILE%"

REM -- Check WSL2 is installed -----------------------------------------------
where wsl >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] WSL2 is not installed.
    echo.
    echo   Install WSL2:
    echo     1. Open PowerShell as Administrator
    echo     2. Run: wsl --install
    echo     3. Restart your computer
    echo     4. Re-run this script
    echo [ERROR] WSL2 not found >> "%LOGFILE%"
    pause
    exit /b 1
)
echo [OK] WSL2 found. >> "%LOGFILE%"

REM -- Step 1: Check actual filesystem free space ----------------------------
echo [1/5] Checking disk space inside WSL2...
echo [STEP1] Checking WSL2 filesystem free space >> "%LOGFILE%"

for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB=%%F
if not defined FS_FREE_KB set FS_FREE_KB=0

REM Convert KB to MB (integer division)
set /a FS_FREE_MB=%FS_FREE_KB% / 1024
echo   Filesystem free space: %FS_FREE_MB% MB
echo [INFO] Filesystem free: %FS_FREE_MB% MB >> "%LOGFILE%"

REM Show current df output
wsl -- df -h / 2>nul
echo.

REM -- Step 2: Try resize2fs FIRST (catches VHDX-big/filesystem-small case) --
echo [2/5] Attempting filesystem resize (resize2fs)...
echo [STEP2] Running resize2fs >> "%LOGFILE%"

for /f %%D in ('wsl -- sh -c "df / 2>/dev/null | tail -1 | awk \"{print \$1}\"" 2^>nul') do set WSL_DEV=%%D
if not defined WSL_DEV set WSL_DEV=/dev/sdd

echo   Root device: %WSL_DEV%
echo [INFO] Root device: %WSL_DEV% >> "%LOGFILE%"
wsl -- sudo resize2fs %WSL_DEV% 2>&1

REM -- Check free space after resize2fs ------------------------------------
for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB2=%%F
if not defined FS_FREE_KB2 set FS_FREE_KB2=0
set /a FS_FREE_MB2=%FS_FREE_KB2% / 1024
echo   Free space after resize2fs: %FS_FREE_MB2% MB
echo [INFO] Free after resize2fs: %FS_FREE_MB2% MB >> "%LOGFILE%"
echo.

REM -- If still not enough, expand the VHDX and resize again ----------------
if %FS_FREE_MB2% LSS 300 (
    echo [3/5] Filesystem still too small. Expanding VHDX...
    echo [STEP3] Running wsl-expand-disk.ps1 >> "%LOGFILE%"

    set PS1_PATH=%~dp0wsl-expand-disk.ps1
    if not exist "!PS1_PATH!" (
        echo [ERROR] wsl-expand-disk.ps1 not found at: !PS1_PATH!
        echo         Make sure all files are in the same folder.
        echo [ERROR] wsl-expand-disk.ps1 missing >> "%LOGFILE%"
        pause
        exit /b 1
    )

    powershell -ExecutionPolicy Bypass -File "!PS1_PATH!" -TargetGB 20 -Auto
    if %errorlevel% neq 0 (
        echo [WARN] VHDX expansion had issues. Checking space anyway...
        echo [WARN] wsl-expand-disk.ps1 returned non-zero >> "%LOGFILE%"
    ) else (
        echo [OK] VHDX expansion complete. >> "%LOGFILE%"
    )

    echo.
    echo  Waiting 3 seconds for WSL2 to restart...
    timeout /t 3 /nobreak >nul

    REM Final free space check
    for /f "tokens=4" %%F in ('wsl -- sh -c "df / 2>/dev/null | tail -1" 2^>nul') do set FS_FREE_KB3=%%F
    if not defined FS_FREE_KB3 set FS_FREE_KB3=0
    set /a FS_FREE_MB2=!FS_FREE_KB3! / 1024
    echo   Free space now: !FS_FREE_MB2! MB
    echo [INFO] Free after full expand: !FS_FREE_MB2! MB >> "%LOGFILE%"
) else (
    echo [3/5] Enough space after resize2fs. Skipping VHDX expansion.
    echo [SKIP] VHDX expansion not needed >> "%LOGFILE%"
)

REM -- Bail if still not enough ----------------------------------------------
if %FS_FREE_MB2% LSS 200 (
    echo.
    echo [ERROR] Still less than 200MB free after all fixes.
    echo.
    echo   Manual fix: Open WSL2 terminal and run:
    echo     sudo resize2fs %WSL_DEV%
    echo     df -h /
    echo.
    echo   If still full, delete large files:
    echo     du -sh /* 2^>/dev/null ^| sort -rh ^| head -10
    echo [ERROR] Disk still full after all attempts >> "%LOGFILE%"
    pause
    exit /b 1
)

REM -- Step 4: Run bootstrap inside WSL2 ------------------------------------
echo.
echo [4/5] Installing Python + JAX inside WSL2...
echo       (This takes 2-5 minutes - do not close this window)
echo.
echo [STEP4] Running wsl-bootstrap.sh >> "%LOGFILE%"

set SH_PATH=%~dp0wsl-bootstrap.sh
if not exist "%SH_PATH%" (
    echo [ERROR] wsl-bootstrap.sh not found at: %SH_PATH%
    echo [ERROR] wsl-bootstrap.sh missing >> "%LOGFILE%"
    pause
    exit /b 1
)

for /f "delims=" %%P in ('wsl -- wslpath -u "%SH_PATH%" 2^>nul') do set WSL_SH=%%P
echo [INFO] Bootstrap path: !WSL_SH! >> "%LOGFILE%"

wsl -- sh "!WSL_SH!" 2>&1
set BOOTSTRAP_ERR=%errorlevel%
echo [STEP4] Bootstrap exit code: %BOOTSTRAP_ERR% >> "%LOGFILE%"

if %BOOTSTRAP_ERR% neq 0 (
    echo.
    echo [ERROR] Bootstrap failed (exit code: %BOOTSTRAP_ERR%)
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

wsl -- python3 --version 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] python3 not found. Try running this script again.
    echo [ERROR] python3 verify failed >> "%LOGFILE%"
    pause
    exit /b 1
)

wsl -- python3 -c "import jax; print('JAX', jax.__version__, '| Devices:', jax.devices())" 2>nul
if %errorlevel% neq 0 (
    echo [WARN] JAX import failed. Try: wsl -- pip install jax jaxlib --no-cache-dir
    echo [WARN] JAX verify failed >> "%LOGFILE%"
) else (
    echo [OK] JAX verified. >> "%LOGFILE%"
)

echo.
echo  =====================================================
echo   DONE! WSL2 is fixed and ready.
echo.
echo   Next: Double-click RUN-BENCHMARK.bat
echo   Log:  %LOGFILE%
echo  =====================================================
echo.
echo [DONE] %DATE% %TIME% >> "%LOGFILE%"
pause
