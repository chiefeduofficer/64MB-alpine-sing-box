
#!/bin/sh
#
# Alpine Linux 64MB RAM sing-box installer
# Low memory / BusyBox wget compatible
# Official GitHub Release
#

set -eu

REPO="SagerNet/sing-box"
INSTALL_DIR="/usr/local/bin"
INSTALL_BIN="$INSTALL_DIR/sing-box"

echo "========================================"
echo " Alpine 64MB sing-box installer"
echo "========================================"

# 1. Root check
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] Please run as root"
    exit 1
fi

# 2. Check required commands
for cmd in wget tar uname awk sed grep mkdir rm chmod mv df; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $cmd"
        exit 1
    fi
done

# 3. Detect CPU architecture
case "$(uname -m)" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l|armv7)
        ARCH="armv7"
        ;;
    i386|i486|i586|i686)
        ARCH="386"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac

echo "[INFO] Architecture: $ARCH"

# 4. Select writable working directory
WORK=""

for d in /root /var/cache /var/tmp /tmp; do
    if [ -d "$d" ] && [ -w "$d" ]; then
        WORK="$d"
        break
    fi
done

if [ -z "$WORK" ]; then
    echo "[ERROR] No writable working directory"
    exit 1
fi

# 5. Temporary files
PREFIX="$WORK/singbox-install-$$"
JSON="$PREFIX.json"
PKG="$PREFIX.tar.gz"
EXTRACT="$PREFIX"
BIN_TMP="$INSTALL_BIN.tmp.$$"

cleanup() {
    rm -f "$JSON" "$PKG" "$BIN_TMP"
    rm -rf "$EXTRACT"
}

trap cleanup EXIT
trap 'exit 1' INT TERM HUP

echo "[INFO] Working directory: $WORK"

# 6. Get latest stable release
echo "[INFO] Checking latest stable release..."

API="https://api.github.com/repos/$REPO/releases/latest"

wget -q -O "$JSON" "$API" || {
    echo "[ERROR] Cannot access GitHub API"
    exit 1
}

VERSION=$(sed -n \
    's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    "$JSON" | sed -n '1p')

if [ -z "$VERSION" ]; then
    echo "[ERROR] Cannot detect release version"
    exit 1
fi

echo "[INFO] Latest stable version: $VERSION"

# 7. Download official binary archive
URL="https://github.com/$REPO/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"

echo "[INFO] Downloading sing-box..."
echo "[INFO] Download target: $URL"

# BusyBox wget compatible
wget -q -O "$PKG" "$URL" || {
    echo "[ERROR] Download failed"
    exit 1
}

if [ ! -s "$PKG" ]; then
    echo "[ERROR] Downloaded archive is empty"
    exit 1
fi

echo "[INFO] Download completed"

# 8. Check archive integrity
echo "[INFO] Checking archive..."

tar -tzf "$PKG" >/dev/null 2>&1 || {
    echo "[ERROR] Invalid or corrupted archive"
    exit 1
}

# 9. Extract on disk, not RAM
echo "[INFO] Extracting archive..."

mkdir "$EXTRACT"

tar -xzf "$PKG" -C "$EXTRACT" || {
    echo "[ERROR] Extraction failed"
    exit 1
}

# 10. Locate binary
BIN=""

for d in "$EXTRACT"/*; do
    if [ -f "$d/sing-box" ]; then
        BIN="$d/sing-box"
        break
    fi
done

if [ -z "$BIN" ]; then
    echo "[ERROR] sing-box binary not found"
    exit 1
fi

# 11. Install binary
echo "[INFO] Installing sing-box..."

mkdir -p "$INSTALL_DIR"

cp "$BIN" "$BIN_TMP"
chmod 755 "$BIN_TMP"
mv -f "$BIN_TMP" "$INSTALL_BIN"

# 12. Verify installation
echo
echo "========================================"
echo " Installation completed successfully"
echo "========================================"

echo "[INFO] Installed binary:"
echo "$INSTALL_BIN"

echo
echo "[INFO] sing-box version:"

"$INSTALL_BIN" version || {
    echo "[ERROR] Binary cannot execute"
    exit 1
}

echo
echo "[INFO] Installation finished."
echo "========================================"
