#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if [ -f /tmp/prism-test-ca.crt ]; then
    mkdir -p /etc/ssl/certs
    cp /tmp/prism-test-ca.crt /etc/ssl/certs/ca-certificates.crt
fi
if [ -n "${PRISM_TEST_APT_MIRROR:-}" ]; then
    for PRISM_SOURCE in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
        if [ -f "$PRISM_SOURCE" ]; then
            sed -i "s|http://archive.ubuntu.com/ubuntu/|$PRISM_TEST_APT_MIRROR/|g; s|http://security.ubuntu.com/ubuntu/|$PRISM_TEST_APT_MIRROR/|g" "$PRISM_SOURCE"
        fi
    done
fi
apt-get update -qq
apt-get install -y -qq xvfb xauth xdotool x11-utils openbox xcompmgr mutter fonts-dejavu-core fonts-noto-cjk desktop-file-utils dbus
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path("/repo/build-linux")
manifest = json.loads((root / "manifest-amd64.json").read_text())
for filename, expected in manifest["sha256"].items():
    actual = hashlib.sha256((root / filename).read_bytes()).hexdigest()
    assert actual == expected, filename + ": checksum mismatch"
    print(actual + "  " + filename)
PY
# Ensure a repeated run validates the current payload even when its version is unchanged.
apt-get install -y -qq --reinstall /repo/build-linux/prismtranslate_0.2.0_amd64.deb
desktop-file-validate /usr/share/applications/prismtranslate.desktop
python3 --version
getconf GNU_LIBC_VERSION
cat /etc/os-release
# First launch uses only bundled wheels; even pip is bootstrapped offline.
export XDG_CONFIG_HOME=/tmp/prism-config
export XDG_DATA_HOME=/tmp/prism-data
mkdir -p /tmp/prism-runtime
chmod 700 /tmp/prism-runtime
export XDG_RUNTIME_DIR=/tmp/prism-runtime
xvfb-run -a prismtranslate --smoke-test
PRISM_PY_VERSION=$(python3 -c 'import sys; print(".".join(map(str,sys.version_info[:2])))')
PRISM_RUNTIME="/tmp/prism-data/prismtranslate/runtime-$(cat /usr/lib/prismtranslate/runtime-id)-py$PRISM_PY_VERSION"
PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a "$PRISM_RUNTIME/bin/python" \
    -m unittest discover -s /repo/linux/tests -v
# A real EWMH window manager with a reserved 27px top panel.
PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a -s "-screen 0 1280x900x24" \
    "$PRISM_RUNTIME/bin/python" /repo/linux/tests/wm_fixture.py
# A dock exposed by the real hold/release gesture must hide before freezing
# the frame. Check both ring OCR modes, directions, preview/crop and cancel.
PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a -s "-screen 0 1280x900x24" \
    "$PRISM_RUNTIME/bin/python" /repo/linux/tests/ring_capture_fixture.py
# Mutter (GNOME's WM) refuses to minimize non-NORMAL windows; Openbox does not.
PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a -s "-screen 0 1280x900x24" \
    dbus-run-session -- bash /repo/linux/tests/with_mutter.sh \
    "$PRISM_RUNTIME/bin/python" /repo/linux/tests/minimize_fixture.py
# Verify the tar launcher can run with the same bundled dependencies.
mkdir -p /tmp/prism-tar
tar -xzf /repo/build-linux/prismtranslate-0.2.0-linux-amd64.tar.gz -C /tmp/prism-tar
xvfb-run -a /tmp/prism-tar/prismtranslate-0.2.0-linux-amd64/bin/prismtranslate --smoke-test
if [ -d /verification ]; then
    PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a -s "-screen 0 1280x900x24" \
        "$PRISM_RUNTIME/bin/python" /repo/linux/tests/preview.py \
        "/verification/ubuntu-$(. /etc/os-release; echo "$VERSION_ID").png"
    PYTHONPATH=/usr/lib/prismtranslate xvfb-run -a -s "-screen 0 1280x900x24" \
        "$PRISM_RUNTIME/bin/python" /repo/linux/tests/preview.py \
        "/verification/ubuntu-$(. /etc/os-release; echo "$VERSION_ID")-dark.png" --dark
fi
echo "PASS: Ubuntu $(. /etc/os-release; echo "$VERSION_ID") amd64 — deb, tar, Qt X11, HTTP, OCR, hotkey"
