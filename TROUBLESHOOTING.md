# WSL2 Disk Doctor - Troubleshooting Guide

This guide covers the most common failures when expanding WSL2 disks and bootstrapping Python/ML environments.

---

## The 7 Most Common Failures

### Failure 1: wsl-expand-disk.ps1 says "must run as Administrator"

**Cause:**
The script is not running with elevated privileges.

**Fix:**
Right-click the PowerShell window and select "Run as Administrator" OR:
1. Click the Start menu
2. Search for "PowerShell"
3. Right-click on "Windows PowerShell"
4. Select "Run as Administrator"
5. Navigate to your wsl-disk-doctor folder: `cd path\to\wsl-disk-doctor`
6. Run the script: `powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1`

---

### Failure 2: "No VHDX files found"

**Cause:**
WSL2 is not installed, or no WSL2 distros have been launched yet.

**Fix:**
1. Check which distros are installed:
   ```
   wsl --list
   ```
2. If the list is empty, install WSL2:
   ```
   wsl --install
   ```
3. If distros are listed but no VHDX files found, launch a distro first:
   ```
   wsl -d <distro-name>
   ```
   (where `<distro-name>` is from the list above)
4. Exit WSL2 by typing `exit`
5. Run the expansion script again

---

### Failure 3: resize2fs fails after expansion

**Cause:**
Newer WSL2 kernels automatically resize the filesystem after VHDX expansion. This is normal behavior, not an error.

**Fix:**
1. Check the actual filesystem size:
   ```
   wsl -- df -h /
   ```
2. If it shows the new size you requested (e.g., 20GB), you're done -- the expansion worked.
3. If it still shows the old size, manually resize:
   ```
   wsl -- sudo resize2fs $(wsl -- df / | tail -1 | awk '{print $1}')
   ```

---

### Failure 4: wsl-bootstrap.sh fails with "still no space"

**Cause:**
The VHDX was expanded but the Linux filesystem was not resized, OR the target size was too small for the package manager cache and the install.

**Fix:**
Option A: Manually resize the filesystem (if it wasn't auto-resized):
```
wsl -- sudo resize2fs $(wsl -- df / | tail -1 | awk '{print $1}')
```
Then run bootstrap again:
```
sh wsl-bootstrap.sh
```

Option B: Expand to a larger size (default is 20GB):
```
powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1 -TargetGB 40
```
Then retry bootstrap.

---

### Failure 5: apk says "No space left" again after expansion

**Cause:**
The bootstrap script encountered a broken partial install state and the package manager cache is still full.

**Fix:**
Inside WSL2, clean the package manager state:
```
apk fix
apk cache clean
rm -rf /var/cache/apk/*
```
Then run bootstrap again:
```
sh wsl-bootstrap.sh
```

---

### Failure 6: python3 not found after bootstrap

**Cause:**
The package manager partially installed python3 but extraction failed mid-way (likely due to a disk space spike during install).

**Fix:**
Inside WSL2, remove and reinstall python3:
```
apk del python3
apk add python3
```
Or, if using Ubuntu/Debian:
```
sudo apt remove python3
sudo apt install python3
```

Then verify:
```
python3 --version
```

---

### Failure 7: JAX import fails after pip install

**Cause:**
pip install was interrupted before completion, or the disk filled during download and extraction of JAX wheels.

**Fix:**
Clear the pip cache and reinstall without using local cache:
```
pip cache purge
pip install jax jaxlib --no-cache-dir
```

Then verify:
```
python3 -c "import jax; print(jax.__version__)"
```

---

## How to Check Disk Space Inside WSL2

Run this command inside WSL2 to see space usage:

```
df -h /
```

Output looks like:
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdc        20G   3.2G   16G  17%  /
```

Key values:
- **Size**: Total disk size (this should increase after expansion)
- **Used**: Currently used space
- **Avail**: Free space (bootstrap needs at least 300MB available)
- **Use%**: Percentage used (if this is >90%, risk of failures)

For more detailed breakdown by top directories:
```
du -sh /* | sort -h
```

---

## How to Find Your VHDX File Manually

WSL2 stores VHDX files in several locations depending on your distro.

### For Microsoft Store distros (Ubuntu, Alpine, Fedora):

Look in: `%LOCALAPPDATA%\Packages\`

Example path for Ubuntu:
```
C:\Users\YourUsername\AppData\Local\Packages\CanonicalGroupLimited.UbuntuonWindows_79rhkp1fndgsc\LocalState\ext4.vhdx
```

### For distros installed with `wsl --import`:

Look in: `%LOCALAPPDATA%\wsl\distros\`

Example:
```
C:\Users\YourUsername\AppData\Local\wsl\distros\my-alpine\ext4.vhdx
```

### Find all VHDX files (PowerShell):

```powershell
Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
Get-ChildItem -Path "$env:LOCALAPPDATA\wsl" -Recurse -Filter "*.vhdx" -ErrorAction SilentlyContinue
```

---

## How to Completely Reset a WSL2 Distro

**WARNING**: This deletes all data in the distro.

If a distro is completely broken (even after cleanup attempts), unregister and reinstall it:

```
wsl --unregister <distro-name>
```

Then reinstall:
```
wsl --install -d <distro-name>
```

List all distros:
```
wsl --list --all
```

---

## Exit Codes from wsl-expand-disk.ps1

The PowerShell script returns the following exit codes:

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Success | VHDX expanded and filesystem resized |
| 1 | Not Administrator | Re-run as Administrator (see Failure 1) |
| 2 | No VHDX files found | Install or launch a WSL2 distro (see Failure 2) |
| 3 | User cancelled | Re-run and select a VHDX to expand |
| 4 | Resize failed | Check Hyper-V is enabled; try manual diskpart (see Failure 3) |
| 5 | resize2fs failed | Kernel may have auto-resized (see Failure 3); verify with `df -h /` |
| 6 | Permission denied | Ensure WSL2 distro is shut down: `wsl --shutdown` then retry |

Check the exit code:
```powershell
powershell -ExecutionPolicy Bypass -File wsl-expand-disk.ps1
echo $LASTEXITCODE
```

---

## Performance Tips

1. **Don't expand to max disk space** - leave 20-30GB free on your Windows drive for OS caching
2. **Close Docker/Hyper-V before expanding** - other tools can lock the VHDX
3. **Disable antivirus scanning on %LOCALAPPDATA%\Packages** - scanning during resize is slow
4. **Keep separate distros for different projects** - avoids monolithic 50GB+ VHDXs

---

## Still Stuck?

1. Check the exit code from wsl-expand-disk.ps1 above
2. Search the README.md keywords for related issues
3. Verify WSL2 is running: `wsl --status`
4. Shut down all distros: `wsl --shutdown`
5. Try the entire process again with a different distro

