# =============================================================================
#  wsl-expand-disk.ps1 - Expand WSL2 virtual disk + resize filesystem
#
#  Run as Administrator:
#    Right-click -> Run as Administrator
#    OR: powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
#
#  Fix order (most reliable first):
#    1. wsl --manage <distro> --resize  (WSL 2.5+, handles everything, no Linux tools needed)
#    2. Resize-VHD  (Hyper-V PowerShell module)
#    3. diskpart    (legacy, may fail on dynamic VHDXs)
#    After any VHDX expand: attempts resize2fs inside WSL2 if available
#
#  NOTE: Alpine Linux does not ship resize2fs (it's in e2fsprogs).
#        Methods 1 and 2 handle filesystem resize from Windows -- no Alpine tools needed.
# =============================================================================

param(
    [string]$Distro   = "",
    [int]$TargetGB    = 20,
    [switch]$Auto,
    [switch]$ResizeOnly
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  WSL2 Disk Doctor - Expander + Filesystem Resize" -ForegroundColor Cyan
Write-Host "  Fixes: No space left on device" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------
# Must be Administrator
# --------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] Must run as Administrator." -ForegroundColor Red
    Write-Host "        Right-click the script -> Run as Administrator"
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Helper: get actual distro names from wsl --list
# --------------------------------------------------------------------------
function Get-WslDistroNames {
    try {
        # wsl --list --quiet outputs distro names (may include BOM/UTF-16 chars on older Windows)
        $raw = & wsl.exe --list --quiet 2>$null
        if ($raw) {
            return ($raw | ForEach-Object { ($_ -replace '[^\x20-\x7E]','').Trim() } | Where-Object { $_ -ne "" })
        }
    } catch {}
    return @()
}

# --------------------------------------------------------------------------
# Helper: get free MB inside currently running WSL2 distro
# --------------------------------------------------------------------------
function Get-WslFreeMB {
    try {
        $raw = (& wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$4}'" 2>$null).Trim()
        $kb = [int64]($raw -replace '\D','')
        return [math]::Round($kb / 1024, 0)
    } catch { return 0 }
}

function Get-WslTotalMB {
    try {
        $raw = (& wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$2}'" 2>$null).Trim()
        $kb = [int64]($raw -replace '\D','')
        return [math]::Round($kb / 1024, 0)
    } catch { return 0 }
}

# --------------------------------------------------------------------------
# FAST PATH: --ResizeOnly (just run wsl --manage resize, no VHDX expansion)
# --------------------------------------------------------------------------
if ($ResizeOnly) {
    Write-Host "[RESIZE-ONLY] Running filesystem resize via wsl --manage..." -ForegroundColor Yellow
    Write-Host ""

    $distroNames = Get-WslDistroNames
    Write-Host "  Detected distros: $($distroNames -join ', ')"

    $targetDistro = if ($Distro) { $Distro } elseif ($distroNames.Count -eq 1) { $distroNames[0] } else { $distroNames[0] }
    $targetMB = $TargetGB * 1024

    Write-Host "  Running: wsl --manage '$targetDistro' --resize $targetMB"
    & wsl.exe --shutdown
    Start-Sleep -Seconds 2

    $result = & wsl.exe --manage $targetDistro --resize $targetMB 2>&1
    Write-Host $result

    Write-Host ""
    Write-Host "  Verifying..."
    & wsl.exe -- df -h /
    Write-Host ""
    Write-Host "[DONE]" -ForegroundColor Green
    Read-Host "Press Enter to exit"
    exit 0
}

# --------------------------------------------------------------------------
# Step 1: Scan VHDX files
# --------------------------------------------------------------------------
Write-Host "[1/5] Scanning for WSL2 distros..." -ForegroundColor Yellow
Write-Host ""

$vhdxFiles = @()
foreach ($searchPath in @("$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\wsl")) {
    if (Test-Path $searchPath) {
        $vhdxFiles += Get-ChildItem -Path $searchPath -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
    }
}

# Registry fallback
try {
    $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $regKey) {
        foreach ($d in (Get-ChildItem $regKey -ErrorAction SilentlyContinue)) {
            $bp = (Get-ItemProperty $d.PSPath -Name BasePath -ErrorAction SilentlyContinue).BasePath
            if ($bp) {
                $vhdx = Join-Path $bp "ext4.vhdx"
                if ((Test-Path $vhdx) -and ($vhdxFiles.FullName -notcontains $vhdx)) {
                    $vhdxFiles += [PSCustomObject]@{ FullName = $vhdx; Name = "ext4.vhdx" }
                }
            }
        }
    }
} catch {}

if ($vhdxFiles.Count -eq 0) {
    Write-Host "[ERROR] No WSL2 VHDX files found." -ForegroundColor Red
    Write-Host "        WSL2 may not be installed or no distro has been launched yet."
    Write-Host "        To install WSL2: wsl --install"
    Write-Host "        Then launch a distro, run it once, and re-run this script."
    Read-Host "Press Enter to exit"
    exit 1
}

# Get distro names from WSL to match against VHDXs
$distroNames = Get-WslDistroNames
$freeNow = Get-WslFreeMB
$totalNow = Get-WslTotalMB

$i = 1
$vhdxList = @()
foreach ($v in $vhdxFiles) {
    $vhdxSizeGB = [math]::Round((Get-Item $v.FullName).Length / 1GB, 2)
    $folderHint  = Split-Path (Split-Path $v.FullName -Parent) -Leaf
    $mismatch    = ($vhdxSizeGB -gt 1) -and ($totalNow -lt 500)

    # Best guess at distro name: first from wsl list, otherwise folder hint
    $guessName = if ($distroNames.Count -gt 0) { $distroNames[0] } else { $folderHint }

    Write-Host "  [$i] $guessName" -ForegroundColor White
    Write-Host "      VHDX file (Windows):  $vhdxSizeGB GB"
    Write-Host "      Filesystem (Linux):   $totalNow MB total, $freeNow MB free"
    if ($mismatch) {
        Write-Host "      *** SIZE MISMATCH: VHDX=$vhdxSizeGB GB but filesystem only $totalNow MB" -ForegroundColor Red
        Write-Host "          'wsl --manage' will fix this from Windows, no Linux tools needed" -ForegroundColor Yellow
    }
    Write-Host ""

    $vhdxList += [PSCustomObject]@{
        Index    = $i; Path = $v.FullName; Hint = $guessName
        SizeGB   = $vhdxSizeGB; FsFreeMB = $freeNow; FsTotalMB = $totalNow; Mismatch = $mismatch
    }
    $i++
}

# --------------------------------------------------------------------------
# Step 2: Select distro
# --------------------------------------------------------------------------
$sel = $null
if ($Auto -or $vhdxList.Count -eq 1) {
    $sel = $vhdxList[0]
    Write-Host "[AUTO] Selected: $($sel.Hint)" -ForegroundColor Green
} else {
    $choice = Read-Host "Enter number to fix (Q to quit)"
    if ($choice -match '^[Qq]') { exit 0 }
    $sel = $vhdxList | Where-Object { $_.Index -eq [int]$choice }
    if (-not $sel) { Write-Host "[ERROR] Invalid." -ForegroundColor Red; exit 1 }
}

# If VHDX >= target, just do resize2fs path
$needExpand = $sel.SizeGB -lt $TargetGB
if (-not $needExpand) {
    Write-Host ""
    Write-Host "[INFO] VHDX already $($sel.SizeGB) GB. Running filesystem resize only." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Step 3: Shut down WSL2
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Shutting down WSL2..." -ForegroundColor Yellow
& wsl.exe --shutdown
Start-Sleep -Seconds 3
Write-Host "      Done."

# --------------------------------------------------------------------------
# Step 4: Resize (VHDX + filesystem) using best available method
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] Resizing..." -ForegroundColor Yellow

$targetMB    = [int64]$TargetGB * 1024
$targetBytes = [int64]$TargetGB * 1073741824
$resized     = $false

# Method 1 (BEST): wsl --manage -- handles BOTH VHDX and filesystem, no Linux tools needed
# Works on WSL 2.5+ (Windows 11 22H2+ and Windows 10 with WSL2 2.5+)
Write-Host "  [Method 1] wsl --manage '$($sel.Hint)' --resize $targetMB ..."
try {
    $out = & wsl.exe --manage $sel.Hint --resize $targetMB 2>&1
    Write-Host "  $out"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [Method 1] SUCCESS" -ForegroundColor Green
        $resized = $true
    } else {
        Write-Host "  [Method 1] Failed (exit $LASTEXITCODE) -- trying next method" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [Method 1] Not available on this WSL version -- trying next method" -ForegroundColor Yellow
}

# Method 2: Resize-VHD (Hyper-V) + resize2fs inside WSL2
if (-not $resized) {
    $hvCmd = Get-Command -Name Resize-VHD -ErrorAction SilentlyContinue
    if ($hvCmd) {
        Write-Host "  [Method 2] Resize-VHD (Hyper-V)..."
        try {
            Resize-VHD -Path $sel.Path -SizeBytes $targetBytes
            Write-Host "  [Method 2] VHDX expanded." -ForegroundColor Green
            $resized = $true
        } catch {
            Write-Host "  [Method 2] Failed: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [Method 2] Hyper-V not available -- trying diskpart" -ForegroundColor Yellow
    }
}

# Method 3: diskpart (legacy, may fail on dynamic VHDXs)
if (-not $resized) {
    Write-Host "  [Method 3] diskpart..."
    $dpScript = "select vdisk file=`"$($sel.Path)`"`r`nexpand vdisk maximum=$targetMB`r`nexit"
    $tmp = "$env:TEMP\wsl_dp.txt"
    [System.IO.File]::WriteAllText($tmp, $dpScript, [System.Text.Encoding]::ASCII)
    $dpOut = & diskpart /s $tmp 2>&1
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Host "  $dpOut"
    if ($dpOut -match "successfully") {
        Write-Host "  [Method 3] VHDX expanded." -ForegroundColor Green
        $resized = $true
    } else {
        Write-Host "  [Method 3] diskpart could not expand. VHDX may already be at maximum." -ForegroundColor Yellow
    }
}

# If Methods 2 or 3 expanded the VHDX, still need filesystem resize inside Linux
# Method 1 (wsl --manage) handles this automatically -- skip for that case
if ($resized -and -not ($LASTEXITCODE -eq 0 -and (& wsl.exe --manage --help 2>&1) -ne $null)) {
    # Only try Linux-side resize2fs if we used method 2 or 3
    Write-Host ""
    Write-Host "  Attempting filesystem resize inside WSL2 (requires e2fsprogs in distro)..."
    try {
        $dev = (& wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$1}'" 2>$null).Trim()
        if (-not $dev) { $dev = "/dev/sdd" }

        # Check if resize2fs exists (Alpine needs apk add e2fsprogs)
        $hasResize2fs = (& wsl.exe -- sh -c "command -v resize2fs 2>/dev/null" 2>$null).Trim()
        if ($hasResize2fs) {
            Write-Host "  Running: sudo resize2fs $dev"
            & wsl.exe -- sudo resize2fs $dev
        } else {
            Write-Host "  [WARN] resize2fs not found in distro (Alpine needs: apk add e2fsprogs)" -ForegroundColor Yellow
            Write-Host "  [INFO] If using wsl --manage (Method 1), filesystem was already resized." -ForegroundColor Cyan
            Write-Host "  [INFO] For Alpine: run 'apk add e2fsprogs' then 'sudo resize2fs $dev'" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "  resize2fs skipped." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Step 5: Verify
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Verifying..." -ForegroundColor Yellow
& wsl.exe -- df -h /

$newFree = Get-WslFreeMB
Write-Host ""
if ($newFree -gt 300) {
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  SUCCESS! $newFree MB free." -ForegroundColor Green
    Write-Host "  Next: sh /mnt/host/c/Users/User/Chharbot/wsl-bootstrap.sh" -ForegroundColor Cyan
    Write-Host "  Or: re-run FIX-WSL-DISK.bat" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Green
} else {
    Write-Host "======================================================" -ForegroundColor Yellow
    Write-Host "  [WARN] Free space: $newFree MB -- may still be too low." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Manual fix inside WSL2:" -ForegroundColor White
    Write-Host "    apk add e2fsprogs && sudo resize2fs /dev/sdd" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Or run with a larger target:" -ForegroundColor White
    Write-Host "    powershell -File wsl-expand-disk.ps1 -TargetGB 40 -Auto" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press Enter to exit"
