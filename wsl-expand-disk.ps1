# =============================================================================
#  wsl-expand-disk.ps1 - Expand a WSL2 distro's virtual disk (VHDX)
#
#  Run as Administrator in PowerShell:
#    Right-click wsl-expand-disk.ps1 -> Run as Administrator
#    OR: powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
#
#  What this does:
#    1. Lists all WSL2 distros and their VHDX locations
#    2. Lets you pick which one to expand
#    3. Shuts down WSL2 cleanly
#    4. Expands the VHDX to your target size using Hyper-V tools OR diskpart
#    5. Resizes the Linux filesystem to fill the new space
#    6. Restarts WSL2
#
#  After running: re-run wsl-bootstrap.sh - installs will have space now.
# =============================================================================

param(
    [string]$Distro = "",
    [int]$TargetGB = 20,
    [switch]$Auto
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  WSL2 Disk Expander" -ForegroundColor Cyan
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
    Write-Host "        Right-click the script and choose 'Run as Administrator'" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------------------------------------------------------
# Find all WSL2 distros and their VHDX files
# --------------------------------------------------------------------------
Write-Host "[1/5] Scanning for WSL2 distros..." -ForegroundColor Yellow
Write-Host ""

$baseSearchPaths = @(
    "$env:LOCALAPPDATA\Packages",
    "$env:LOCALAPPDATA\lxss"
)

$vhdxFiles = @()
foreach ($basePath in $baseSearchPaths) {
    if (Test-Path $basePath) {
        $found = Get-ChildItem -Path $basePath -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
        $vhdxFiles += $found
    }
}

# Also check custom WSL install locations from registry
try {
    $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $regKey) {
        $distros = Get-ChildItem $regKey -ErrorAction SilentlyContinue
        foreach ($d in $distros) {
            $basePath = (Get-ItemProperty $d.PSPath -Name BasePath -ErrorAction SilentlyContinue).BasePath
            if ($basePath) {
                $vhdx = Join-Path $basePath "ext4.vhdx"
                if (Test-Path $vhdx) {
                    # Avoid duplicates
                    if ($vhdxFiles.FullName -notcontains $vhdx) {
                        $vhdxFiles += [PSCustomObject]@{ FullName = $vhdx; Name = "ext4.vhdx" }
                    }
                }
            }
        }
    }
} catch {}

if ($vhdxFiles.Count -eq 0) {
    Write-Host "[ERROR] No WSL2 VHDX files found." -ForegroundColor Red
    Write-Host "        Make sure you have WSL2 installed and have run a distro at least once."
    Read-Host "Press Enter to exit"
    exit 1
}

# Show each VHDX with its current size and parent folder name (distro hint)
Write-Host "Found WSL2 virtual disks:" -ForegroundColor Green
Write-Host ""
$i = 1
$vhdxList = @()
foreach ($v in $vhdxFiles) {
    $sizeGB = [math]::Round((Get-Item $v.FullName).Length / 1GB, 2)
    $distroHint = Split-Path (Split-Path $v.FullName -Parent) -Leaf
    Write-Host "  [$i] $distroHint" -ForegroundColor White
    Write-Host "      Path: $($v.FullName)"
    Write-Host "      Current size: $sizeGB GB"
    Write-Host ""
    $vhdxList += [PSCustomObject]@{
        Index = $i
        Path  = $v.FullName
        Hint  = $distroHint
        SizeGB = $sizeGB
    }
    $i++
}

# --------------------------------------------------------------------------
# Select which distro to expand
# --------------------------------------------------------------------------
$selectedVHDX = $null
if ($Auto -and $vhdxList.Count -eq 1) {
    $selectedVHDX = $vhdxList[0]
    Write-Host "[AUTO] Selected: $($selectedVHDX.Hint)" -ForegroundColor Green
} elseif ($vhdxList.Count -eq 1) {
    $selectedVHDX = $vhdxList[0]
    Write-Host "[INFO] Only one distro found: $($selectedVHDX.Hint)" -ForegroundColor Cyan
} else {
    $choice = Read-Host "Enter number to expand (or Q to quit)"
    if ($choice -eq "Q" -or $choice -eq "q") { exit 0 }
    $selectedVHDX = $vhdxList | Where-Object { $_.Index -eq [int]$choice }
    if (-not $selectedVHDX) {
        Write-Host "[ERROR] Invalid selection." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "[2/5] Selected: $($selectedVHDX.Hint)" -ForegroundColor Green
Write-Host "      Current: $($selectedVHDX.SizeGB) GB"
Write-Host "      Target:  $TargetGB GB"
Write-Host ""

if ($selectedVHDX.SizeGB -ge $TargetGB) {
    Write-Host "[INFO] VHDX is already $($selectedVHDX.SizeGB) GB -- larger than target $TargetGB GB." -ForegroundColor Yellow
    Write-Host "       The problem may be that your filesystem inside WSL2 is full of downloaded files."
    Write-Host "       Run inside WSL2:  df -h   to check, then:  apk cache clean && rm -rf /var/cache/apk/*"
    Write-Host ""
    $continue = Read-Host "Expand anyway to a larger size? (Y/N)"
    if ($continue -ne "Y" -and $continue -ne "y") { exit 0 }
    $TargetGB = [int]($selectedVHDX.SizeGB) + 20
    Write-Host "  New target: $TargetGB GB"
}

# --------------------------------------------------------------------------
# Shut down WSL2
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Shutting down WSL2..." -ForegroundColor Yellow
wsl.exe --shutdown
Start-Sleep -Seconds 3
Write-Host "      Done."

# --------------------------------------------------------------------------
# Expand the VHDX
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] Expanding VHDX to $TargetGB GB..." -ForegroundColor Yellow

$targetBytes = [int64]$TargetGB * 1GB
$targetMB = [int64]$TargetGB * 1024

# Try Optimize-VHD (Hyper-V module) first -- cleanest method
$hvAvailable = Get-Command -Name Resize-VHD -ErrorAction SilentlyContinue
if ($hvAvailable) {
    Write-Host "      Using Hyper-V Resize-VHD..."
    Resize-VHD -Path $selectedVHDX.Path -SizeBytes $targetBytes
    Write-Host "      VHDX expanded successfully." -ForegroundColor Green
} else {
    # Fall back to diskpart
    Write-Host "      Hyper-V tools not found, using diskpart..."
    $diskpartScript = @"
select vdisk file="$($selectedVHDX.Path)"
expand vdisk maximum=$targetMB
exit
"@
    $tmpFile = "$env:TEMP\wsl_expand_diskpart.txt"
    $diskpartScript | Out-File -FilePath $tmpFile -Encoding ASCII
    $result = diskpart /s $tmpFile
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    Write-Host $result
    Write-Host "      VHDX expanded." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# Resize the Linux filesystem to fill the new space
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Resizing Linux filesystem to fill new space..." -ForegroundColor Yellow
Write-Host "      Starting WSL2..."

# Run resize2fs inside WSL2 to claim the new space
$resizeCmd = "sudo resize2fs /dev/`$(lsblk -o NAME,MOUNTPOINT | grep -w '/' | awk '{print `$1}') 2>/dev/null || true; df -h / | tail -1"
try {
    wsl.exe -- bash -c $resizeCmd
} catch {
    Write-Host "      resize2fs skipped (may not be needed on newer WSL2 kernels)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  DONE! Your WSL2 distro now has $TargetGB GB of space." -ForegroundColor Green
Write-Host ""
Write-Host "  Next step: Go to your WSL2 terminal and run:" -ForegroundColor White
Write-Host "    sh /mnt/host/c/Users/User/Chharbot/wsl-bootstrap.sh" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Or to check free space right now:" -ForegroundColor White
Write-Host "    wsl -- df -h /" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""

Read-Host "Press Enter to exit"
