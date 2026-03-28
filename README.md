# wsl-disk-doctor

**Fix "No space left on device" errors in WSL2 -- then bootstrap Python/ML in 2 steps.**

Most WSL2 disk tools only shrink virtual disks. This one expands them when you're stuck mid-install, cleans up the broken state, and gets you running with minimal footprint.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## The Problem

You're inside WSL2 (Alpine, Ubuntu, etc.) and run `apk add python3` or `apt install`. Halfway through:

```
ERROR: python3-3.12.12-r0: failed to extract usr/lib/libpython3.12.so.1.0: No space left on device
ERROR: System state may be inconsistent: failed to write database: No space left on device
```

Now your distro is in a broken half-installed state. The existing tools (wslcompact, compact-wsl2-disk) only shrink disks -- they can't help you here.

---


## One-Click Automatic Fix (Recommended)

Double-click `FIX-WSL-DISK.bat`. That is all.

It will:
1. Ask Windows for Administrator permission (click Yes)
2. Expand your WSL2 disk automatically
3. Install Python 3 + JAX inside WSL2
4. Verify everything works
5. Save a log to `fix-wsl-disk.log` so you can see exactly what happened

---

## Manual Fix (2 steps, if you prefer)

### Step 1 -- Expand the virtual disk (Windows, run as Admin)

```powershell
# Right-click -> Run as Administrator
powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
```

This script:
- Auto-finds all WSL2 VHDX files on your system (checks `%LOCALAPPDATA%\Packages` + registry)
- Shows current size of each distro
- Expands to your target size using `Resize-VHD` (Hyper-V) or `diskpart` as fallback
- Resizes the Linux filesystem to claim the new space (`resize2fs`)

### Step 2 -- Bootstrap Python + JAX (inside WSL2)

```sh
sh /path/to/wsl-bootstrap.sh
```

This script:
- **Checks disk space first** -- exits with clear instructions if still too full
- **Cleans broken partial installs** (`apk cache clean`, `apk fix`) before retrying
- **Installs only what's needed**: `python3 + pip` -- no gcc, no g++, no git (~80MB vs ~400MB)
- **JAX ships pre-built wheels** -- no compiler required
- Sets AMD GPU env vars automatically (RX 5700 XT / gfx1010 / ROCm)
- Runs a CPU math verification benchmark to confirm everything works

---

## Why Not Just Use wslcompact / compact-wsl2-disk?

| Tool | Shrink VHD | Expand VHD | Fix broken install state | Minimal ML bootstrap |
|------|-----------|-----------|------------------------|---------------------|
| wslcompact | YES | no | no | no |
| compact-wsl2-disk | YES | no | no | no |
| WSL2_Disk_Volume_Optimizer | YES | no | no | no |
| **wsl-disk-doctor** | no | **YES** | **YES** | **YES** |

These tools solve opposite problems. Use wslcompact **after** you have space. Use wsl-disk-doctor **when you run out**.

---

## Supported Distributions

| Distro | Package Manager | Status |
|--------|----------------|--------|
| Alpine Linux | apk | Tested |
| Ubuntu / Debian | apt | Supported |
| Fedora / RHEL | dnf | Supported |
| Arch Linux | pacman | Supported |

---

## Requirements

- **wsl-expand-disk.ps1**: Windows 10/11 with WSL2, Administrator rights
- **wsl-bootstrap.sh**: Any POSIX shell (`sh`, not `bash` required)

---

## Keywords

WSL2 disk full, no space left on device WSL2, WSL2 VHDX expand, WSL2 Alpine apk error, resize WSL2 virtual disk, WSL2 out of space fix, wsl2 disk space, expand ext4.vhdx, WSL2 Python install failed disk full, WSL2 JAX install no space

---

## License

MIT -- see [LICENSE](LICENSE)
