#!/bin/sh
# =============================================================================
#  wsl-bootstrap.sh - Fix bare WSL2 distro: Python 3, pip, JAX
#  Works on: Alpine (apk), Debian/Ubuntu (apt), Fedora (dnf), Arch (pacman)
#
#  MINIMAL install - no gcc, no g++, no git (~80MB vs ~400MB with build tools)
#  JAX ships pre-built wheels so no compiler is needed.
#
#  Run from inside WSL2:
#    sh /mnt/host/c/Users/User/Chharbot/wsl-bootstrap.sh
#
#  If you get "No space left on device":
#    1. Close WSL2
#    2. Right-click wsl-expand-disk.ps1 -> Run as Administrator
#    3. Re-run this script
# =============================================================================

set -e

REPO="/mnt/host/c/Users/User/Chharbot/jax-amd-gpu-setup"
RESULTS="$REPO/RESULTS"
LOG="/mnt/host/c/Users/User/Chharbot/wsl-bootstrap.log"

log() { echo "$1"; echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>/dev/null || true; }

echo "" > "$LOG" 2>/dev/null || LOG="/tmp/wsl-bootstrap.log"

echo ""
echo "============================================="
echo "  Chharbot WSL2 Bootstrap (minimal install)"
echo "  ~80MB total - no compiler needed"
echo "============================================="
echo ""
log "[START] $(date)"

# --------------------------------------------------------------------------
# Check available disk space before starting
# --------------------------------------------------------------------------
AVAIL_MB=$(df / 2>/dev/null | tail -1 | awk '{print int($4/1024)}')
log "[INFO] Available disk space: ${AVAIL_MB} MB"
echo "  Available disk: ${AVAIL_MB} MB"
if [ "$AVAIL_MB" -lt 300 ]; then
    echo ""
    echo "  [ERROR] Less than 300MB free. Install will fail."
    echo ""
    echo "  Fix (on Windows, run as Admin):"
    echo "    Right-click Chharbot\\wsl-expand-disk.ps1 -> Run as Administrator"
    echo "  Then re-run this script."
    log "[ERROR] Disk too full: ${AVAIL_MB}MB available, need 300MB+"
    exit 1
fi
echo ""

# --------------------------------------------------------------------------
# Step 1: Detect package manager
# --------------------------------------------------------------------------
log "[1/6] Detecting distribution..."
echo "[1/6] Detecting distribution..."

PKG_MGR=""
DISTRO=""
if command -v apk > /dev/null 2>&1; then
    PKG_MGR="apk"
    DISTRO="Alpine"
elif command -v apt-get > /dev/null 2>&1; then
    PKG_MGR="apt"
    DISTRO="Debian/Ubuntu"
elif command -v dnf > /dev/null 2>&1; then
    PKG_MGR="dnf"
    DISTRO="Fedora/RHEL"
elif command -v pacman > /dev/null 2>&1; then
    PKG_MGR="pacman"
    DISTRO="Arch"
else
    log "[ERROR] No known package manager found"
    echo "[ERROR] Could not detect package manager (tried: apk, apt-get, dnf, pacman)"
    exit 1
fi

log "  Detected: $DISTRO ($PKG_MGR)"
echo "  Detected: $DISTRO ($PKG_MGR)"
echo ""

# --------------------------------------------------------------------------
# Step 2: Clean package cache first (free up space from failed installs)
# --------------------------------------------------------------------------
log "[2/6] Cleaning package cache..."
echo "[2/6] Cleaning any failed/partial installs..."

if [ "$PKG_MGR" = "apk" ]; then
    apk cache clean 2>/dev/null || true
    rm -rf /var/cache/apk/* 2>/dev/null || true
    apk fix 2>/dev/null || true
elif [ "$PKG_MGR" = "apt" ]; then
    apt-get clean -q 2>/dev/null || true
fi

AVAIL_MB=$(df / 2>/dev/null | tail -1 | awk '{print int($4/1024)}')
log "  Disk after cleanup: ${AVAIL_MB}MB"
echo "  Disk after cleanup: ${AVAIL_MB} MB free"
echo ""

# --------------------------------------------------------------------------
# Step 3: Install Python 3 + pip ONLY (minimal, no compiler)
# --------------------------------------------------------------------------
log "[3/6] Installing Python 3 + pip (minimal)..."
echo "[3/6] Installing Python 3 + pip..."
echo "      (no gcc/g++ - JAX uses pre-built wheels)"
echo ""

if [ "$PKG_MGR" = "apk" ]; then
    apk add --no-cache python3 py3-pip
elif [ "$PKG_MGR" = "apt" ]; then
    apt-get update -q
    apt-get install -y -q --no-install-recommends python3 python3-pip python3-venv
elif [ "$PKG_MGR" = "dnf" ]; then
    dnf install -y python3 python3-pip
elif [ "$PKG_MGR" = "pacman" ]; then
    pacman -Sy --noconfirm python python-pip
fi

PY_VER=$(python3 --version 2>&1)
PIP_VER=$(python3 -m pip --version 2>&1 | cut -d' ' -f1-2)
log "  $PY_VER | $PIP_VER"
echo ""
echo "  $PY_VER"
echo "  $PIP_VER"
echo ""

# --------------------------------------------------------------------------
# Step 4: Upgrade pip, install JAX CPU
# --------------------------------------------------------------------------
log "[4/6] Installing JAX..."
echo "[4/6] Installing JAX (CPU wheels, ~200MB)..."
echo "      This may take 2-5 minutes on first run."
echo ""

python3 -m pip install --upgrade pip --quiet
python3 -m pip install jax jaxlib --quiet

JAX_VER=$(python3 -c "import jax; print(jax.__version__)" 2>&1)
log "  JAX $JAX_VER"
echo ""
echo "  JAX $JAX_VER installed."
echo ""

# --------------------------------------------------------------------------
# Step 5: Set AMD environment (RX 5700 XT gfx1010)
# --------------------------------------------------------------------------
log "[5/6] Configuring AMD env vars..."
echo "[5/6] Configuring AMD GPU environment..."

if [ -f "$HOME/.bashrc" ]; then
    PROFILE_FILE="$HOME/.bashrc"
elif [ -f "$HOME/.profile" ]; then
    PROFILE_FILE="$HOME/.profile"
else
    touch "$HOME/.profile"
    PROFILE_FILE="$HOME/.profile"
fi

if ! grep -q "HSA_OVERRIDE_GFX_VERSION" "$PROFILE_FILE" 2>/dev/null; then
    printf '\n# Chharbot AMD GPU workarounds (RX 5700 XT = gfx1010)\n' >> "$PROFILE_FILE"
    printf 'export HSA_OVERRIDE_GFX_VERSION=10.3.0\n' >> "$PROFILE_FILE"
    printf 'export XLA_FLAGS="--xla_gpu_enable_triton_gemm=false"\n' >> "$PROFILE_FILE"
    printf 'export MIOPEN_USER_DB_PATH=/tmp/miopen-cache\n' >> "$PROFILE_FILE"
    printf 'export JAX_COMPILATION_CACHE_DIR=/tmp/jax-cache\n' >> "$PROFILE_FILE"
    printf 'export HIP_VISIBLE_DEVICES=0\n' >> "$PROFILE_FILE"
    log "  Wrote AMD env vars to $PROFILE_FILE"
    echo "  Wrote AMD env vars to $PROFILE_FILE"
else
    log "  AMD env vars already present"
    echo "  AMD env vars already present -- skipping."
fi

export HSA_OVERRIDE_GFX_VERSION=10.3.0
export XLA_FLAGS="--xla_gpu_enable_triton_gemm=false"
export MIOPEN_USER_DB_PATH=/tmp/miopen-cache
export JAX_COMPILATION_CACHE_DIR=/tmp/jax-cache
export HIP_VISIBLE_DEVICES=0
mkdir -p /tmp/miopen-cache /tmp/jax-cache
echo ""

# --------------------------------------------------------------------------
# Step 6: Run CPU benchmark
# --------------------------------------------------------------------------
log "[6/6] Running CPU benchmark..."
echo "[6/6] Running CPU math verification (~30 seconds)..."
echo ""

if [ -f "$REPO/scripts/research_failure_suite.py" ]; then
    mkdir -p "$RESULTS"
    python3 "$REPO/scripts/research_failure_suite.py" \
        --cpu-only --quick \
        --output-dir "$RESULTS"
    RESULT_FILE=$(ls -t "$RESULTS"/*.json 2>/dev/null | head -1)
    log "[OK] Result saved: $RESULT_FILE"
    echo ""
    echo "  Result saved: $RESULT_FILE"
else
    log "[WARN] research_failure_suite.py not found at $REPO/scripts/"
    echo "  [WARN] research_failure_suite.py not found."
    echo "         Run: git -C '$REPO' pull"
fi

AVAIL_FINAL=$(df / 2>/dev/null | tail -1 | awk '{print int($4/1024)}')
log "[DONE] Disk remaining: ${AVAIL_FINAL}MB"

echo ""
echo "============================================="
echo "  Done! Bootstrap complete."
echo ""
echo "  Disk remaining: ${AVAIL_FINAL} MB"
echo "  Log: $LOG"
echo ""
echo "  Now:"
echo "   - Close WSL2"
echo "   - Double-click RUN-BENCHMARK.bat"
echo "   - It will find Python+JAX and run cleanly"
echo ""
echo "  For GPU support (ROCm) later:"
echo "    python3 '$REPO/setup_env.py' --rocm"
echo "============================================="
echo ""
