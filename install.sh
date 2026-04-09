#!/bin/bash
# TETRA module installer for OpenWebRX+
# Author: SP8MB
# Installs TETRA voice decoding support on Raspberry Pi / Debian
#
# Usage:
#   sudo bash install.sh              # Full install (build + patch)
#   sudo bash install.sh --update     # Update scripts/panel only (no rebuild)
#   sudo bash install.sh --uninstall  # Remove TETRA module
#   sudo bash install.sh --check      # Verify installation
#
# Prerequisites:
#   - OpenWebRX+ v1.2.x installed
#   - Internet access for apt packages (full install only)

set -e

INSTALL_DIR="/usr/lib/python3/dist-packages/htdocs/plugins/receiver/tetra"
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
            echo ""
            echo "Modes:"
            echo "  (default)    Full install: dependencies, compile, patch"
            echo "  --update     Update decoder scripts and panel only"
            echo "  --uninstall  Remove TETRA module completely"
            echo "  --check      Verify installation status"
            echo ""
            echo "Options:"
            echo "  --no-restart  Don't restart openwebrx service"
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
# Helper: verify installation
# ??????????????????????????????????????????????????????
verify_installation() {
    local errors=0

    log "Verifying installation..."

    # Core binaries/scripts
    for f in tetra_decoder.py tetra_demod.py tetra-rx; do
        if [[ -f "$INSTALL_DIR/$f" ]]; then
            log "  OK  $f"
        else
            warn "  MISSING  $f"
            errors=$((errors + 1))
        fi
    done

    # Codec (optional but needed for audio)
    for f in cdecoder sdecoder; do
        if [[ -f "$INSTALL_DIR/$f" ]]; then
            log "  OK  $f"
        else
            warn "  MISSING  $f (audio decoding won't work)"
        fi
    done

    # CSDR modules
    for f in csdr/module/tetra.py csdr/chain/tetra.py; do
        if [[ -f "$OWRX_PYTHON/$f" ]]; then
            log "  OK  $f"
        else
            warn "  MISSING  $f"
            errors=$((errors + 1))
        fi
    done

    # Patches in OpenWebRX+
    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/modes.py" 2>/dev/null; then
        log "  OK  TETRA mode in modes.py"
    else
        warn "  MISSING  TETRA mode in modes.py"
        errors=$((errors + 1))
    fi

    if grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py" 2>/dev/null; then
        log "  OK  TETRA feature in feature.py"
    else
        warn "  MISSING  TETRA feature in feature.py"
        errors=$((errors + 1))
    fi

    if grep -q '"tetra"' "$OWRX_PYTHON/owrx/dsp.py" 2>/dev/null; then
        log "  OK  TETRA routing in dsp.py"
    else
        warn "  MISSING  TETRA routing in dsp.py"
        errors=$((errors + 1))
    fi

    # Frontend
    if grep -q 'openwebrx-panel-metadata-tetra' "$OWRX_PYTHON/htdocs/index.html" 2>/dev/null; then
        log "  OK  TETRA panel in index.html"
    else
        warn "  MISSING  TETRA panel in index.html"
        errors=$((errors + 1))
    fi

    if grep -q 'TetraMetaPanel' "$OWRX_PYTHON/htdocs/lib/MetaPanel.js" 2>/dev/null; then
        log "  OK  TetraMetaPanel in MetaPanel.js"
    else
        warn "  MISSING  TetraMetaPanel in MetaPanel.js"
        errors=$((errors + 1))
    fi

    if grep -q 'tetra-ts.busy' "$OWRX_PYTHON/htdocs/css/openwebrx.css" 2>/dev/null; then
        log "  OK  TETRA CSS styles"
    else
        warn "  MISSING  TETRA CSS styles"
        errors=$((errors + 1))
    fi

    # GNURadio
    if python3 -c 'from gnuradio import gr' 2>/dev/null; then
        log "  OK  GNURadio $(python3 -c 'from gnuradio import gr; print(gr.version())' 2>/dev/null)"
    else
        warn "  MISSING  GNURadio"
        errors=$((errors + 1))
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        log "Installation OK - all components present"
    else
        warn "Installation has $errors issue(s)"
    fi
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
# UNINSTALL mode (fully restored, including frontend)
# ??????????????????????????????????????????????????????
if [[ "$MODE" == "uninstall" ]]; then
    log "=== Uninstalling TETRA module ==="

    # Remove CSDR modules
    rm -f "$OWRX_PYTHON/csdr/module/tetra.py"
    rm -f "$OWRX_PYTHON/csdr/chain/tetra.py"
    log "Removed CSDR modules"

    # Restore ALL backed-up OpenWebRX+ files (including frontend)
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py \
             htdocs/index.html htdocs/lib/MetaPanel.js htdocs/css/openwebrx.css; do
        backup="$OWRX_PYTHON/$f.bak.pre-tetra"
        if [[ -f "$backup" ]]; then
            cp "$backup" "$OWRX_PYTHON/$f"
            log "Restored $f from backup"
        else
            warn "No backup for $f - manual cleanup may be needed"
        fi
    done

    # Remove the entire TETRA plugin directory
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log "Removed $INSTALL_DIR"
    fi

    # Clear Python cache
    find "$OWRX_PYTHON" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$OWRX_PYTHON" -name "*.pyc" -delete 2>/dev/null || true

    if [[ -z "$NO_RESTART" ]]; then
        log "Restarting OpenWebRX+..."
        systemctl restart openwebrx 2>/dev/null || warn "Could not restart openwebrx service"
    fi

    log "=== TETRA module uninstalled ==="
    exit 0
fi
# ??????????????????????????????????????????????????????
# Source file checks (only for install/update)
# ??????????????????????????????????????????????????????
for f in tetra_decoder.py tetra_demod.py csdr_module_tetra.py csdr_chain_tetra.py tetra_panel.js tetra_panel.html; do
    [[ -f "$SCRIPT_DIR/$f" ]] || error "Source file missing: $SCRIPT_DIR/$f"
done

# ??????????????????????????????????????????????????????
# INSTALL / UPDATE mode
# ??????????????????????????????????????????????????????

if [[ "$MODE" == "install" ]]; then
    log "=== TETRA Module Installer for OpenWebRX+ ==="

    # -- Step 1: System dependencies --
    log "Step 1/8: Installing system dependencies..."
    apt-get update -qq
    apt-get install -y -qq \
        gnuradio \
        libosmocore-dev \
        build-essential \
        pkg-config \
        git \
        wget \
        unzip \
        python3-dev \
        2>/dev/null
    log "GNURadio $(python3 -c 'from gnuradio import gr; print(gr.version())' 2>/dev/null || echo '?') installed"

    # -- Step 2: Create install directory --
    log "Step 2/8: Setting up $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"

    # -- Step 3: Compile tetra-rx (osmo-tetra) --
    log "Step 3/8: Compiling tetra-rx (osmo-tetra)..."
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
        log "tetra-rx compiled successfully"
    else
        error "Failed to clone osmo-tetra"
    fi

    # -- Step 4: Build ETSI ACELP codec (optional) --
    log "Step 4/8: Building ETSI ACELP codec..."
    CODEC_DIR="$OSMO_TETRA_SRC/etsi_codec-patches"
    if [[ -d "$CODEC_DIR" && -f "$CODEC_DIR/download_and_patch.sh" ]]; then
        cd "$CODEC_DIR"
        if [[ ! -f "$INSTALL_DIR/cdecoder" ]]; then
            log "Running ETSI codec download and build..."
            bash download_and_patch.sh 2>&1 | tail -10
            if [[ -d codec ]]; then
                cd codec
                make 2>&1 | tail -5
                cp cdecoder sdecoder "$INSTALL_DIR/" 2>/dev/null || true
                cd "$CODEC_DIR"
            fi
            if [[ -f "$INSTALL_DIR/cdecoder" && -f "$INSTALL_DIR/sdecoder" ]]; then
                log "ACELP codec built successfully"
            else
                warn "ACELP codec build failed - audio decoding will not work"
                warn "See: $CODEC_DIR/README"
            fi
        else
            log "ACELP codec already installed"
        fi
    else
        warn "ETSI codec patches not found"
        warn "Copy cdecoder and sdecoder to $INSTALL_DIR/ manually"
    fi
else
    log "=== TETRA Module Update ==="
fi

# ??????????????????????????????????????????????????????
# Steps common to install and update
# ??????????????????????????????????????????????????????

STEP_BASE=5
[[ "$MODE" == "update" ]] && STEP_BASE=1
STEP_TOTAL=8
[[ "$MODE" == "update" ]] && STEP_TOTAL=4

# -- Deploy decoder scripts --
log "Step $STEP_BASE/$STEP_TOTAL: Deploying decoder scripts..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/tetra_decoder.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/tetra_demod.py" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/tetra_decoder.py"
log "Deployed tetra_decoder.py and tetra_demod.py"

# -- Install CSDR module/chain --
STEP=$((STEP_BASE + 1))
log "Step $STEP/$STEP_TOTAL: Installing CSDR module..."
cp "$SCRIPT_DIR/csdr_module_tetra.py" "$OWRX_PYTHON/csdr/module/tetra.py"
cp "$SCRIPT_DIR/csdr_chain_tetra.py" "$OWRX_PYTHON/csdr/chain/tetra.py"
log "Installed csdr/module/tetra.py and csdr/chain/tetra.py"

# -- Patch OpenWebRX+ (modes.py, feature.py, dsp.py) --
STEP=$((STEP_BASE + 2))
log "Step $STEP/$STEP_TOTAL: Patching OpenWebRX+..."

# Backup originals (only on first install)
if [[ "$MODE" == "install" ]]; then
    for f in owrx/modes.py owrx/feature.py owrx/dsp.py \
             htdocs/index.html htdocs/lib/MetaPanel.js htdocs/css/openwebrx.css; do
        if [[ -f "$OWRX_PYTHON/$f" && ! -f "$OWRX_PYTHON/$f.bak.pre-tetra" ]]; then
            cp "$OWRX_PYTHON/$f" "$OWRX_PYTHON/$f.bak.pre-tetra"
        fi
    done
    log "  Backups created (.bak.pre-tetra)"
fi

# ----------------------------------------------------------------------
# Patch modes.py – insert TETRA mode after NXDN with correct indentation
# ----------------------------------------------------------------------
if ! grep -q '"tetra"' "$OWRX_PYTHON/owrx/modes.py"; then
    log "  Patching modes.py..."
    python3 << 'PYEOF'
import re

modes_file = "/usr/lib/python3/dist-packages/owrx/modes.py"
with open(modes_file, "r") as f:
    lines = f.readlines()

# Find the line containing AnalogMode("nxdn"
insert_idx = -1
indent = ""
for i, line in enumerate(lines):
    if 'AnalogMode("nxdn"' in line:
        insert_idx = i + 1  # insert after this line
        # Capture the indentation (spaces/tabs) from the nxdn line
        indent_match = re.match(r'^(\s*)', line)
        indent = indent_match.group(1) if indent_match else "        "
        break

if insert_idx == -1:
    print("    WARNING: Could not find NXDN mode line in modes.py")
else:
    tetra_line = f'{indent}AnalogMode("tetra", "TETRA", bandpass=Bandpass(-12500, 12500), requirements=["tetra_decoder"], squelch=False),\n'
    lines.insert(insert_idx, tetra_line)
    with open(modes_file, "w") as f:
        f.writelines(lines)
    print("    TETRA mode added after NXDN")
PYEOF
else
    log "  modes.py already patched"
fi

# ----------------------------------------------------------------------
# Patch feature.py (unchanged, already correct)
# ----------------------------------------------------------------------
if ! grep -q 'tetra_decoder' "$OWRX_PYTHON/owrx/feature.py"; then
    log "  Patching feature.py..."
    python3 << PYEOF
import re

feature_file = "$OWRX_PYTHON/owrx/feature.py"
with open(feature_file, "r") as f:
    content = f.read()

# Add tetra_decoder feature to the features dict
features_pattern = r'("digital_voice_digiham"\s*:\s*\[[^\]]+\])'
match = re.search(features_pattern, content)
if match:
    insert_pos = match.end()
    tetra_feature = ',\n            "tetra_decoder": ["tetra_demod"]'
    content = content[:insert_pos] + tetra_feature + content[insert_pos:]

    # Add has_tetra_demod method with the install directory
    method_code = '''
    def has_tetra_demod(self):
        """Check if TETRA demodulator is available."""
        import os
        tetra_dir = "'''"${INSTALL_DIR}"'''"
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
    # Insert method before the last class or at end of FeatureDetector
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
    print("    TETRA feature detection added")
else:
    print("    WARNING: Could not find features dict in feature.py")
PYEOF
else
    log "  feature.py already patched"
fi

# ----------------------------------------------------------------------
# Patch dsp.py – insert TETRA routing AFTER the entire NXDN block
# ----------------------------------------------------------------------
if ! grep -q '"tetra"' "$OWRX_PYTHON/owrx/dsp.py"; then
    log "  Patching dsp.py..."
    python3 << 'PYEOF'
import re

dsp_file = "/usr/lib/python3/dist-packages/owrx/dsp.py"
with open(dsp_file, "r") as f:
    lines = f.readlines()

# Find the line that starts the NXDN block: 'elif demod == "nxdn":'
nxdn_idx = -1
for i, line in enumerate(lines):
    if re.match(r'\s+elif\s+demod\s*==\s*"nxdn":', line):
        nxdn_idx = i
        break

if nxdn_idx == -1:
    print("    WARNING: Could not find NXDN routing in dsp.py")
else:
    # Find the end of the NXDN block: a line with the same or less indentation
    # that is not a continuation (e.g., next elif or return from outer function)
    base_indent = len(lines[nxdn_idx]) - len(lines[nxdn_idx].lstrip())
    # Look for the line after the return statement of the nxdn block
    # The block consists of: the elif line, then two indented lines (from, return)
    # After that, the next line should have indentation <= base_indent
    insert_idx = nxdn_idx + 1
    # Skip the from and return lines (they are more indented)
    while insert_idx < len(lines) and len(lines[insert_idx]) - len(lines[insert_idx].lstrip()) > base_indent:
        insert_idx += 1
    # Now insert_idx points to the line after the NXDN block (likely next elif or a return)
    
    # Build the tetra block with same indentation as the nxdn line
    indent = lines[nxdn_idx][:base_indent]  # preserve exact spaces/tabs
    tetra_block = f'''{indent}elif demod == "tetra":
{indent}    from csdr.chain.tetra import Tetra
{indent}    return Tetra()
'''
    lines.insert(insert_idx, tetra_block)
    with open(dsp_file, "w") as f:
        f.writelines(lines)
    print("    TETRA routing added after NXDN block")
PYEOF
else
    log "  dsp.py already patched"
fi

# -- Install frontend (HTML, JS, CSS) --
STEP=$((STEP_BASE + 3))
log "Step $STEP/$STEP_TOTAL: Installing frontend panel..."

# --- Install TETRA panel HTML ---
python3 << PYEOF
html_file = "$OWRX_PYTHON/htdocs/index.html"
panel_file = "$SCRIPT_DIR/tetra_panel.html"

with open(html_file, "r") as f:
    html = f.read()
with open(panel_file, "r") as f:
    new_panel = f.read().strip()

marker = 'id="openwebrx-panel-metadata-tetra"'
if marker in html:
    # Replace existing panel
    start = html.find(marker)
    div_start = html.rfind("<div", 0, start)
    pos = start
    depth = 1
    while depth > 0 and pos < len(html):
        next_open = html.find("<div", pos + 1)
        next_close = html.find("</div>", pos + 1)
        if next_close < 0:
            break
        if 0 <= next_open < next_close:
            depth += 1
            pos = next_open
        else:
            depth -= 1
            pos = next_close
    div_end = pos + len("</div>")
    html = html[:div_start] + new_panel + html[div_end:]
    print("    Updated TETRA panel in index.html")
else:
    # Insert before the DMR meta panel (or before closing body)
    insert_markers = [
        'id="openwebrx-panel-metadata-dmr"',
        'id="openwebrx-panel-metadata-ysf"',
        'id="openwebrx-panel-metadata-dstar"',
    ]
    inserted = False
    for m in insert_markers:
        pos = html.find(m)
        if pos >= 0:
            div_start = html.rfind("<div", 0, pos)
            # Find proper indentation
            line_start = html.rfind("\n", 0, div_start) + 1
            indent = html[line_start:div_start]
            html = html[:div_start] + new_panel + "\n" + indent + html[div_start:]
            inserted = True
            break
    if not inserted:
        # Last resort: insert before </body>
        body_end = html.find("</body>")
        if body_end >= 0:
            html = html[:body_end] + new_panel + "\n" + html[body_end:]
            inserted = True
    if inserted:
        print("    Added TETRA panel to index.html")
    else:
        print("    WARNING: Could not insert TETRA panel into index.html")

with open(html_file, "w") as f:
    f.write(html)
PYEOF

# --- Install TetraMetaPanel JS ---
python3 << PYEOF
js_file = "$OWRX_PYTHON/htdocs/lib/MetaPanel.js"
panel_js_file = "$SCRIPT_DIR/tetra_panel.js"

with open(js_file, "r") as f:
    content = f.read()
with open(panel_js_file, "r") as f:
    new_js = f.read().strip()

# Check if TetraMetaPanel already exists
if "function TetraMetaPanel(el)" in content:
    # Replace existing
    start = content.find("function TetraMetaPanel(el)")
    types_pos = content.find("MetaPanel.types", start)
    if types_pos >= 0:
        content = content[:start] + new_js + "\n\n" + content[types_pos:]
        print("    Updated TetraMetaPanel in MetaPanel.js")
else:
    # Insert before MetaPanel.types
    types_pos = content.find("MetaPanel.types")
    if types_pos >= 0:
        content = content[:types_pos] + new_js + "\n\n" + content[types_pos:]
        print("    Added TetraMetaPanel to MetaPanel.js")
    else:
        # Append at end
        content += "\n\n" + new_js + "\n"
        print("    Appended TetraMetaPanel to MetaPanel.js")

# Register in MetaPanel.types
import re
if '"tetra"' not in content or 'TetraMetaPanel' not in content.split("MetaPanel.types")[-1]:
    # Add tetra to MetaPanel.types = { ... }
    types_match = re.search(r'(MetaPanel\.types\s*=\s*\{)', content)
    if types_match:
        insert_pos = types_match.end()
        # Check if there's already content after the brace
        after = content[insert_pos:insert_pos+1]
        if after == '\n' or after == ' ':
            content = content[:insert_pos] + '\n    "tetra": TetraMetaPanel,' + content[insert_pos:]
        else:
            content = content[:insert_pos] + '\n    "tetra": TetraMetaPanel,' + content[insert_pos:]
        print("    Registered tetra in MetaPanel.types")

with open(js_file, "w") as f:
    f.write(content)
PYEOF

# --- Install TETRA CSS ---
python3 << 'PYEOF'
css_file = "/usr/lib/python3/dist-packages/htdocs/css/openwebrx.css"
with open(css_file, "r") as f:
    css = f.read()

tetra_css = """
/* TETRA panel styles */
.openwebrx-tetra-panel {
    padding: 5px 10px;
    font-size: 0.85em;
}
.openwebrx-tetra-panel .tetra-header {
    font-weight: bold;
    font-size: 1.1em;
    margin-bottom: 3px;
    color: #74c0fc;
}
.openwebrx-tetra-panel .tetra-label {
    color: #868e96;
    margin-right: 3px;
}
.openwebrx-tetra-panel .tetra-row {
    margin: 1px 0;
}
.openwebrx-tetra-panel .tetra-timeslots {
    margin-top: 3px;
}
.openwebrx-tetra-panel .tetra-ts {
    display: inline-block;
    width: 20px;
    text-align: center;
    margin: 0 2px;
    padding: 1px 4px;
    border: 1px solid #495057;
    border-radius: 3px;
    font-size: 0.9em;
}
.openwebrx-tetra-panel .tetra-ts.busy {
    background: #e67700;
    color: #fff;
}
.openwebrx-tetra-panel .tetra-ts.idle {
    background: #2b8a3e;
    color: #fff;
}
"""

if "tetra-ts.busy" not in css:
    css += tetra_css
    with open(css_file, "w") as f:
        f.write(css)
    print("    Added TETRA CSS styles")
else:
    # Replace existing TETRA CSS
    import re
    css = re.sub(r'/\* TETRA panel styles \*/.*?(?=\n/\*|\Z)', tetra_css.strip() + '\n', css, flags=re.DOTALL)
    with open(css_file, "w") as f:
        f.write(css)
    print("    Updated TETRA CSS styles")
PYEOF

# -- Clear cache and restart --
log "Clearing Python cache..."
find "$OWRX_PYTHON" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OWRX_PYTHON" -name "*.pyc" -delete 2>/dev/null || true

# -- Verify --
echo ""
verify_installation

# -- Restart service --
if [[ -z "$NO_RESTART" ]]; then
    echo ""
    log "Restarting OpenWebRX+..."
    systemctl restart openwebrx 2>/dev/null || warn "Could not restart openwebrx service"
fi

echo ""
if [[ "$MODE" == "install" ]]; then
    log "=== Installation complete! ==="
    log ""
    log "Next steps:"
    log "  1. Open the web interface"
    log "  2. Go to Settings -> SDR -> Profiles"
    log "  3. Create a profile for your TETRA frequency"
    log "  4. Set modulation to 'TETRA'"
else
    log "=== Update complete! ==="
fi
