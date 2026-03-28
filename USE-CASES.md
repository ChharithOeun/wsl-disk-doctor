# WSL2 Disk Doctor - Real-World Use Cases

This document covers 5 common scenarios where wsl-disk-doctor solves real problems.

---

## Use Case 1: ML/AI Developer Bootstrapping Python Environment

**Symptom:**
You follow a tutorial to install PyTorch or TensorFlow on WSL2 Alpine:
```
apk add python3 py3-pip
pip install torch torchvision torchaudio
```

Halfway through:
```
ERROR: py3-torch-2.1.0-r0: failed to extract usr/lib/python3.11/site-packages/torch: No space left on device
ERROR: System state may be inconsistent: failed to write database: No space left on device
```

Your WSL2 distro is now broken and half-installed.

**Solution Path:**

1. **On Windows** (Administrator PowerShell):
   ```powershell
   powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1 -TargetGB 30
   ```
   Expands from default 20GB to 30GB (enough for ML libraries).

2. **Inside WSL2** (after expansion):
   ```sh
   sh wsl-bootstrap.sh
   ```
   Cleans the broken state, installs minimal Python+JAX, verifies with a math benchmark.

3. **Now you have clean slate**:
   ```
   pip install torch torchvision  # Now succeeds
   ```

**Why This Works:**
- The APK package manager was starved for disk space during extraction
- Bootstrap cleans the broken database state before retrying
- Expansion gives breathing room for large wheels (PyTorch is 800MB+)

---

## Use Case 2: Alpine Linux WSL2 Distro for Minimal Containers

**Scenario:**
You're building container images on WSL2 and want to test them locally first. Alpine is only 80MB on disk but wasted no space on a full dev environment.

**Setup:**
1. Install Alpine on WSL2:
   ```
   wsl --install -d Alpine
   ```

2. Expand once (since Alpine grows slowly):
   ```powershell
   powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1 -TargetGB 25
   ```

3. Bootstrap it:
   ```
   sh wsl-bootstrap.sh
   ```

**After bootstrap:**
- Alpine remains ~300MB used on disk
- Python3, pip, JAX pre-installed
- You can layer on container tooling (Docker client, buildkit) without bloat

**Benefit:**
Keep Alpine minimal even after adding Python:
```
df -h /       # Shows ~5GB used, not 20GB
du -sh /* | sort -h   # See exactly what's using space
```

**Keeping it Minimal:**
```
apk del make gcc g++ perl      # Remove build tools after compile
apk cache clean                 # Clear package download cache
rm -rf /var/cache/apk/*        # Remove all package manager artifacts
```

Result: A 300MB-on-disk WSL2 Alpine distro with Python, JAX, and room for projects.

---

## Use Case 3: CI/CD Pipeline on WSL2

**Scenario:**
You're running GitHub Actions runners or GitLab runners on WSL2 for Windows developers. The runners cache build artifacts and download large dependencies.

**Problem:**
After 100+ builds, the runner workspace fills up mid-job:
```
[2026-03-27T14:32:00] pip install large-library
error: No space left on device
```

**Solution with wsl-disk-doctor:**

1. **Expand proactively:**
   ```powershell
   # From a scheduled maintenance task
   powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1 -TargetGB 50
   ```

2. **Setup bootstrap for clean initial state:**
   ```sh
   # In your CI runner initialization script
   sh wsl-bootstrap.sh
   ```

3. **Add periodic cleanup in runner config:**
   ```sh
   # Runs between jobs to free space
   apk cache clean && rm -rf /tmp/* && pip cache purge
   ```

**Non-Interactive Mode:**
Both scripts work in automation:
- `wsl-expand-disk.ps1` with pre-selected distro (no prompts)
- `wsl-bootstrap.sh` with error codes (0=success, 1=fail, exits cleanly)

**Benefits:**
- Prevent surprise disk-full failures mid-pipeline
- Keep runner distros lean (80MB base, not 10GB bloat)
- Fast bootstrap of clean state between resets

---

## Use Case 4: Multiple WSL2 Distros (Ubuntu + Alpine)

**Scenario:**
You have 3 distros on one Windows machine:
- `Ubuntu` - for general development
- `Alpine` - for testing minimal deployments
- `Alpine-ML` - custom Alpine with ML libraries

Each needs different amounts of disk space.

**Problem:**
Default VHDX size (20GB) is too small for Ubuntu+Alpine combined, but expanding all at once wastes space on Alpine.

**Solution:**

1. **List all distros:**
   ```
   wsl --list
   ```

2. **Run expand script:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
   ```
   It shows:
   ```
   Found 3 VHDX files:
   1. Ubuntu [C:\...] - Currently 20GB
   2. Alpine [C:\...] - Currently 20GB
   3. Alpine-ML [C:\...] - Currently 20GB

   Which would you like to expand? Enter number (1-3):
   ```

3. **Expand selectively:**
   - Expand Ubuntu to 40GB (for development)
   - Expand Alpine-ML to 30GB (for ML experiments)
   - Leave Alpine at 20GB (minimal testing)

4. **Bootstrap each appropriately:**
   ```
   # Inside Ubuntu: needs dev tools, compilers, full Python
   sh wsl-bootstrap.sh

   # Inside Alpine-ML: already has JAX, skip bootstrap
   # Inside Alpine: minimal, no bootstrap needed
   ```

**Result:**
- Ubuntu: 40GB, full dev environment
- Alpine-ML: 30GB, ML-ready
- Alpine: 20GB, lean and mean

---

## Use Case 5: Recovering a Corrupted WSL2 Install

**Scenario:**
You're mid-install of a large package when the VHDX runs out of space. Now the distro won't boot:

```
[wsl-dispatch] Error: 0x80370102
[wsl] WSL 2 kernel panic
```

The database is corrupted and you can't even `wsl -d <distro>` anymore.

**Recovery Path:**

1. **Try to start distro (it will fail):**
   ```
   wsl -d Ubuntu
   ```

2. **Check distro health:**
   ```
   wsl --list --verbose
   ```
   Shows Ubuntu as `Stopped` with some error.

3. **Shutdown WSL:**
   ```
   wsl --shutdown
   ```

4. **Expand the disk from Windows:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1 -TargetGB 40
   ```

5. **Try to start again:**
   ```
   wsl -d Ubuntu
   ```
   If it boots, run:
   ```
   apk cache clean && apk fix
   ```
   or
   ```
   sudo apt clean && sudo apt --fix-broken install
   ```

6. **If still broken, full reset:**
   ```
   wsl --unregister Ubuntu
   wsl --install -d Ubuntu
   sh wsl-bootstrap.sh
   ```

**Why This Works:**
- More disk space sometimes allows the kernel to repair the journal
- Bootstrap cleans broken package manager state
- Full reset is the nuclear option but only takes 2 minutes

**Prevention:**
Monitor disk space proactively:
```
# Inside WSL2, add to ~/.bashrc or ~/.profile
alias diskcheck='df -h / && echo "---" && du -sh /* | sort -h'
```

---

## Summary: When to Use wsl-disk-doctor

| Situation | Tool | Command |
|-----------|------|---------|
| Distro disk full mid-install | wsl-expand-disk.ps1 | Expand 20GB -> 30GB |
| After expansion, clean broken state | wsl-bootstrap.sh | Install Python+JAX |
| Multiple distros, expand selectively | wsl-expand-disk.ps1 | Choose which distro |
| Automated CI/CD pipeline | Both (non-interactive) | Works in scripts |
| Kernel panic due to corruption | wsl-expand-disk.ps1 | Often fixes on retry |
| After recovery, reset distro | wsl --unregister + bootstrap.sh | Clean slate |

---

## Getting Started with Your Use Case

1. Read the main [README.md](README.md) for installation steps
2. Identify your scenario above
3. Follow the solution path
4. If you hit an error, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

