#!/bin/bash
# TETRA module installer for OpenWebRX+ (plugin-based, all files in plugin dir)
# Author: SP8MB (modified for consolidated plugin directory)
# Usage:
#   sudo bash install.sh              # Full install (backend + plugin)
#   sudo bash install.sh --update     # Update scripts only (no rebuild)
#   sudo bash install.sh --uninstall  # Remove TETRA module
#   sudo bash install.sh --check      # Verify installation

set -e

PLUGIN_DIR="/usr/lib/python3/dist-packages/htdocs/plugins/receiver/tetra_panel"
OWRX_PYTHON="/usr/lib/python3/dist-packages"
BUILD_DIR="/tmp/openwebrx-tetra-build"
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

# Argument parsing
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

# Prechecks
[[ $EUID -ne 0 ]] && error "This script must be run as root (sudo)"
[[ -f "$OWRX_PYTHON/owrx/modes.py" ]] || error "OpenWebRX+ not found at $OWRX_PYTHON"

# Helper: verify installation
verify_installation() {
    local errors=0
    log "Verifying installation..."

    # Backend binaries/scripts in PLUGIN_DIR
    for f in tetra_decoder.py tetra_demod.py tetra-rx; do
        if [[ -f "$PLUGIN_DIR/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f"; errors=$((errors+1)); fi
    done
    for f in cdecoder sdecoder; do
        if [[ -f "$PLUGIN_DIR/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f (audio may not work)"; fi
    done

    # CSDR modules
    for f in csdr/module/tetra.py csdr/chain/tetra.py; do
        if [[ -f "$OWRX_PYTHON/$f" ]]; then log "  OK  $f"; else warn "  MISSING  $f"; errors=$((errors+1)); fi
    done

    # Python patches
    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/modes.py" 2>/dev/null; then log "  OK  TETRA mode in modes.py"; else warn "  MISSING  TETRA mode"; errors=$((errors+1)); fi
    if grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py" 2>/dev/null; then log "  OK  TETRA feature in feature.py"; else warn "  MISSING  TETRA feature"; errors=$((errors+1)); fi
    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/dsp.py" 2>/dev/null; then log "  OK  TETRA routing in dsp.py"; else warn "  MISSING  TETRA routing"; errors=$((errors+1)); fi

    # Frontend plugin
    if [[ -f "$PLUGIN_DIR/tetra_panel.js" ]]; then
        log "  OK  tetra_panel.js"
    else
        warn "  MISSING  tetra_panel.js"
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

# CHECK mode
if [[ "$MODE" == "check" ]]; then
    verify_installation
    exit $?
fi

# UNINSTALL mode
if [[ "$MODE" == "uninstall" ]]; then
    log "=== Uninstalling TETRA module ==="
    rm -f "$OWRX_PYTHON/csdr/module/tetra.py" "$OWRX_PYTHON/csdr/chain/tetra.py"
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py; do
        if [[ -f "$OWRX_PYTHON/$f.bak.pre-tetra" ]]; then
            cp "$OWRX_PYTHON/$f.bak.pre-tetra" "$OWRX_PYTHON/$f"
            log "Restored $f"
        fi
    done
    rm -rf "$PLUGIN_DIR"
    sed -i "/Plugins.load('tetra_panel')/d" "$OWRX_PYTHON/htdocs/plugins/receiver/init.js" 2>/dev/null || true
    find "$OWRX_PYTHON" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    if [[ -z "$NO_RESTART" ]]; then
        systemctl restart openwebrx 2>/dev/null || warn "Could not restart openwebrx"
    fi
    log "=== Uninstall complete ==="
    exit 0
fi

# Source file checks (for install/update)
for f in tetra_decoder.py tetra_demod.py csdr_module_tetra.py csdr_chain_tetra.py tetra_panel.js; do
    [[ -f "$SCRIPT_DIR/$f" ]] || error "Missing file: $SCRIPT_DIR/$f"
done

# ============================================================================
# INSTALL mode (full build)
# ============================================================================
if [[ "$MODE" == "install" ]]; then
    log "=== TETRA Module Installer for OpenWebRX+ ==="

    # Step 1: Dependencies
    log "Step 1/7: Installing system dependencies..."
    apt-get update -qq
    apt-get install -y -qq gnuradio libosmocore-dev build-essential pkg-config git wget unzip python3-dev 2>/dev/null

    # Step 2: Create plugin directory
    log "Step 2/7: Creating $PLUGIN_DIR..."
    mkdir -p "$PLUGIN_DIR"

    # Step 3: Build tetra-rx in temporary directory
    log "Step 3/7: Compiling tetra-rx (osmo-tetra)..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    git clone --depth 1 https://github.com/sq5bpf/osmo-tetra-sq5bpf "$BUILD_DIR/osmo-tetra-sq5bpf" 2>/dev/null || true
    cd "$BUILD_DIR/osmo-tetra-sq5bpf/src"
    make clean 2>/dev/null || true
    make tetra-rx float_to_bits 2>&1 | tail -5
    cp tetra-rx "$PLUGIN_DIR/"
    cp float_to_bits "$PLUGIN_DIR/" 2>/dev/null || true
    log "tetra-rx compiled and copied"




# Step 4: Build ETSI ACELP codec using the official script
log "Step 4/7: Building ETSI ACELP codec..."

if [[ -f "$PLUGIN_DIR/cdecoder" && -f "$PLUGIN_DIR/sdecoder" ]]; then
    log "ACELP codec already installed, skipping build."
else
    CODEC_BUILD_DIR="$BUILD_DIR/etsi_codec"
    mkdir -p "$CODEC_BUILD_DIR"
    cd "$CODEC_BUILD_DIR"

    if [[ ! -d "osmo-tetra" ]]; then
        log "Cloning the official osmo-tetra repository..."
        git clone https://gitea.osmocom.org/tetra/osmo-tetra
    fi

    cd osmo-tetra/etsi_codec-patches
    log "Running the official ETSI codec download and patch script..."
    if bash download_and_patch.sh; then
        log "Codec source downloaded and patched successfully."
    else
        warn "The official download_and_patch.sh script failed."
        cd "$SCRIPT_DIR"
        warn "Continuing without ACELP codec (audio will not work)."
        return 0 2>/dev/null || true
    fi

    # The script creates a 'codec' directory one level up
    cd ../codec
    if [[ -d "c-code" ]]; then
        cd c-code
        log "Building ACELP codec in $(pwd)..."
        if make; then
            cp cdecoder sdecoder "$PLUGIN_DIR/"
            chmod +x "$PLUGIN_DIR"/cdecoder "$PLUGIN_DIR"/sdecoder
            log "ACELP codec binaries copied to $PLUGIN_DIR"
        else
            warn "Compilation failed. Check the output above."
        fi
    else
        warn "Could not find c-code directory. Audio will not work."
    fi

    cd "$SCRIPT_DIR"
    rm -rf "$BUILD_DIR/etsi_codec"   # Clean up (optional)
fi



    # Clean up build directory (optional, keep if you want to debug)
    cd /
    rm -rf "$BUILD_DIR"

    log "Installation build steps completed."
fi
# ============================================================================
# END of INSTALL mode
# ============================================================================

# ============================================================================
# Common steps for both INSTALL and UPDATE
# ============================================================================

# Set step numbering based on mode
if [[ "$MODE" == "install" ]]; then
    STEP_BASE=5
else
    STEP_BASE=1
fi

# Deploy decoder scripts
log "Step $STEP_BASE/7: Deploying decoder scripts..."
cp "$SCRIPT_DIR/tetra_decoder.py" "$PLUGIN_DIR/"
cp "$SCRIPT_DIR/tetra_demod.py" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/tetra_decoder.py"

# Install CSDR modules with path substitution
STEP=$((STEP_BASE + 1))
log "Step $STEP/7: Installing CSDR modules..."
sed "s|TETRA_DIR_PLACEHOLDER|$PLUGIN_DIR|g" "$SCRIPT_DIR/csdr_module_tetra.py" > /tmp/csdr_module_tetra.py
cp /tmp/csdr_module_tetra.py "$OWRX_PYTHON/csdr/module/tetra.py"
sed "s|TETRA_DIR_PLACEHOLDER|$PLUGIN_DIR|g" "$SCRIPT_DIR/csdr_chain_tetra.py" > /tmp/csdr_chain_tetra.py
cp /tmp/csdr_chain_tetra.py "$OWRX_PYTHON/csdr/chain/tetra.py"
rm /tmp/csdr_module_tetra.py /tmp/csdr_chain_tetra.py
log "CSDR modules installed with path $PLUGIN_DIR"

# Patch OpenWebRX+ Python files
STEP=$((STEP_BASE + 2))
log "Step $STEP/7: Patching OpenWebRX+ Python files..."

# Backups (only on install, not on update)
if [[ "$MODE" == "install" ]]; then
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py; do
        [[ -f "$OWRX_PYTHON/$f" && ! -f "$OWRX_PYTHON/$f.bak.pre-tetra" ]] && cp "$OWRX_PYTHON/$f" "$OWRX_PYTHON/$f.bak.pre-tetra"
    done
    log "  Backups created"
fi

# Patch modes.py (add TETRA mode after nxdn)
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

if insert_index != -1:
    new_line = f'{indent}AnalogMode("tetra", "TETRA", bandpass=Bandpass(-12500, 12500), requirements=["tetra_decoder"], squelch=False),\n'
    lines.insert(insert_index, new_line)
    with open(modes_file, "w") as f:
        f.writelines(lines)
    print("    TETRA mode added")
else:
    print("    WARNING: Could not find NXDN line")
PYEOF
fi

# Patch feature.py (add tetra_decoder feature)
if ! grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py"; then
    log "  Patching feature.py..."
    python3 << 'PYEOF'
import re
feature_file = "/usr/lib/python3/dist-packages/owrx/feature.py"
with open(feature_file, "r") as f:
    content = f.read()
# Add to features dict
features_pattern = r'("digital_voice_digiham"\s*:\s*\[[^\]]+\])'
match = re.search(features_pattern, content)
if match:
    insert_pos = match.end()
    tetra_feature = ',\n            "tetra_decoder": ["tetra_demod"]'
    content = content[:insert_pos] + tetra_feature + content[insert_pos:]

# Add method if not present
if 'def has_tetra_demod(self):' not in content:
    method_code = '''
    def has_tetra_demod(self):
        import os
        tetra_dir = "''' + "{{PLUGIN_DIR}}" + '''"
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
    # Replace placeholder with actual PLUGIN_DIR
    method_code = method_code.replace("{{PLUGIN_DIR}}", "/usr/lib/python3/dist-packages/htdocs/plugins/receiver/tetra_panel")
    # Find insertion point (after last has_ method or before class)
    last_def = content.rfind('\n    def has_')
    if last_def > 0:
        next_def = content.find('\n    def ', last_def + 1)
        if next_def < 0:
            next_def = content.find('\nclass ', last_def + 1)
            if next_def < 0:
                next_def = len(content)
        content = content[:next_def] + '\n' + method_code + '\n' + content[next_def:]
    else:
        content += '\n' + method_code + '\n'
    with open(feature_file, "w") as f:
        f.write(content)
    print("    TETRA feature added")
else:
    print("    TETRA feature already present")
PYEOF
fi

# Patch dsp.py (add routing before dstar)
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
    print("    TETRA routing added")
else:
    print("    WARNING: Could not find dstar line")
PYEOF
fi

# Install frontend plugin files
STEP=$((STEP_BASE + 3))
log "Step $STEP/7: Installing frontend plugin files..."
cp "$SCRIPT_DIR/tetra_panel.js" "$PLUGIN_DIR/"
if [[ -f "$SCRIPT_DIR/tetra_panel.css" ]]; then
    cp "$SCRIPT_DIR/tetra_panel.css" "$PLUGIN_DIR/"
fi
log "  Plugin JS copied to $PLUGIN_DIR"

# Register plugin in init.js (modern OpenWebRX+ pattern)
MAIN_INIT="$OWRX_PYTHON/htdocs/plugins/receiver/init.js"
if [[ ! -f "$MAIN_INIT" ]]; then
    cat > "$MAIN_INIT" << 'EOF'
// Receiver plugins initialization.
const rp_url = 'https://0xaf.github.io/openwebrxplus-plugins/receiver';

Plugins.load(rp_url + '/utils/utils.js').then(async function () {
    Plugins.load('tetra_panel');
});
EOF
    log "  Created $MAIN_INIT and added plugin loader"
else
    if ! grep -q "Plugins.load('tetra_panel')" "$MAIN_INIT"; then
        python3 << PYEOF
import re
init_js = "$MAIN_INIT"
with open(init_js, "r") as f:
    content = f.read()
# Look for the utils load pattern and insert after the opening brace
pattern = r"(Plugins\.load\(rp_url\s*\+\s*['\"]/utils/utils\.js['\"]\)\.then\(async\s+function\s*\(\s*\)\s*\{)"
if re.search(pattern, content):
    new_content = re.sub(pattern, r"\1\n    Plugins.load('tetra_panel');", content)
    if new_content != content:
        with open(init_js, "w") as f:
            f.write(new_content)
        print("    Added plugin loader to init.js")
    else:
        print("    Could not add loader (already present?)")
else:
    # Fallback: append at the end (less ideal)
    with open(init_js, "a") as f:
        f.write("\nPlugins.load('tetra_panel');\n")
    print("    Appended plugin loader to init.js")
PYEOF
    else
        log "  Plugin already registered in init.js"
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
