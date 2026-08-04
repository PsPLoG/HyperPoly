#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash update/namv2/build-update.sh /path/to/namv2.deb [config.env]

Builds a USB-ready directory containing:
  1. the prebuilt NAMv2 LV2 package
  2. a HyperPoly UI integration package
  3. SHA256SUMS

The script refuses to build until NAMv2's distinct LV2 URI, model patch
property, ports, default model and separate model-storage paths are provided.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
NAMV2_DEB=$(realpath "$1")
CONFIG_FILE=${2:-"$SCRIPT_DIR/config.env"}

[[ -f "$NAMV2_DEB" ]] || { echo "NAMv2 deb not found: $NAMV2_DEB" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || {
    echo "config not found: $CONFIG_FILE" >&2
    echo "copy $SCRIPT_DIR/config.example.env to config.env and fill it after inspecting the deb" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

required_vars=(
    NAMV2_PLUGIN_URI NAMV2_MODEL_PROPERTY_URI NAMV2_PATCH_PORT_SYMBOL
    NAMV2_AUDIO_INPUT_SYMBOL NAMV2_AUDIO_OUTPUT_SYMBOL
    NAMV2_INPUT_LEVEL_SYMBOL NAMV2_OUTPUT_LEVEL_SYMBOL
    NAMV2_INPUT_LEVEL_DEFAULT NAMV2_INPUT_LEVEL_MIN NAMV2_INPUT_LEVEL_MAX
    NAMV2_OUTPUT_LEVEL_DEFAULT NAMV2_OUTPUT_LEVEL_MIN NAMV2_OUTPUT_LEVEL_MAX
    NAMV2_DEFAULT_MODEL NAMV2_MODEL_ROOT NAMV2_MODEL_STORAGE_ROOT
    NAMV2_USB_MODEL_FOLDER
)
for name in "${required_vars[@]}"; do
    value=${!name:-}
    if [[ -z "$value" || "$value" == "REQUIRED" ]]; then
        echo "missing required config: $name" >&2
        exit 1
    fi
done

OLD_NAM_URI="http://github.com/mikeoliphant/neural-amp-modeler-lv2"
if [[ "$NAMV2_PLUGIN_URI" == "$OLD_NAM_URI" ]]; then
    echo "NAMv2 must have a distinct LV2 plugin URI; got the existing NAM URI" >&2
    exit 1
fi
if [[ "$NAMV2_MODEL_ROOT" == "/audio/amp_nam" || "$NAMV2_MODEL_STORAGE_ROOT" == "/mnt/audio/amp_nam" ]]; then
    echo "NAMv2 model paths must not reuse the classic NAM model directory" >&2
    exit 1
fi
if [[ ! "$NAMV2_USB_MODEL_FOLDER" =~ ^[A-Za-z0-9._-]+$ || "$NAMV2_USB_MODEL_FOLDER" == "amps" ]]; then
    echo "NAMV2_USB_MODEL_FOLDER must be a separate safe USB-root folder name" >&2
    exit 1
fi
if [[ ! "$NAMV2_MODEL_ROOT" =~ ^/audio/[A-Za-z0-9._/-]+$ ]]; then
    echo "NAMV2_MODEL_ROOT must be a safe path below /audio" >&2
    exit 1
fi
if [[ ! "$NAMV2_MODEL_STORAGE_ROOT" =~ ^/mnt/audio/[A-Za-z0-9._/-]+$ ]]; then
    echo "NAMV2_MODEL_STORAGE_ROOT must be a safe path below /mnt/audio" >&2
    exit 1
fi
case "$NAMV2_DEFAULT_MODEL" in
    "$NAMV2_MODEL_ROOT"/*) ;;
    *) echo "NAMV2_DEFAULT_MODEL must be below NAMV2_MODEL_ROOT" >&2; exit 1 ;;
esac

for command in dpkg-deb python3 patch sha256sum realpath grep; do
    command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done

NAMV2_PACKAGE_NAME=$(dpkg-deb -f "$NAMV2_DEB" Package)
NAMV2_PACKAGE_VERSION=$(dpkg-deb -f "$NAMV2_DEB" Version)
NAMV2_ARCH=$(dpkg-deb -f "$NAMV2_DEB" Architecture)
case "$NAMV2_ARCH" in
    arm64|aarch64) ;;
    *) echo "warning: NAMv2 package architecture is $NAMV2_ARCH; verify it matches the target" >&2 ;;
esac

WORK="$SCRIPT_DIR/work"
DIST="$SCRIPT_DIR/dist"
USB_OUT="$DIST/usb"
rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$USB_OUT"

python3 "$SCRIPT_DIR/inspect-deb.py" "$NAMV2_DEB" --extract-to "$WORK/namv2-root" > "$WORK/inspection.json"
python3 - "$WORK/inspection.json" "$NAMV2_PLUGIN_URI" "$NAMV2_MODEL_PROPERTY_URI" <<'PY'
import json
import sys

path, plugin_uri, property_uri = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if not data["checks"]["has_lv2_bundle"]:
    raise SystemExit("NAMv2 deb does not contain an *.lv2 bundle")
if plugin_uri not in data["plugin_uri_candidates"]:
    print("warning: configured plugin URI was not automatically found in TTL", file=sys.stderr)
if property_uri not in data["model_property_uri_candidates"]:
    print("warning: configured model property URI was not automatically found in TTL", file=sys.stderr)
PY

# Work on a private UI copy so source files remain unchanged and the generated
# module_info.js exactly matches the patched module_info.py.
cp -a "$REPO_ROOT/digit_ui" "$WORK/ui"

export NAMV2_PLUGIN_URI NAMV2_MODEL_PROPERTY_URI NAMV2_PATCH_PORT_SYMBOL
export NAMV2_AUDIO_INPUT_SYMBOL NAMV2_AUDIO_OUTPUT_SYMBOL
export NAMV2_INPUT_LEVEL_SYMBOL NAMV2_OUTPUT_LEVEL_SYMBOL
export NAMV2_INPUT_LEVEL_DEFAULT NAMV2_INPUT_LEVEL_MIN NAMV2_INPUT_LEVEL_MAX
export NAMV2_OUTPUT_LEVEL_DEFAULT NAMV2_OUTPUT_LEVEL_MIN NAMV2_OUTPUT_LEVEL_MAX
export NAMV2_DEFAULT_MODEL NAMV2_MODEL_ROOT NAMV2_MODEL_STORAGE_ROOT
export NAMV2_USB_MODEL_FOLDER

render_patch() {
    local source=$1
    local output=$2
    python3 - "$source" "$output" <<'PY'
import os
import sys

source, output = sys.argv[1:]
text = open(source, encoding="utf-8").read()
keys = [
    "NAMV2_PLUGIN_URI", "NAMV2_MODEL_PROPERTY_URI", "NAMV2_PATCH_PORT_SYMBOL",
    "NAMV2_AUDIO_INPUT_SYMBOL", "NAMV2_AUDIO_OUTPUT_SYMBOL",
    "NAMV2_INPUT_LEVEL_SYMBOL", "NAMV2_OUTPUT_LEVEL_SYMBOL",
    "NAMV2_INPUT_LEVEL_DEFAULT", "NAMV2_INPUT_LEVEL_MIN", "NAMV2_INPUT_LEVEL_MAX",
    "NAMV2_OUTPUT_LEVEL_DEFAULT", "NAMV2_OUTPUT_LEVEL_MIN", "NAMV2_OUTPUT_LEVEL_MAX",
    "NAMV2_DEFAULT_MODEL", "NAMV2_MODEL_ROOT", "NAMV2_MODEL_STORAGE_ROOT",
    "NAMV2_USB_MODEL_FOLDER",
]
for key in keys:
    value = os.environ[key]
    if "\n" in value or "\r" in value:
        raise SystemExit(f"invalid newline in {key}")
    text = text.replace(f"@{key}@", value)
if "@NAMV2_" in text:
    raise SystemExit(f"unexpanded NAMv2 placeholder remains in {source}")
open(output, "w", encoding="utf-8").write(text)
PY
}

render_patch "$SCRIPT_DIR/namv2-ui.patch.in" "$WORK/namv2-ui.patch"
render_patch "$SCRIPT_DIR/namv2-model-storage.patch.in" "$WORK/namv2-model-storage.patch"

patch --dry-run --batch --forward -d "$WORK/ui" -p1 < "$WORK/namv2-ui.patch"
patch --batch --forward -d "$WORK/ui" -p1 < "$WORK/namv2-ui.patch"
patch --dry-run --batch --forward -d "$WORK/ui" -p1 < "$WORK/namv2-model-storage.patch"
patch --batch --forward -d "$WORK/ui" -p1 < "$WORK/namv2-model-storage.patch"

(
    cd "$WORK/ui"
    python3 -m py_compile \
        module_info.py show_widget.py ingen_wrapper.py amp_browser_model.py \
        effect_proto_to_js.py
    python3 effect_proto_to_js.py
)
grep -q 'amp_namv2' "$WORK/ui/qml/module_info.js"
grep -q 'set_json_namv2' "$WORK/ui/ingen_wrapper.py"
grep -q 'ui_copy_amps_v2' "$WORK/ui/show_widget.py"
grep -q 'set_model_root' "$WORK/ui/amp_browser_model.py"
grep -q 'file:///audio/amp_nam' "$WORK/ui/qml/PatchBayEffect.qml"
grep -q "file://$NAMV2_MODEL_ROOT" "$WORK/ui/qml/PatchBayEffect.qml"

PKGROOT="$WORK/ui-package"
mkdir -p "$PKGROOT/DEBIAN" "$PKGROOT/home/debian/UI/qml"
install -m 0644 "$WORK/ui/module_info.py" "$PKGROOT/home/debian/UI/module_info.py"
install -m 0644 "$WORK/ui/qml/module_info.js" "$PKGROOT/home/debian/UI/qml/module_info.js"
install -m 0644 "$WORK/ui/show_widget.py" "$PKGROOT/home/debian/UI/show_widget.py"
install -m 0644 "$WORK/ui/ingen_wrapper.py" "$PKGROOT/home/debian/UI/ingen_wrapper.py"
install -m 0644 "$WORK/ui/amp_browser_model.py" "$PKGROOT/home/debian/UI/amp_browser_model.py"
install -m 0644 "$WORK/ui/qml/PatchBayEffect.qml" "$PKGROOT/home/debian/UI/qml/PatchBayEffect.qml"
install -m 0644 "$WORK/ui/qml/AmpBrowser.qml" "$PKGROOT/home/debian/UI/qml/AmpBrowser.qml"
install -m 0644 "$WORK/ui/qml/Settings.qml" "$PKGROOT/home/debian/UI/qml/Settings.qml"

UI_VERSION="${NAMV2_PACKAGE_VERSION}+hyperpoly2"
export UI_VERSION NAMV2_PACKAGE_NAME NAMV2_PACKAGE_VERSION
python3 - "$SCRIPT_DIR/debian/control.in" "$PKGROOT/DEBIAN/control" <<'PY'
import os
import sys

source, output = sys.argv[1:]
text = open(source, encoding="utf-8").read()
for key in ("UI_VERSION", "NAMV2_PACKAGE_NAME", "NAMV2_PACKAGE_VERSION"):
    text = text.replace(f"@{key}@", os.environ[key])
open(output, "w", encoding="utf-8").write(text)
PY
python3 - "$SCRIPT_DIR/debian/postinst" "$PKGROOT/DEBIAN/postinst" <<'PY'
import os
import sys

source, output = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("@NAMV2_MODEL_STORAGE_ROOT@", os.environ["NAMV2_MODEL_STORAGE_ROOT"])
if "@NAMV2_" in text:
    raise SystemExit("unexpanded NAMv2 placeholder remains in postinst")
open(output, "w", encoding="utf-8").write(text)
PY
chmod 0755 "$PKGROOT/DEBIAN/postinst"

SAFE_VERSION=${UI_VERSION//:/%3a}
UI_DEB="$USB_OUT/zz-hyperpoly-namv2-ui_${SAFE_VERSION}_all.deb"
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
    dpkg-deb --root-owner-group --build "$PKGROOT" "$UI_DEB"
elif command -v fakeroot >/dev/null; then
    fakeroot dpkg-deb --build "$PKGROOT" "$UI_DEB"
else
    echo "dpkg-deb lacks --root-owner-group and fakeroot is unavailable" >&2
    exit 1
fi

cp -a "$NAMV2_DEB" "$USB_OUT/"
(
    cd "$USB_OUT"
    sha256sum ./*.deb > SHA256SUMS
)

dpkg-deb --info "$UI_DEB"
dpkg-deb --contents "$UI_DEB"

echo
echo "USB-ready update created at: $USB_OUT"
echo "Copy both .deb files and SHA256SUMS directly to the USB root."
echo "Put NAMv2 model files under USB_ROOT/$NAMV2_USB_MODEL_FOLDER before using COPY NAMV2 AMPS."
