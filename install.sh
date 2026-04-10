#!/bin/bash
# TETRA module installer for OpenWebRX+ (plugin-based frontend)
# Author: SP8MB
# Installs TETRA voice decoding support on Raspberry Pi / Debian
#
# Usage:
#   sudo bash install.sh              # Full install (backend + plugin)
#   sudo bash install.sh --update     # Update scripts only (no rebuild)
#   sudo bash install.sh --uninstall  # Remove TETRA module
#   sudo bash install.sh --check      # Verify installation

set -e

INSTALL_DIR="/opt/openwebrx-tetra"
OWRX_PYTHON="/usr/lib/python3/dist-packages"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[TETRA]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }

# ??????????????????????????????????????????????????????
# Argument parsing
# ??????????????????????????????????????????????????????
MODE="install"
NO_RESTART=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)    MODE="update"; shift ;;
        --uninstall) MODE="uninstall"; shift ;;
        --check)     MODE="check"; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        -h|--help)
            echo "Usage: sudo bash install.sh [--update|--uninstall|--check] [--no-restart]"
            exit 0
            ;;
        *) error "Unknown option: $1" ;;
    esac
done

# ??????????????????????????????????????????????????????
# Prechecks
# ??????????????????????????????????????????????????????
[[ $EUID -ne 0 ]] && error "This script must be run as root (sudo)"
[[ -f "$OWRX_PYTHON/owrx/modes.py" ]] || error "OpenWebRX+ not found at $OWRX_PYTHON"

# ??????????????????????????????????????????????????????
# Helper: verify installation (backend + plugin)
# ??????????????????????????????????????????????????????
verify_installation() {
    local errors=0
    log "Verifying installation..."

    # Backend binaries
    for f in tetra_decoder.py tetra_demod.py tetra-rx; do
        if [[ -f "$INSTALL_DIR/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f"; errors=$((errors+1)); fi
    done
    for f in cdecoder sdecoder; do
        if [[ -f "$INSTALL_DIR/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f (audio may not work)"; fi
    done
    # CSDR modules
    for f in csdr/module/tetra.py csdr/chain/tetra.py; do
        if [[ -f "$OWRX_PYTHON/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f"; errors=$((errors+1)); fi
    done
    # Python patches
    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/modes.py" 2>/dev/null; then log "  OK  TETRA mode in modes.py"; else warn "  MISSING  TETRA mode"; errors=$((errors+1)); fi
    if grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py" 2>/dev/null; then log "  OK  TETRA feature in feature.py"; else warn "  MISSING  TETRA feature"; errors=$((errors+1)); fi
    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/dsp.py" 2>/dev/null; then log "  OK  TETRA routing in dsp.py"; else warn "  MISSING  TETRA routing"; errors=$((errors+1)); fi
    # Plugin frontend
    if [[ -f "$OWRX_PYTHON/htdocs/plugins/receiver/tetra_panel/tetra_panel.js" ]]; then
        log "  OK  TETRA plugin JS"
    else
        warn "  MISSING  plugin tetra_panel.js"
        errors=$((errors+1))
    fi
    if grep -q "Plugins.load('tetra_panel')" "$OWRX_PYTHON/htdocs/plugins/receiver/init.js" 2>/dev/null; then
        log "  OK  Plugin loader in init.js"
    else
        warn "  MISSING  plugin loader"
        errors=$((errors+1))
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then log "Installation OK"; else warn "Installation has $errors issue(s)"; fi
    return $errors
}

# ??????????????????????????????????????????????????????
# CHECK mode
# ??????????????????????????????????????????????????????
if [[ "$MODE" == "check" ]]; then
    verify_installation
    exit $?
fi

# ??????????????????????????????????????????????????????
# UNINSTALL mode
# ??????????????????????????????????????????????????????
if [[ "$MODE" == "uninstall" ]]; then
    log "=== Uninstalling TETRA module ==="
    rm -f "$OWRX_PYTHON/csdr/module/tetra.py" "$OWRX_PYTHON/csdr/chain/tetra.py"
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py; do
        if [[ -f "$OWRX_PYTHON/$f.bak.pre-tetra" ]]; then
            cp "$OWRX_PYTHON/$f.bak.pre-tetra" "$OWRX_PYTHON/$f"
            log "Restored $f"
        fi
    done
    # Remove plugin
    rm -rf "$OWRX_PYTHON/htdocs/plugins/receiver/tetra_panel"
    sed -i "/Plugins.load('tetra_panel')/d" "$OWRX_PYTHON/htdocs/plugins/receiver/init.js" 2>/dev/null || true
    # Clear cache
    find "$OWRX_PYTHON" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    if [[ -z "$NO_RESTART" ]]; then
        systemctl restart openwebrx 2>/dev/null || warn "Could not restart openwebrx"
    fi
    log "=== Uninstall complete ==="
    exit 0
fi

# ??????????????????????????????????????????????????????
# Source file checks
# ??????????????????????????????????????????????????????
for f in tetra_decoder.py tetra_demod.py csdr_module_tetra.py csdr_chain_tetra.py tetra_panel.js; do
    [[ -f "$SCRIPT_DIR/$f" ]] || error "Missing file: $SCRIPT_DIR/$f"
done

# ??????????????????????????????????????????????????????
# INSTALL / UPDATE mode (backend + plugin)
# ??????????????????????????????????????????????????????

if [[ "$MODE" == "install" ]]; then
    log "=== TETRA Module Installer for OpenWebRX+ ==="

    # Step 1: Dependencies
    log "Step 1/7: Installing system dependencies..."
    apt-get update -qq
    apt-get install -y -qq gnuradio libosmocore-dev build-essential pkg-config git wget unzip python3-dev 2>/dev/null

    # Step 2: Create install dir
    log "Step 2/7: Setting up $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"

    # Step 3: Compile tetra-rx
    log "Step 3/7: Compiling tetra-rx (osmo-tetra)..."
    OSMO_TETRA_SRC="$INSTALL_DIR/osmo-tetra-sq5bpf"
    if [[ ! -d "$OSMO_TETRA_SRC" ]]; then
        git clone --depth 1 https://github.com/sq5bpf/osmo-tetra-sq5bpf "$OSMO_TETRA_SRC" 2>/dev/null || true
    fi
    if [[ -d "$OSMO_TETRA_SRC/src" ]]; then
        cd "$OSMO_TETRA_SRC/src"
        make clean 2>/dev/null || true
        make tetra-rx float_to_bits 2>&1 | tail -5
        cp tetra-rx "$INSTALL_DIR/"
        cp float_to_bits "$INSTALL_DIR/" 2>/dev/null || true
        log "tetra-rx compiled"
    else
        error "Failed to clone osmo-tetra"
    fi

    # Step 4: Build ACELP codec
    log "Step 4/7: Building ETSI ACELP codec..."
    CODEC_DIR="$OSMO_TETRA_SRC/etsi_codec-patches"
    if [[ -d "$CODEC_DIR" && -f "$CODEC_DIR/download_and_patch.sh" ]]; then
        cd "$CODEC_DIR"
        if [[ ! -f "$INSTALL_DIR/cdecoder" ]]; then
            bash download_and_patch.sh 2>&1 | tail -10
            if [[ -d codec ]]; then
                cd codec && make 2>&1 | tail -5
                cp cdecoder sdecoder "$INSTALL_DIR/" 2>/dev/null || true
            fi
        fi
    else
        warn "ETSI codec patches not found – audio may not work"
    fi
else
    log "=== TETRA Module Update (backend only) ==="
fi

# ??????????????????????????????????????????????????????
# Common steps (install & update)
# ??????????????????????????????????????????????????????

STEP_BASE=5
[[ "$MODE" == "update" ]] && STEP_BASE=1

# Deploy decoder scripts
log "Step $STEP_BASE/7: Deploying decoder scripts..."
cp "$SCRIPT_DIR/tetra_decoder.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/tetra_demod.py" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/tetra_decoder.py"

# Install CSDR modules
STEP=$((STEP_BASE + 1))
log "Step $STEP/7: Installing CSDR modules..."
cp "$SCRIPT_DIR/csdr_module_tetra.py" "$OWRX_PYTHON/csdr/module/tetra.py"
cp "$SCRIPT_DIR/csdr_chain_tetra.py" "$OWRX_PYTHON/csdr/chain/tetra.py"

# Patch OpenWebRX+ Python files (modes.py, feature.py, dsp.py)
STEP=$((STEP_BASE + 2))
log "Step $STEP/7: Patching OpenWebRX+ Python files..."

# Backups (first install only)
if [[ "$MODE" == "install" ]]; then
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py; do
        [[ -f "$OWRX_PYTHON/$f" && ! -f "$OWRX_PYTHON/$f.bak.pre-tetra" ]] && cp "$OWRX_PYTHON/$f" "$OWRX_PYTHON/$f.bak.pre-tetra"
    done
    log "  Backups created"
fi

# --- Patch modes.py (add TETRA mode after nxdn line) ---
if ! grep -q '"tetra"' "$OWRX_PYTHON/owrx/modes.py"; then
    log "  Patching modes.py..."
    python3 << 'PYEOF'
modes_file = "/usr/lib/python3/dist-packages/owrx/modes.py"
with open(modes_file, "r") as f:
    lines = f.readlines()

insert_index = -1
indent = None

for i, line in enumerate(lines):
    if 'AnalogMode("nxdn"' in line:
        insert_index = i + 1
        import re
        match = re.match(r'^(\s+)', line)
        indent = match.group(1) if match else '        '
        break

if insert_index == -1:
    for i, line in enumerate(lines):
        if 'AnalogMode(' in line and 'AnalogMode("tetra"' not in line:
            insert_index = i + 1
            import re
            match = re.match(r'^(\s+)', line)
            indent = match.group(1) if match else '        '
            break

if insert_index != -1:
    new_line = f'{indent}AnalogMode("tetra", "TETRA", bandpass=Bandpass(-12500, 12500), requirements=["tetra_decoder"], squelch=False),\n'
    lines.insert(insert_index, new_line)
    with open(modes_file, "w") as f:
        f.writelines(lines)
    print("    TETRA mode added to modes.py")
else:
    print("    WARNING: Could not find insertion point in modes.py")
PYEOF
fi

# --- Patch feature.py (add tetra_decoder feature) ---
if ! grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py"; then
    log "  Patching feature.py..."
    python3 << 'PYEOF'
import re
feature_file = "/usr/lib/python3/dist-packages/owrx/feature.py"
with open(feature_file, "r") as f:
    content = f.read()
features_pattern = r'("digital_voice_digiham"\s*:\s*\[[^\]]+\])'
match = re.search(features_pattern, content)
if match:
    insert_pos = match.end()
    tetra_feature = ',\n            "tetra_decoder": ["tetra_demod"]'
    content = content[:insert_pos] + tetra_feature + content[insert_pos:]
method_code = '''
    def has_tetra_demod(self):
        import os
        tetra_dir = "/opt/openwebrx-tetra"
        has_decoder = os.path.isfile(os.path.join(tetra_dir, "tetra_decoder.py"))
        has_tetra_rx = os.path.isfile(os.path.join(tetra_dir, "tetra-rx"))
        has_gnuradio = False
        try:
            import gnuradio
            has_gnuradio = True
        except ImportError:
            pass
        return has_decoder and has_tetra_rx and has_gnuradio
'''
last_def = content.rfind('\n    def has_')
if last_def > 0:
    next_def = content.find('\n    def ', last_def + 1)
    if next_def < 0:
        next_def = content.find('\nclass ', last_def + 1)
        if next_def < 0:
            next_def = len(content)
    content = content[:next_def] + '\n' + method_code + '\n' + content[next_def:]
with open(feature_file, "w") as f:
    f.write(content)
print("    TETRA feature added")
PYEOF
fi

# --- Patch dsp.py (add routing before dstar) ---
if ! grep -q '"tetra"' "$OWRX_PYTHON/owrx/dsp.py"; then
    log "  Patching dsp.py..."
    python3 << 'PYEOF'
dsp_file = "/usr/lib/python3/dist-packages/owrx/dsp.py"
with open(dsp_file, "r") as f:
    lines = f.readlines()

insert_index = -1
indent = None

for i, line in enumerate(lines):
    if 'elif demod == "dstar":' in line:
        insert_index = i
        import re
        match = re.match(r'^(\s+)', line)
        indent = match.group(1) if match else '        '
        break

if insert_index != -1:
    tetra_block = f'''
{indent}elif demod == "tetra":
{indent}    from csdr.chain.tetra import Tetra
{indent}    return Tetra()
'''
    lines.insert(insert_index, tetra_block)
    with open(dsp_file, "w") as f:
        f.writelines(lines)
    print("    TETRA routing added to dsp.py (before dstar)")
else:
    print("    WARNING: Could not find 'elif demod == \"dstar\":' in dsp.py")
PYEOF
fi

# -- Install frontend plugin files --
STEP=$((STEP_BASE + 3))
log "Step $STEP/7: Installing frontend plugin files..."

PLUGIN_DIR="$OWRX_PYTHON/htdocs/plugins/receiver/tetra_panel"
mkdir -p "$PLUGIN_DIR"
cp "$SCRIPT_DIR/tetra_panel.js" "$PLUGIN_DIR/"
if [[ -f "$SCRIPT_DIR/tetra_panel.css" ]]; then
    cp "$SCRIPT_DIR/tetra_panel.css" "$PLUGIN_DIR/"
fi
log "  Plugin files copied to $PLUGIN_DIR"

# Ensure main receiver init.js loads the plugin (flexible spacing)
MAIN_INIT="$OWRX_PYTHON/htdocs/plugins/receiver/init.js"
if [[ ! -f "$MAIN_INIT" ]]; then
    echo '// Receiver plugins loader' > "$MAIN_INIT"
    echo 'Plugins.load("utils").then(function () {' >> "$MAIN_INIT"
    echo "    Plugins.load('tetra_panel');" >> "$MAIN_INIT"
    echo '});' >> "$MAIN_INIT"
    log "  Created $MAIN_INIT and added plugin loader"
else
    if ! grep -q "Plugins.load('tetra_panel')" "$MAIN_INIT"; then
        # Match both "function() {" and "function () {" (with optional space)
        sed -i "/Plugins.load('utils').then(function\s*() {/a \    Plugins.load('tetra_panel');" "$MAIN_INIT"
        log "  Added plugin loader to existing $MAIN_INIT"
    else
        log "  Plugin already registered in $MAIN_INIT"
    fi
fi

# Clear Python cache
log "Clearing Python cache..."
find "$OWRX_PYTHON" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OWRX_PYTHON" -name "*.pyc" -delete 2>/dev/null || true

# Verify installation
echo ""
verify_installation

# Restart service
if [[ -z "$NO_RESTART" ]]; then
    log "Restarting OpenWebRX+..."
    systemctl restart openwebrx 2>/dev/null || warn "Could not restart openwebrx service"
fi

echo ""
if [[ "$MODE" == "install" ]]; then
    log "=== Installation complete! ==="
    log "Next steps:"
    log "  1. Clear browser cache (Ctrl+Shift+R)"
    log "  2. Create a profile with modulation 'TETRA'"
    log "  3. Tune to a TETRA frequency – the panel will appear"
else
    log "=== Update complete! ==="
fi
