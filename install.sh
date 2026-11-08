
#!/bin/bash
# Alpine 64MB NAT sing-box Lite Installer
# Version: 2.0
# Official GitHub Release + SHA256 verification
# Stream download + extract only sing-box binary

set -Eeuo pipefail
umask 077

REPO="SagerNet/sing-box"
DEST="/usr/local/bin/sing-box"
WORK="/root/.singbox-install"
API="https://api.github.com/repos/${REPO}/releases/latest"

info() { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
err()  { echo "[ERROR] $*" >&2; }

# Root check
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行"
    exit 1
fi

# Check Alpine
if [ ! -f /etc/alpine-release ]; then
    err "此脚本专门针对 Alpine Linux"
    exit 1
fi

# Check dependencies
for cmd in bash curl jq tar tee sha256sum awk uname mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "缺少依赖: $cmd"
        err "请执行: apk add --no-cache bash curl jq tar coreutils"
        exit 1
    fi
done

# Detect architecture
case "$(uname -m)" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l)
        ARCH="armv7"
        ;;
    *)
        err "不支持的 CPU 架构: $(uname -m)"
        exit 1
        ;;
esac

# Alpine uses musl
LIBC="-musl"

info "系统: Alpine Linux"
info "架构: ${ARCH}"
info "C 库: musl"

# Use disk-backed directory, never /tmp
mkdir -p "$WORK"
chmod 700 "$WORK"

# Clean stale installer files
find "$WORK" -maxdepth 1 -type f \
    -name 'sb-install.*' -delete 2>/dev/null || true

TMP="$(mktemp -d "$WORK/sb-install.XXXXXX")"
OUT="$TMP/sing-box"
DIGEST="$TMP/archive.sha256"
META="$TMP/release.json"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

# Fetch release metadata
info "获取 GitHub 最新稳定版..."

curl -fsSL \
    --connect-timeout 15 \
    --max-time 60 \
    "$API" -o "$META" || {
        err "无法获取 GitHub Release 信息"
        exit 1
    }

# Parse and validate release metadata
RELEASE="$(jq -er '
    select(.draft == false and .prerelease == false)
    | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | .tag_name
' "$META")" || {
    err "无法识别稳定版版本号"
    exit 1
}

VERSION="${RELEASE#v}"

# Find exact musl asset
ASSET="sing-box-${VERSION}-linux-${ARCH}${LIBC}.tar.gz"

ASSET_INFO="$(jq -er --arg name "$ASSET" '
    [.assets[] | select(.name == $name)] as $a
    | select(($a | length) == 1)
    | [
        $a[0].browser_download_url,
        $a[0].digest
      ]
    | @tsv
' "$META")" || {
    err "没有找到对应架构的官方 musl 安装包: $ASSET"
    exit 1
}

IFS=$'\t' read -r URL EXPECTED_DIGEST <<< "$ASSET_INFO"

# Validate download URL and digest
EXPECTED_URL="https://github.com/${REPO}/releases/download/${RELEASE}/${ASSET}"

if [ "$URL" != "$EXPECTED_URL" ]; then
    err "下载地址校验失败"
    exit 1
fi

if [[ ! "$EXPECTED_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
    err "官方 SHA256 摘要无效，拒绝安装"
    exit 1
fi

EXPECTED_DIGEST="${EXPECTED_DIGEST#sha256:}"

info "版本: ${VERSION}"
info "安装包: ${ASSET}"
info "开始流式下载与解压..."

# Extract only the main executable.
# tee sends the same compressed stream to SHA256 and tar.
ENTRY="sing-box-${VERSION}-linux-${ARCH}${LIBC}/sing-box"

set +e
curl -fLsS \
    --retry 2 \
    --connect-timeout 15 \
    --max-time 900 \
    "$URL" |
    tee >(sha256sum > "$DIGEST") |
    tar -xzOf - "$ENTRY" > "$OUT"

STATUS=("${PIPESTATUS[@]}")
set -e

if [ "${STATUS[0]}" -ne 0 ] || \
   [ "${STATUS[1]}" -ne 0 ] || \
   [ "${STATUS[2]}" -ne 0 ]; then
    err "下载或流式解压失败"
    exit 1
fi

# Wait for digest process to finish
WAIT=0
while [ ! -s "$DIGEST" ] && [ "$WAIT" -lt 100 ]; do
    sleep 0.1
    WAIT=$((WAIT + 1))
done

if [ ! -s "$DIGEST" ]; then
    err "SHA256 计算失败"
    exit 1
fi

ACTUAL_DIGEST="$(awk '{print $1}' "$DIGEST")"

if [ "${ACTUAL_DIGEST,,}" != "${EXPECTED_DIGEST,,}" ]; then
    err "SHA256 校验失败，拒绝安装"
    exit 1
fi

ok "SHA256 校验通过"

# Verify extracted binary
if [ ! -s "$OUT" ]; then
    err "提取的 sing-box 文件为空"
    exit 1
fi

chmod 755 "$OUT"

if ! "$OUT" version >/dev/null 2>&1; then
    err "sing-box 二进制无法运行"
    exit 1
fi

ACTUAL_VERSION="$("$OUT" version 2>/dev/null |
    sed -n 's/^sing-box version \([^ ]*\).*/\1/p' |
    head -n 1)"

if [ "$ACTUAL_VERSION" != "$VERSION" ]; then
    err "版本校验不一致"
    exit 1
fi

# Atomic installation
mkdir -p "$(dirname "$DEST")"

NEW="${DEST}.new.$$"

cp "$OUT" "$NEW"
chmod 755 "$NEW"

if ! "$NEW" version >/dev/null 2>&1; then
    rm -f "$NEW"
    err "安装前二次验证失败"
    exit 1
fi

mv -f "$NEW" "$DEST"

ok "sing-box 安装成功"
echo "--------------------------------"
echo "版本: $VERSION"
echo "架构: $ARCH"
echo "路径: $DEST"
echo "校验: SHA256 OK"
echo "--------------------------------"

"$DEST" version

echo
ok "安装完成！没有自动启动服务。"
