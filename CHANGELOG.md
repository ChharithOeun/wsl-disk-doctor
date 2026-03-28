# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [1.4.0] - 2026-03-27

### Fixed

- wsl-expand-disk.ps1: Strip \\?\ prefix from BasePath before calling Join-Path.
  Windows registry stores BasePath as \\?\C:\Users\... (extended-length path prefix).
  PowerShell Join-Path parses this with a null drive component and throws
  "Cannot process argument because the value of argument drive is null".
  Fix: $base -replace '^\\\\\?\\ applied before any path construction.
- FIX-WSL-DISK.bat + wsl-expand-disk.ps1: Resize target changed from 20 GB to 50 GB.
  wsl --manage --resize with a target SMALLER than current VHDX virtual disk size
  triggers resize2fs "New size smaller than minimum" and exits E_FAIL.
  Ubuntu-22.04 VHDX virtual disk was already >20 GB so 20 GB was a shrink not a grow.
  50 GB is a safe default grow target for most single-user WSL2 setups.
- wsl-expand-disk.ps1: Default TargetGB changed from 20 to 50.

### Root Cause Documented

BasePath in HKCU registry is stored with the Windows extended-length path prefix \\?\.
PowerShell Join-Path splits the path into drive + rest, and treats \\?\ as a UNC server
with null drive, causing ArgumentNull exceptions. Must strip \\?\ before using the value
in any path API.

## [1.3.0] - 2026-03-27

### Fixed

- FIX-WSL-DISK.bat: Distro name now read from Windows registry instead of `wsl --list --quiet`.
  `wsl --list --quiet` outputs UTF-16LE; cmd.exe `for /f` reads only the first byte ("d"),
  causing `wsl --manage "d" --resize` to fail with "no distribution with that name".
  Fix: PowerShell registry query reads `DistributionName` from
  `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\{DefaultDistribution}`.
- FIX-WSL-DISK.bat: Filters docker-* distros from resize candidates.
  Docker Desktop registers `docker-desktop` and `docker-desktop-data` in the WSL2 registry.
  These cannot be resized with `wsl --manage` (Docker Desktop manages them internally).
- FIX-WSL-DISK.bat: Adds `wsl --update` step before `wsl --manage --resize`.
  `wsl --manage --resize` requires WSL 2.5+. Without updating first, the command silently
  fails on older WSL installs even on Windows 11.
- FIX-WSL-DISK.bat: Step count corrected to 6 (was 5) after adding WSL update step.
- FIX-WSL-DISK.bat: All WSL2 shell commands use `sh` not `bash` (Alpine ships sh, not bash).

### Root Cause Documented

`wsl --list --quiet` emits UTF-16LE with BOM. When cmd.exe `for /f` reads this output,
it interprets the first two bytes (BOM + "B") as "d" (first byte of "docker-desktop").
The result: `wsl --manage "d" --resize 20480` always fails regardless of actual distro name.
Registry-based lookup is the only reliable cross-machine solution.

## [1.2.0] - 2026-03-27

### Fixed

- FIX-WSL-DISK.bat: `wsl --manage` is now the PRIMARY resize method (WSL 2.5+).
  Previously buried as third fallback -- now tried first before diskpart or Resize-VHD.
  This handles both VHDX and filesystem resize from Windows with no Linux tools needed.
- FIX-WSL-DISK.bat: Detects distro name via `wsl --list --quiet` before resize attempt.
  Previously used folder GUID name which `wsl --manage` does not accept.
- FIX-WSL-DISK.bat: Skips resize entirely if >= 500 MB already free (jumps to bootstrap).
- FIX-WSL-DISK.bat: Added full WSL2 installation flow for fresh machines.
  Runs `wsl --install` if WSL2 not detected, with clear restart instructions.
- wsl-expand-disk.ps1: Uses `sh` not `bash` for all device detection commands.
  Alpine Linux does not ship bash by default -- previous commands silently failed.
- wsl-expand-disk.ps1: Detects when `resize2fs` is missing in distro (Alpine needs
  `apk add e2fsprogs`) and prints exact install command instead of failing silently.
- wsl-expand-disk.ps1: Added `--ResizeOnly` flag to skip VHDX expansion and only
  run filesystem resize (useful when VHDX is already large enough).
- wsl-expand-disk.ps1: MISMATCH detection: shows VHDX GB vs filesystem MB side-by-side
  when VHDX is large but filesystem is tiny (common after failed/partial WSL2 setup).
- All .bat and .ps1 files: verified pure 7-bit ASCII before every commit.
  Unicode box-drawing chars (UTF-8) cause silent exit on Windows CP1252 systems.

### Root Cause Documented

Alpine Linux does not include `e2fsprogs` (which provides `resize2fs`).
Chicken-and-egg: cannot `apk add e2fsprogs` when disk is full.
Solution: `wsl --manage <distro> --resize <MB>` handles everything from Windows
without needing any tools inside the Linux distro.

## [1.1.0] - 2026-03-27

### Added

- FIX-WSL-DISK.bat: one-click automatic fix (self-elevates, expands, bootstraps, verifies)
- CHANGELOG.md: Keep a Changelog format, auto-updated via GitHub Actions
- TROUBLESHOOTING.md: 7 documented failure modes with exact fix commands
- USE-CASES.md: 5 real-world scenarios (ML dev, Alpine containers, CI/CD, multi-distro)
- fix_wsl_disk.py: cross-platform Python alternative (stdlib only, --dry-run, --list)
- .github/workflows/changelog.yml: auto-updates CHANGELOG on every push to main
- README: one-click section at top, comparison table vs shrink-only tools, SEO keywords

### Fixed

- wsl-expand-disk.ps1: added VHDX-big/filesystem-small mismatch detection
- wsl-expand-disk.ps1: resize2fs now runs after VHDX expansion
- wsl-bootstrap.sh: pre-flight disk check (exits early if < 300 MB)
- wsl-bootstrap.sh: cleans broken partial apk installs before retrying

## [1.0.0] - 2026-03-27

### Added

- wsl-expand-disk.ps1: auto-finds all WSL2 VHDX files and expands them
- wsl-bootstrap.sh: minimal Python+JAX install (80MB, no compiler needed)
- pre-flight disk check exits early with fix steps if < 300MB free
- auto-detects Alpine/Ubuntu/Fedora/Arch package manager
- AMD GPU env vars (HSA_OVERRIDE_GFX_VERSION=10.3.0) for RX 5700 XT

[1.4.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ChharithOeun/wsl-disk-doctor/releases/tag/v1.0.0
