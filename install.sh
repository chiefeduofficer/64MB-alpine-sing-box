#!/bin/sh

# Alpine Linux 64MB RAM sing-box installer
# Low memory / BusyBox wget compatible

set -eu

REPO="SagerNet/sing-box"
INSTALL_DIR="/usr/local/bin"
BIN="$INSTALL_DIR/sing-box"

WORK="/root/.sing-box-install-$$"
API="$WORK/release.json"
ARCHIVE="$WORK/sing-box.tar.gz"
EXTRACT="$WORK/extract"

cleanup() {
    rm -rf "$WORK"
}

trap cleanup EXIT
trap 'exit 1' INT TERM

echo "======================================"
echo " Alpine 64MB sing-box Installer"
echo "======================================"

# Root check
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] Please run as root"
    exit 1
fi

# Check required commands
for cmd in wget tar uname grep sed mkdir rm cp chmod; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $cmd"
        exit 1
    fi
done

# Detect architecture
MACHINE="$(uname -m)"

case "$MACHINE" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    armv7l|armv7)
        ARCH="armv7"
        ;;
    armv6l)
        ARCH="armv6"
        ;;
    armv5tel)
        ARCH="armv5"
        ;;
    i386|i486|i586|i686)
        ARCH="386"
        ;;
    mips)
        ARCH="mips"
        ;;
    mipsel)
        ARCH="mipsle"
        ;;
    mips64)
        ARCH="mips64"
        ;;
    mips64el)
        ARCH="mips64le"
        ;;
    riscv64)
        ARCH="riscv64"
        ;;
    s390x)
        ARCH="s390x"
        ;;
    ppc64le)
        ARCH="ppc64le"
        ;;
    loongarch64)
        ARCH="loong64"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: $MACHINE"
        exit 1
        ;;
esac

echo "[INFO] CPU: $MACHINE"
echo "[INFO] Target: linux-$ARCH"

# Check available disk space
mkdir -p /root
mkdir -p "$WORK"
mkdir -p "$INSTALL_DIR"

echo "[INFO] Working directory: $WORK"

# Get latest stable release
echo "[INFO] Fetching latest stable version..."

wget -q -O "$API" \
    "https://api.github.com/repos/$REPO/releases/latest" || {
    echo "[ERROR] Failed to fetch release information"
    exit 1
}

VERSION="$(
    sed -n \
    's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    "$API" | sed -n '1p'
)"

if [ -z "$VERSION" ]; then
    echo "[ERROR] Cannot detect release version"
    exit 1
fi

echo "[INFO] Latest version: $VERSION"

# Construct download URL
URL="https://github.com/$REPO/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"

echo "[INFO] Downloading sing-box..."
echo "[INFO] Download URL: $URL"

# BusyBox wget compatible
wget -q -O "$ARCHIVE" "$URL" || {
    echo "[ERROR] Download failed"
    exit 1
}

# Extract directly to disk
echo "[INFO] Extracting archive..."

mkdir -p "$EXTRACT"

tar -xzf "$ARCHIVE" -C "$EXTRACT" || {
    echo "[ERROR] Extraction failed"
    exit 1
}

# Locate expected binary
SOURCE="$EXTRACT/sing-box-${VERSION}-linux-${ARCH}/sing-box"

if [ ! -f "$SOURCE" ]; then
    echo "[ERROR] sing-box binary not found"
    exit 1
fi

# Install binary
echo "[INFO] Installing sing-box..."

chmod 755 "$SOURCE"
cp "$SOURCE" "$BIN"
chmod 755 "$BIN"

# Verify installation
echo
echo "======================================"
echo " Installation completed!"
echo "======================================"

if "$BIN" version; then
    echo
    echo "[SUCCESS] sing-box installed at:"
    echo "$BIN"
else
    echo "[ERROR] Binary execution failed"
    exit 1
fi

echo "======================================"
