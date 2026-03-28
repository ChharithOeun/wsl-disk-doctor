# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2026-03-27

### Features

- wsl-expand-disk.ps1 auto-finds all WSL2 VHDX files and expands them
- wsl-bootstrap.sh minimal Python+JAX install (80MB, no compiler needed)
- pre-flight disk check exits early with fix steps if < 300MB free
- auto-detects Alpine/Ubuntu/Fedora/Arch package manager
- AMD GPU env vars (HSA_OVERRIDE_GFX_VERSION=10.3.0) for RX 5700 XT

[1.0.0]: https://github.com/yourusername/wsl-disk-doctor/releases/tag/v1.0.0
