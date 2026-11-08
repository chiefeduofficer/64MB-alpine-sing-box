
#!/bin/sh
# Alpine 64MB sing-box V3
# Single binary installer
# No gzip / tar / curl / jq / bash on VPS

set -eu
umask 077

# 修改为你自己的 GitHub 仓库
REPO="${SB_REPO:-YOUR_GITHUB_USERNAME/alpine-sing-box}"
DEST="/usr/local/bin/sing-box"
BACKUP="${DEST}.bak"

info() { echo "[INFO] $*"; }
ok()   { echo "[OK] $*"; }
fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Root
[ "$(id -u)" = "0" ] || fail "请使用 root 运行"

# Alpine
[ -f /etc/alpine-release ] || fail "仅支持 Alpine Linux"

# Version argument
VERSION="${1:-}"

[ -n "$VERSION" ] || {
    echo "用法: $0 <version>"
    echo "示例: $0 1.14.4"
    exit 1
}

VERSION="${VERSION#v}"

case "$VERSION" in
    *[!0-9.]*|.*|*.)
        fail "版本格式错误: $VERSION"
        ;;
esac

case "$VERSION" in
    *..*)
        fail "版本格式错误: $VERSION"
        ;;
esac

# Architecture
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *)
        fail "暂不支持架构: $(uname -m)"
        ;;
esac

# BusyBox wget
command -v wget >/dev/null 2>&1 || fail "缺少 wget"

# SHA256
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
elif busybox sha256sum --help >/dev/null 2>&1; then
    SHA_CMD="busybox sha256sum"
else
    fail "缺少 SHA256 工具"
fi

# URLs
TAG="sing-box-v${VERSION}"
ASSET="sing-box-linux-${ARCH}"

BASE="https://github.com/${REPO}/releases/download/${TAG}"

BIN_URL="${BASE}/${ASSET}"
SUM_URL="${BASE}/${ASSET}.sha256"

# Temp files in destination directory:
# same filesystem makes final rename atomic.
mkdir -p "$(dirname "$DEST")"

TMP_BIN="${DEST}.download.$$"
TMP_SUM="${DEST}.sha256.$$"
TMP_BACKUP="${BACKUP}.tmp.$$"

cleanup() {
    rm -f "$TMP_BIN" "$TMP_SUM" "$TMP_BACKUP"
}
trap cleanup EXIT HUP INT TERM

info "Alpine: $(cat /etc/alpine-release)"
info "版本: $VERSION"
info "架构: $ARCH"
info "来源: $REPO"

# Download binary
info "下载 sing-box 单文件..."

wget -q -T 20 -t 3 \
    -O "$TMP_BIN" "$BIN_URL" || {
        fail "二进制下载失败"
    }

[ -s "$TMP_BIN" ] || fail "下载文件为空"

# Download checksum
info "下载 SHA256..."

wget -q -T 20 -t 3 \
    -O "$TMP_SUM" "$SUM_URL" || {
        fail "SHA256 下载失败"
    }

[ -s "$TMP_SUM" ] || fail "SHA256 文件为空"

EXPECTED="$(awk 'NR==1 {print $1}' "$TMP_SUM")"

# Check SHA256 format
case "$EXPECTED" in
    *[!0123456789abcdefABCDEF]*|'')
        fail "SHA256 格式错误"
        ;;
esac

[ "${#EXPECTED}" -eq 64 ] || fail "SHA256 长度错误"

# Calculate SHA256
info "正在校验文件..."

ACTUAL="$($SHA_CMD "$TMP_BIN" | awk '{print $1}')"

[ "$ACTUAL" = "$EXPECTED" ] || {
    fail "SHA256 校验失败，拒绝安装"
}

ok "SHA256 校验通过"

# Preserve previous version
if [ -e "$DEST" ]; then
    info "备份当前版本..."

    # Prefer hard link to avoid copying the old binary.
    if ! ln "$DEST" "$TMP_BACKUP" 2>/dev/null; then
        cp -p "$DEST" "$TMP_BACKUP" || fail "旧版本备份失败"
    fi

    mv -f "$TMP_BACKUP" "$BACKUP" || {
        fail "旧版本备份提交失败"
    }

    ok "旧版本已备份: $BACKUP"
fi

# Atomic replace
chmod 755 "$TMP_BIN"

mv -f "$TMP_BIN" "$DEST" || {
    fail "安装失败，旧版本备份仍然保留"
}

ok "sing-box 安装成功"

echo "--------------------------------"
echo "版本: $VERSION"
echo "架构: $ARCH"
echo "路径: $DEST"
echo "SHA256: $ACTUAL"

if [ -f "$BACKUP" ]; then
    echo "备份: $BACKUP"
fi

echo "--------------------------------"
echo "注意: 本脚本没有启动 sing-box"
