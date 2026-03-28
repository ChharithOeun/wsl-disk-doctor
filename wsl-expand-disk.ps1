# =============================================================================
#  wsl-expand-disk.ps1 - Expand WSL2 virtual disk + resize filesystem
#
#  Run as Administrator:
#    Right-click -> Run as Administrator
#    OR: powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
#
#  What this does:
#    1. Reads ALL WSL2 distros directly from the Windows registry
#       (bypasses wsl --list encoding issues, finds small VHDXs too)
#    2. Skips docker-* distros (Docker Desktop manages its own, cannot be resized)
#    3. Updates WSL to 2.5+ so wsl --manage --resize is available
#    4. Resizes your distro with wsl --manage (handles VHDX + filesystem together)
#    5. Falls back to Resize-VHD or diskpart if wsl --manage unavailable
#    6. Verifies free space is actually available before exiting
# =============================================================================

param(
    [string]$DistroName = "",
    [int]$TargetGB      = 20,
    [switch]$Auto
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
    Write-Host "        Right-click -> Run as Administrator"
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Step 1: Read ALL distros directly from registry
#
# Why registry and not wsl --list:
#   wsl --list --quiet outputs UTF-16LE. cmd.exe for/f only reads
#   the first byte ('d' from 'docker-desktop'). Registry gives
#   proper strings with no encoding conversion needed.
#
# Registry structure:
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss
#     DefaultDistribution  REG_SZ  {guid-of-default}
#     \{guid}\
#         DistributionName  REG_SZ  "BBoy-PopTart"
#         BasePath          REG_SZ  "C:\Users\User\AppData\Local\..."
# --------------------------------------------------------------------------
Write-Host "[1/5] Reading WSL2 distros from registry..." -ForegroundColor Yellow
Write-Host ""

$lxssKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
if (-not (Test-Path $lxssKey)) {
    Write-Host "[ERROR] WSL2 registry key not found." -ForegroundColor Red
    Write-Host "        WSL2 is not installed. Run: wsl --install"
    Read-Host "Press Enter to exit"
    exit 1
}

$defaultGuid = (Get-ItemProperty $lxssKey -ErrorAction SilentlyContinue).DefaultDistribution

$allDistros = Get-ChildItem $lxssKey -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    $name  = $props.DistributionName
    $base  = $props.BasePath
    $guid  = $_.PSChildName
    if ($name -and $base) {
        $vhdx    = Join-Path $base "ext4.vhdx"
        $vhdxExists = Test-Path $vhdx
        $vhdxMB  = if ($vhdxExists) { [math]::Round((Get-Item $vhdx).Length / 1MB, 0) } else { 0 }
        [PSCustomObject]@{
            Name       = $name
            GUID       = $guid
            BasePath   = $base
            VHDX       = $vhdx
            VHDXExists = $vhdxExists
            VHDXMB     = $vhdxMB
            IsDefault  = ($guid -eq $defaultGuid)
            IsDocker   = ($name -like "docker-*")
        }
    }
} | Where-Object { $_ -ne $null }

if ($allDistros.Count -eq 0) {
    Write-Host "[ERROR] No WSL2 distros found in registry." -ForegroundColor Red
    Write-Host "        Install a distro first: wsl --install"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "  All registered distros:" -ForegroundColor White
foreach ($d in $allDistros) {
    $defaultMark = if ($d.IsDefault) { " [DEFAULT]" } else { "" }
    $dockerMark  = if ($d.IsDocker)  { " [DOCKER - will skip]" } else { "" }
    $vhdxInfo    = if ($d.VHDXExists) { "$($d.VHDXMB) MB" } else { "VHDX not found" }
    Write-Host "    $($d.Name)$defaultMark$dockerMark -- VHDX: $vhdxInfo"
}
Write-Host ""

# Filter out Docker-managed distros (cannot be resized with wsl --manage)
$userDistros = $allDistros | Where-Object { -not $_.IsDocker }

if ($userDistros.Count -eq 0) {
    Write-Host "[ERROR] No user-managed distros found (only Docker distros, which cannot be resized)." -ForegroundColor Red
    Write-Host "        Install a WSL2 distro: wsl --install ubuntu"
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Step 2: Select distro to resize
# --------------------------------------------------------------------------
$sel = $null
if ($DistroName) {
    $sel = $userDistros | Where-Object { $_.Name -eq $DistroName }
    if (-not $sel) {
        Write-Host "[ERROR] Distro '$DistroName' not found." -ForegroundColor Red
        exit 1
    }
} elseif ($Auto -or $userDistros.Count -eq 1) {
    # Auto: prefer the default distro, otherwise take the first user distro
    $sel = $userDistros | Where-Object { $_.IsDefault } | Select-Object -First 1
    if (-not $sel) { $sel = $userDistros[0] }
    Write-Host "[AUTO] Selected: $($sel.Name) (default distro)" -ForegroundColor Green
} else {
    $i = 1
    foreach ($d in $userDistros) {
        $mark = if ($d.IsDefault) { " [DEFAULT]" } else { "" }
        Write-Host "  [$i] $($d.Name)$mark -- VHDX: $($d.VHDXMB) MB"
        $i++
    }
    Write-Host ""
    $choice = Read-Host "Enter number (Q to quit)"
    if ($choice -match '^[Qq]') { exit 0 }
    $sel = @($userDistros)[[int]$choice - 1]
    if (-not $sel) { Write-Host "[ERROR] Invalid." -ForegroundColor Red; exit 1 }
}

Write-Host ""
Write-Host "[2/5] Target: $($sel.Name)" -ForegroundColor Green
Write-Host "      VHDX:   $($sel.VHDX)"
Write-Host "      Size:   $($sel.VHDXMB) MB"
Write-Host "      Goal:   $TargetGB GB ($([int]$TargetGB * 1024) MB)"
Write-Host ""

# --------------------------------------------------------------------------
# Step 3: Update WSL to get wsl --manage support (WSL 2.5+)
# --------------------------------------------------------------------------
Write-Host "[3/5] Updating WSL to ensure wsl --manage is available..." -ForegroundColor Yellow
try {
    $updateOut = & wsl.exe --update 2>&1
    Write-Host "      $updateOut"
} catch {
    Write-Host "      wsl --update skipped: $_" -ForegroundColor Yellow
}
Write-Host ""

# Shut down WSL cleanly before resize
Write-Host "      Shutting down WSL2..."
& wsl.exe --shutdown
Start-Sleep -Seconds 3

# --------------------------------------------------------------------------
# Step 4: Resize -- wsl --manage is primary (handles VHDX + filesystem)
# --------------------------------------------------------------------------
Write-Host "[4/5] Resizing $($sel.Name) to $TargetGB GB..." -ForegroundColor Yellow
$targetMB    = [int64]$TargetGB * 1024
$targetBytes = [int64]$TargetGB * 1073741824
$resized     = $false

# Method 1: wsl --manage (WSL 2.5+) -- resizes VHDX AND filesystem in one command
Write-Host "  [Method 1] wsl --manage '$($sel.Name)' --resize $targetMB"
try {
    $out = & wsl.exe --manage $sel.Name --resize $targetMB 2>&1
    Write-Host "  Result: $out"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [Method 1] SUCCESS -- VHDX and filesystem both resized." -ForegroundColor Green
        $resized = $true
    } else {
        Write-Host "  [Method 1] Failed (exit $LASTEXITCODE). WSL may be < 2.5. Run: wsl --update" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [Method 1] Error: $_" -ForegroundColor Yellow
}

# Method 2: Resize-VHD (Hyper-V) + manual resize2fs after
if (-not $resized -and $sel.VHDXExists) {
    $hvCmd = Get-Command -Name Resize-VHD -ErrorAction SilentlyContinue
    if ($hvCmd) {
        Write-Host "  [Method 2] Resize-VHD (Hyper-V)..."
        try {
            Resize-VHD -Path $sel.VHDX -SizeBytes $targetBytes
            Write-Host "  [Method 2] VHDX expanded. (NOTE: filesystem resize still needed inside WSL2)" -ForegroundColor Green
            Write-Host "             Run inside WSL2: apk add e2fsprogs && sudo resize2fs /dev/sdd" -ForegroundColor Cyan
            $resized = $true
        } catch {
            Write-Host "  [Method 2] Failed: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [Method 2] Hyper-V not installed." -ForegroundColor Yellow
    }
}

# Method 3: diskpart (legacy -- only works on non-Docker VHDXs, may fail on dynamic disks)
if (-not $resized -and $sel.VHDXExists) {
    Write-Host "  [Method 3] diskpart..."
    $dpScript = "select vdisk file=`"$($sel.VHDX)`"`r`nexpand vdisk maximum=$targetMB`r`nexit"
    $tmp = "$env:TEMP\wsl_dp_$([guid]::NewGuid()).txt"
    [System.IO.File]::WriteAllText($tmp, $dpScript, [System.Text.Encoding]::ASCII)
    $dpOut = & diskpart /s $tmp 2>&1
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Host "  diskpart output: $dpOut"
    if ($dpOut -match "successfully") {
        Write-Host "  [Method 3] VHDX expanded. Filesystem resize still needed inside WSL2." -ForegroundColor Yellow
        Write-Host "             Inside WSL2: apk add e2fsprogs && sudo resize2fs /dev/sdd" -ForegroundColor Cyan
        $resized = $true
    } else {
        Write-Host "  [Method 3] diskpart also failed." -ForegroundColor Red
        Write-Host "             This usually means WSL2 < 2.5. Run: wsl --update" -ForegroundColor Yellow
    }
}

if (-not $resized) {
    Write-Host ""
    Write-Host "[ERROR] All resize methods failed." -ForegroundColor Red
    Write-Host "  Most likely fix: update WSL2 first" -ForegroundColor Yellow
    Write-Host "    wsl --update"
    Write-Host "  Then re-run this script."
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Step 5: Verify free space actually increased
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Verifying..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
& wsl.exe -- sh -c "df -h /"
Write-Host ""

$freeRaw = (& wsl.exe -- sh -c "df / 2>/dev/null | tail -1 | awk '{print \$4}'" 2>$null).Trim()
$freeKB  = [int64]($freeRaw -replace '\D','')
$freeMB  = [math]::Round($freeKB / 1024, 0)

if ($freeMB -gt 300) {
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  SUCCESS! $freeMB MB free in $($sel.Name)." -ForegroundColor Green
    Write-Host "  Next: re-run FIX-WSL-DISK.bat" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Green
} else {
    Write-Host "======================================================" -ForegroundColor Yellow
    Write-Host "  [WARN] Only $freeMB MB free after resize." -ForegroundColor Yellow
    Write-Host "  If wsl --manage was used, the filesystem should have resized automatically."
    Write-Host "  If Resize-VHD or diskpart was used, run inside WSL2:"
    Write-Host "    apk add e2fsprogs && sudo resize2fs /dev/sdd" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press Enter to exit"
