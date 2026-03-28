# =============================================================================
#  wsl-expand-disk.ps1 - Expand a WSL2 distro's virtual disk + resize filesystem
#
#  Run as Administrator in PowerShell:
#    Right-click wsl-expand-disk.ps1 -> Run as Administrator
#    OR: powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
#
#  What this does:
#    1. Lists all WSL2 distros and their VHDX locations
#    2. Checks whether the PROBLEM is the VHDX size OR the filesystem size
#       (These are different! A 53 GB VHDX can have a 135 MB filesystem inside.)
#    3. Expands the VHDX if needed (Resize-VHD, then wsl --manage, then diskpart)
#    4. Resizes the Linux ext4 filesystem to fill the available space (resize2fs)
#    5. Verifies free space is actually available
#
#  After running: re-run wsl-bootstrap.sh - installs will have space now.
# =============================================================================

param(
    [string]$Distro = "",
    [int]$TargetGB = 20,
    [switch]$Auto,
    [switch]$ResizeOnly
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  WSL2 Disk Doctor - Expander + Filesystem Fix" -ForegroundColor Cyan
Write-Host "  Fixes: No space left on device" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------
# Check: must be Administrator
# --------------------------------------------------------------------------
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] This script must run as Administrator." -ForegroundColor Red
    Write-Host "        Right-click the script -> Run as Administrator" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# FAST PATH: --ResizeOnly flag skips VHDX expansion, just does filesystem resize
# --------------------------------------------------------------------------
if ($ResizeOnly) {
    Write-Host "[RESIZE-ONLY] Skipping VHDX expansion, running filesystem resize..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Detecting root device inside WSL2..."
    $dev = (wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$1}'" 2>$null).Trim()
    if (-not $dev) { $dev = "/dev/sdd" }
    Write-Host "  Root device: $dev"
    Write-Host "  Running: sudo resize2fs $dev"
    wsl.exe -- sudo resize2fs $dev
    Write-Host ""
    Write-Host "  Verifying free space..."
    wsl.exe -- df -h /
    Write-Host ""
    Write-Host "[DONE] Filesystem resize complete." -ForegroundColor Green
    Read-Host "Press Enter to exit"
    exit 0
}

# --------------------------------------------------------------------------
# Find all WSL2 distros and their VHDX files
# --------------------------------------------------------------------------
Write-Host "[1/6] Scanning for WSL2 distros..." -ForegroundColor Yellow
Write-Host ""

$vhdxFiles = @()

# Search standard Packages directory
$packagesPath = "$env:LOCALAPPDATA\Packages"
if (Test-Path $packagesPath) {
    $found = Get-ChildItem -Path $packagesPath -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
    $vhdxFiles += $found
}

# Search new WSL directory (Windows 11 22H2+)
$wslPath = "$env:LOCALAPPDATA\wsl"
if (Test-Path $wslPath) {
    $found = Get-ChildItem -Path $wslPath -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
    $vhdxFiles += $found
}

# Search registry for custom install locations
try {
    $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $regKey) {
        $distros = Get-ChildItem $regKey -ErrorAction SilentlyContinue
        foreach ($d in $distros) {
            $basePath = (Get-ItemProperty $d.PSPath -Name BasePath -ErrorAction SilentlyContinue).BasePath
            if ($basePath) {
                $vhdx = Join-Path $basePath "ext4.vhdx"
                if ((Test-Path $vhdx) -and ($vhdxFiles.FullName -notcontains $vhdx)) {
                    $vhdxFiles += [PSCustomObject]@{ FullName = $vhdx; Name = "ext4.vhdx" }
                }
            }
        }
    }
} catch {}

if ($vhdxFiles.Count -eq 0) {
    Write-Host "[ERROR] No WSL2 VHDX files found." -ForegroundColor Red
    Write-Host "        Make sure WSL2 is installed and you have launched a distro at least once."
    Write-Host "        Check: wsl --list --verbose"
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Show distros with BOTH VHDX size AND filesystem free space
# --------------------------------------------------------------------------
Write-Host "Found WSL2 virtual disks:" -ForegroundColor Green
Write-Host ""

$i = 1
$vhdxList = @()
foreach ($v in $vhdxFiles) {
    $vhdxSizeGB = [math]::Round((Get-Item $v.FullName).Length / 1GB, 2)
    $distroHint = Split-Path (Split-Path $v.FullName -Parent) -Leaf

    # Get filesystem free space from inside WSL2
    $fsFreeRaw = wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$4}'" 2>$null
    $fsFreeKB = [int64]($fsFreeRaw -replace '\D','')
    $fsFreeMB = [math]::Round($fsFreeKB / 1024, 1)
    $fsTotalRaw = wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$2}'" 2>$null
    $fsTotalKB = [int64]($fsTotalRaw -replace '\D','')
    $fsTotalMB = [math]::Round($fsTotalKB / 1024, 1)

    $mismatch = ($vhdxSizeGB -gt 1) -and ($fsTotalMB -lt 500)

    Write-Host "  [$i] $distroHint" -ForegroundColor White
    Write-Host "      VHDX file size:     $vhdxSizeGB GB (Windows sees this)"
    Write-Host "      Filesystem total:   $fsTotalMB MB  (Linux sees this)"
    Write-Host "      Filesystem free:    $fsFreeMB MB"
    if ($mismatch) {
        Write-Host "      *** MISMATCH DETECTED: VHDX is $vhdxSizeGB GB but filesystem is only $fsTotalMB MB" -ForegroundColor Red
        Write-Host "          resize2fs will fix this without expanding the VHDX" -ForegroundColor Yellow
    }
    Write-Host ""

    $vhdxList += [PSCustomObject]@{
        Index      = $i
        Path       = $v.FullName
        Hint       = $distroHint
        SizeGB     = $vhdxSizeGB
        FsFreeMB   = $fsFreeMB
        FsTotalMB  = $fsTotalMB
        Mismatch   = $mismatch
    }
    $i++
}

# --------------------------------------------------------------------------
# Select distro
# --------------------------------------------------------------------------
$selectedVHDX = $null
if ($Auto -or $vhdxList.Count -eq 1) {
    $selectedVHDX = $vhdxList[0]
    Write-Host "[AUTO] Selected: $($selectedVHDX.Hint)" -ForegroundColor Green
} else {
    $choice = Read-Host "Enter number to fix (or Q to quit)"
    if ($choice -eq "Q" -or $choice -eq "q") { exit 0 }
    $selectedVHDX = $vhdxList | Where-Object { $_.Index -eq [int]$choice }
    if (-not $selectedVHDX) {
        Write-Host "[ERROR] Invalid selection." -ForegroundColor Red
        exit 1
    }
}

# --------------------------------------------------------------------------
# CASE A: VHDX is big but filesystem is tiny -> resize2fs ONLY, skip VHDX expand
# --------------------------------------------------------------------------
if ($selectedVHDX.Mismatch) {
    Write-Host ""
    Write-Host "[DIAGNOSIS] VHDX=$($selectedVHDX.SizeGB)GB but filesystem=$($selectedVHDX.FsTotalMB)MB" -ForegroundColor Yellow
    Write-Host "            The VHDX already has space. The filesystem just hasn't claimed it yet." -ForegroundColor Yellow
    Write-Host "            Skipping VHDX expansion -- running resize2fs directly." -ForegroundColor Green
    Write-Host ""

    Write-Host "[3/6] Shutting down WSL2 cleanly..." -ForegroundColor Yellow
    wsl.exe --shutdown
    Start-Sleep -Seconds 3

    Write-Host "[4/6] Skipped (VHDX already large enough)" -ForegroundColor Gray

    Write-Host "[5/6] Resizing Linux filesystem to fill VHDX space..." -ForegroundColor Yellow
    Write-Host "      Detecting root device..."

    # Start WSL2, get the root device, run resize2fs on it
    # Use sh not bash (Alpine uses sh)
    $dev = (wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$1}'" 2>$null).Trim()
    if (-not $dev -or $dev -eq "") {
        $dev = "/dev/sdd"
        Write-Host "      Could not detect device, defaulting to /dev/sdd"
    } else {
        Write-Host "      Root device: $dev"
    }

    Write-Host "      Running: sudo resize2fs $dev"
    wsl.exe -- sudo resize2fs $dev

    Write-Host ""
    Write-Host "[6/6] Verifying free space..." -ForegroundColor Yellow
    $output = wsl.exe -- df -h /
    Write-Host $output

    # Parse new free space
    $newFreeRaw = wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$4}'" 2>$null
    $newFreeKB = [int64]($newFreeRaw -replace '\D','')
    $newFreeMB = [math]::Round($newFreeKB / 1024, 0)

    Write-Host ""
    if ($newFreeMB -gt 300) {
        Write-Host "======================================================" -ForegroundColor Green
        Write-Host "  SUCCESS! Filesystem resized." -ForegroundColor Green
        Write-Host "  Free space now: $newFreeMB MB" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Run bootstrap now (in WSL2 terminal):" -ForegroundColor White
        Write-Host "    sh /mnt/host/c/Users/User/Chharbot/wsl-bootstrap.sh" -ForegroundColor Cyan
        Write-Host "  Or just re-run FIX-WSL-DISK.bat" -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Green
    } else {
        Write-Host "======================================================" -ForegroundColor Red
        Write-Host "  [WARN] Free space still low ($newFreeMB MB)." -ForegroundColor Yellow
        Write-Host "  Try manually inside WSL2:" -ForegroundColor White
        Write-Host "    sudo resize2fs $dev" -ForegroundColor Cyan
        Write-Host "    df -h /" -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Yellow
    }

    Read-Host "Press Enter to exit"
    exit 0
}

# --------------------------------------------------------------------------
# CASE B: Filesystem IS the full VHDX (no mismatch) -- need to expand VHDX
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] VHDX expansion needed." -ForegroundColor Yellow
Write-Host "      VHDX: $($selectedVHDX.SizeGB) GB  |  Target: $TargetGB GB"
Write-Host ""

if ($selectedVHDX.SizeGB -ge $TargetGB) {
    Write-Host "[INFO] VHDX already $($selectedVHDX.SizeGB) GB (>= target $TargetGB GB)." -ForegroundColor Yellow
    Write-Host "       But filesystem only has $($selectedVHDX.FsFreeMB) MB free."
    Write-Host "       This may be a data problem -- check inside WSL2: du -sh /* | sort -rh | head -10"
    $TargetGB = [int]($selectedVHDX.SizeGB) + 20
    Write-Host "       Expanding to $TargetGB GB to give headroom..."
}

Write-Host "[3/6] Shutting down WSL2..." -ForegroundColor Yellow
wsl.exe --shutdown
Start-Sleep -Seconds 3
Write-Host "      Done."

Write-Host ""
Write-Host "[4/6] Expanding VHDX to $TargetGB GB..." -ForegroundColor Yellow
$targetBytes  = [int64]$TargetGB * 1073741824  # exact bytes, not PS math
$targetMB     = [int64]$TargetGB * 1024

$expanded = $false

# Method 1: wsl --manage (WSL 2.5+, cleanest)
try {
    $distroName = $selectedVHDX.Hint
    Write-Host "      Trying: wsl --manage '$distroName' --resize $($TargetGB * 1024)..."
    $wslManageResult = & wsl.exe --manage $distroName --resize ($TargetGB * 1024) 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "      Expanded via wsl --manage." -ForegroundColor Green
        $expanded = $true
    }
} catch {}

# Method 2: Resize-VHD (Hyper-V)
if (-not $expanded) {
    $hvCmd = Get-Command -Name Resize-VHD -ErrorAction SilentlyContinue
    if ($hvCmd) {
        try {
            Write-Host "      Trying: Resize-VHD..."
            Resize-VHD -Path $selectedVHDX.Path -SizeBytes $targetBytes
            Write-Host "      Expanded via Resize-VHD." -ForegroundColor Green
            $expanded = $true
        } catch {
            Write-Host "      Resize-VHD failed: $_" -ForegroundColor Yellow
        }
    }
}

# Method 3: diskpart (legacy fallback)
if (-not $expanded) {
    Write-Host "      Trying: diskpart..."
    $dpScript = "select vdisk file=`"$($selectedVHDX.Path)`"`r`nexpand vdisk maximum=$targetMB`r`nexit"
    $tmpFile = "$env:TEMP\wsl_expand.txt"
    [System.IO.File]::WriteAllText($tmpFile, $dpScript, [System.Text.Encoding]::ASCII)
    $dpResult = & diskpart /s $tmpFile 2>&1
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    if ($dpResult -match "successfully" -or $LASTEXITCODE -eq 0) {
        Write-Host "      Expanded via diskpart." -ForegroundColor Green
        $expanded = $true
    } else {
        Write-Host "      diskpart result: $dpResult" -ForegroundColor Yellow
        Write-Host "      [WARN] VHDX expansion may have failed." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Step 5: resize2fs - always run this regardless of expansion method
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] Resizing Linux filesystem (resize2fs)..." -ForegroundColor Yellow

# Use sh (not bash) - works on Alpine
$dev = (wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$1}'" 2>$null).Trim()
if (-not $dev -or $dev -eq "") { $dev = "/dev/sdd" }
Write-Host "      Root device: $dev"
Write-Host "      Running: sudo resize2fs $dev"

wsl.exe -- sudo resize2fs $dev

# --------------------------------------------------------------------------
# Step 6: Verify
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Verifying..." -ForegroundColor Yellow
wsl.exe -- df -h /

$newFreeRaw = wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$4}'" 2>$null
$newFreeKB  = [int64]($newFreeRaw -replace '\D','')
$newFreeMB  = [math]::Round($newFreeKB / 1024, 0)

Write-Host ""
if ($newFreeMB -gt 300) {
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  SUCCESS! $newFreeMB MB free." -ForegroundColor Green
    Write-Host "  Run bootstrap: sh /mnt/host/c/Users/User/Chharbot/wsl-bootstrap.sh" -ForegroundColor Cyan
    Write-Host "  Or re-run FIX-WSL-DISK.bat" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Green
} else {
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host "  [WARN] Still low ($newFreeMB MB)." -ForegroundColor Yellow
    Write-Host "  Try inside WSL2: sudo resize2fs $dev && df -h /" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Yellow
}

Read-Host "Press Enter to exit"
