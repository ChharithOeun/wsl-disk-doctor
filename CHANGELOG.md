# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

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

[1.2.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ChharithOeun/wsl-disk-doctor/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ChharithOeun/wsl-disk-doctor/releases/tag/v1.0.0
