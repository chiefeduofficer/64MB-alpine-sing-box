
#!/usr/bin/env bash
#
# Alpine 64MB NAT sing-box Lite Installer
# Version: 3.0
# Official GitHub Release + SHA256
# Resume Download + Disk Preflight + Atomic Install + Rollback
#
# Supported:
#   Alpine Linux / musl
#   x86_64 / aarch64 / armv7l
#
# Install:
#   bash install.sh
#
# No automatic service startup.

set -Eeuo pipefail
umask 077

# ============================================================
# Configuration
# ============================================================

REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

DEST="/usr/local/bin/sing-box"
WORK="/root/.singbox-install"

MAX_RETRIES=3
CONNECT_TIMEOUT=15
DOWNLOAD_TIMEOUT=1800

# Reserve disk space for filesystem overhead.
DISK_RESERVE=$((1024 * 1024))

# ============================================================
# Logging
# ============================================================

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK]   %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

err() {
    printf '[ERROR] %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

# ============================================================
# Global variables
# ============================================================

TMP=""
ARCHIVE=""
META=""
NEW=""
BACKUP=""

ROLLBACK_ACTIVE=0
HAD_OLD=0

# ============================================================
# Cleanup and rollback
# ============================================================

cleanup() {
    local rc=$?

    trap - EXIT INT TERM

    if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then
        warn "检测到安装未完成，执行回滚..."

        rm -f "$DEST"

        if [ "$HAD_OLD" -eq 1 ] && [ -f "$BACKUP" ]; then
            if mv -f "$BACKUP" "$DEST"; then
                ok "旧版本已恢复"
            else
                err "回滚失败！备份文件保留在: $BACKUP"
                rc=1
            fi
        else
            warn "原先不存在旧版本，已清除不完整安装"
        fi
    fi

    [ -n "$NEW" ] && rm -f "$NEW"
    [ -n "$BACKUP" ] && rm -f "$BACKUP"

    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi

    exit "$rc"
}

on_signal() {
    local signal="$1"

    case "$signal" in
        INT)  exit 130 ;;
        TERM) exit 143 ;;
    esac
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# ============================================================
# Environment checks
# ============================================================

check_environment() {
    info "检查运行环境..."

    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

    [ -f /etc/alpine-release ] || \
        die "此脚本仅支持 Alpine Linux"

    local deps=(
        bash curl jq tar sha256sum
        awk sed head wc df
        uname mkdir chmod cp mv rm
        mktemp sleep dirname
    )

    local missing=()

    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || \
            missing+=("$cmd")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        err "缺少依赖: ${missing[*]}"
        err "请执行:"
        err "apk add --no-cache bash curl jq tar coreutils"
        exit 1
    fi

    ok "环境检查通过"
}

# ============================================================
# Architecture detection
# ============================================================

detect_arch() {
    local machine
    machine="$(uname -m)"

    case "$machine" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv7)
            ARCH="armv7"
            ;;
        *)
            die "不支持的 CPU 架构: $machine"
            ;;
    esac

    LIBC="musl"

    info "系统: Alpine Linux"
    info "架构: ${ARCH}"
    info "C 库: ${LIBC}"
}

# ============================================================
# Disk space checking
# ============================================================

available_bytes() {
    local path="$1"
    local kb

    kb="$(df -Pk "$path" | awk 'END {print $4}')"

    [[ "$kb" =~ ^[0-9]+$ ]] || \
        die "无法读取磁盘剩余空间: $path"

    printf '%s\n' "$((kb * 1024))"
}

check_disk_space() {
    local path="$1"
    local required="$2"
    local available

    available="$(available_bytes "$path")"

    info "磁盘检查: $path"
    info "需要空间: $((required / 1024 / 1024)) MB"
    info "剩余空间: $((available / 1024 / 1024)) MB"

    if [ "$available" -lt "$required" ]; then
        die "磁盘空间不足: $path"
    fi
}

# ============================================================
# Prepare working directory
# ============================================================

prepare_workspace() {
    info "准备临时目录..."

    mkdir -p "$WORK"
    mkdir -p "$(dirname "$DEST")"

    chmod 700 "$WORK"

    TMP="$(mktemp -d "$WORK/sb-install.XXXXXX")"

    ARCHIVE="$TMP/sing-box.tar.gz"
    META="$TMP/release.json"

    NEW="$(dirname "$DEST")/.sing-box.new.$$"
    BACKUP="$(dirname "$DEST")/.sing-box.backup.$$"

    ok "临时目录: $TMP"
}

# ============================================================
# HTTP helper
# ============================================================

http_get() {
    local url="$1"
    local output="$2"

    curl -fLsS \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time 120 \
        --retry 3 \
        --retry-delay 2 \
        --retry-connrefused \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: Alpine-sing-box-Installer-V3" \
        "$url" \
        -o "$output"
}

# ============================================================
# Fetch release information
# ============================================================

fetch_release() {
    info "获取 GitHub 最新稳定版..."

    http_get "$API" "$META" || \
        die "无法获取 GitHub Release 信息"

    RELEASE="$(
        jq -er '
            select(.draft == false and .prerelease == false)
            | select(
                .tag_name |
                test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")
            )
            | .tag_name
        ' "$META"
    )" || die "无法识别稳定版版本号"

    VERSION="${RELEASE#v}"

    ASSET="sing-box-${VERSION}-linux-${ARCH}-musl.tar.gz"

    local count

    count="$(
        jq --arg name "$ASSET" \
            '[.assets[] | select(.name == $name)] | length' \
            "$META"
    )"

    [ "$count" = "1" ] || \
        die "没有找到唯一的官方安装包: $ASSET"

    URL="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .browser_download_url
        ' "$META"
    )" || die "无法读取安装包下载地址"

    EXPECTED_DIGEST="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .digest
        ' "$META"
    )" || die "GitHub 未提供 SHA256 摘要"

    ASSET_SIZE="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .size
        ' "$META"
    )" || die "无法读取安装包大小"

    EXPECTED_URL="https://github.com/${REPO}/releases/download/${RELEASE}/${ASSET}"

    [ "$URL" = "$EXPECTED_URL" ] || \
        die "下载地址校验失败"

    [[ "$EXPECTED_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || \
        die "官方 SHA256 格式无效"

    [[ "$ASSET_SIZE" =~ ^[0-9]+$ ]] || \
        die "安装包大小无效"

    [ "$ASSET_SIZE" -gt 0 ] || \
        die "安装包大小为零"

    EXPECTED_DIGEST="${EXPECTED_DIGEST#sha256:}"

    info "版本: $VERSION"
    info "安装包: $ASSET"
    info "下载大小: $((ASSET_SIZE / 1024 / 1024)) MB"

    ok "Release 信息验证通过"
}

# ============================================================
# Download with resume and retry
# ============================================================

download_release() {
    info "检查下载目录空间..."

    check_disk_space "$WORK" \
        "$((ASSET_SIZE + DISK_RESERVE))"

    local attempt
    local current_size

    info "开始下载官方安装包..."

    for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do

        info "下载尝试 ${attempt}/${MAX_RETRIES}"

        # -C - automatically resumes from existing file size.
        if curl -fLsS \
            -C - \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$DOWNLOAD_TIMEOUT" \
            --retry 0 \
            --progress-bar \
            -H "User-Agent: Alpine-sing-box-Installer-V3" \
            "$URL" \
            -o "$ARCHIVE"; then

            break
        fi

        current_size=0

        if [ -f "$ARCHIVE" ]; then
            current_size="$(wc -c < "$ARCHIVE")"
        fi

        # HTTP 416 can occur if the previous transfer
        # already completed. Verify size before accepting.
        if [ "$current_size" -eq "$ASSET_SIZE" ]; then
            break
        fi

        warn "下载中断，准备继续续传..."

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep 2
        fi
    done

    [ -f "$ARCHIVE" ] || \
        die "下载文件不存在"

    current_size="$(wc -c < "$ARCHIVE")"

    # If resume failed, make one clean retry sequence.
    if [ "$current_size" -ne "$ASSET_SIZE" ]; then
        warn "续传未完成，尝试重新下载..."

        rm -f "$ARCHIVE"

        curl -fLsS \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$DOWNLOAD_TIMEOUT" \
            --retry 3 \
            --retry-delay 2 \
            --retry-connrefused \
            --progress-bar \
            -H "User-Agent: Alpine-sing-box-Installer-V3" \
            "$URL" \
            -o "$ARCHIVE" || \
            die "重新下载失败"
    fi

    current_size="$(wc -c < "$ARCHIVE")"

    [ "$current_size" -eq "$ASSET_SIZE" ] || \
        die "文件大小不匹配"

    ok "下载完成，文件大小正确"
}

# ============================================================
# SHA256 verification
# ============================================================

verify_archive() {
    info "正在校验 SHA256..."

    local actual

    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    [ "${actual,,}" = "${EXPECTED_DIGEST,,}" ] || \
        die "SHA256 校验失败，拒绝安装"

    ok "SHA256 校验通过"
}

# ============================================================
# Extract binary
# ============================================================

extract_binary() {
    info "正在提取 sing-box..."

    ENTRY="sing-box-${VERSION}-linux-${ARCH}-musl/sing-box"

    rm -f "$NEW"

    if ! tar -xzf "$ARCHIVE" -O "$ENTRY" > "$NEW"; then
        rm -f "$NEW"
        die "解压 sing-box 失败"
    fi

    [ -s "$NEW" ] || \
        die "提取的二进制文件为空"

    chmod 755 "$NEW"

    if ! "$NEW" version >/dev/null 2>&1; then
        die "二进制无法运行，可能存在架构或 musl 兼容性问题"
    fi

    local actual_version

    actual_version="$(
        "$NEW" version 2>/dev/null |
        sed -n 's/^sing-box version \([^ ]*\).*/\1/p' |
        head -n 1
    )"

    [ "$actual_version" = "$VERSION" ] || \
        die "二进制版本不匹配"

    ok "二进制验证通过"
}

# ============================================================
# Installation preflight
# ============================================================

install_preflight() {
    local new_size
    local old_size=0
    local required

    new_size="$(wc -c < "$NEW")"

    if [ -f "$DEST" ]; then
        old_size="$(wc -c < "$DEST")"
    fi

    # Space for new binary and old-version backup.
    required="$((new_size + old_size + DISK_RESERVE))"

    info "检查安装目录空间..."

    check_disk_space "$(dirname "$DEST")" "$required"

    info "新版本大小: $((new_size / 1024 / 1024)) MB"

    ok "安装空间充足"
}

# ============================================================
# Atomic installation with rollback
# ============================================================

install_binary() {
    info "开始安装..."

    if [ -e "$DEST" ]; then
        info "检测到旧版本，创建回滚备份..."

        cp -p "$DEST" "$BACKUP" || \
            die "创建旧版本备份失败"

        HAD_OLD=1

        ok "旧版本备份完成"
    else
        HAD_OLD=0
        info "未检测到旧版本"
    fi

    # Enable rollback before replacing the destination.
    ROLLBACK_ACTIVE=1

    # NEW and DEST are in the same filesystem.
    mv -f "$NEW" "$DEST" || \
        die "替换安装文件失败"

    chmod 755 "$DEST"

    # Verify installed executable.
    if ! "$DEST" version >/dev/null 2>&1; then
        die "安装后验证失败"
    fi

    local installed_version

    installed_version="$(
        "$DEST" version 2>/dev/null |
        sed -n 's/^sing-box version \([^ ]*\).*/\1/p' |
        head -n 1
    )"

    [ "$installed_version" = "$VERSION" ] || \
        die "安装后版本验证失败"

    # Commit installation.
    if [ "$HAD_OLD" -eq 1 ]; then
        rm -f "$BACKUP" || \
            die "安装成功但无法清理旧版本备份"
    fi

    ROLLBACK_ACTIVE=0

    ok "安装成功"
}

# ============================================================
# Main
# ============================================================

main() {
    info "========================================"
    info " Alpine sing-box Lite Installer V3"
    info "========================================"

    check_environment

    detect_arch

    prepare_workspace

    fetch_release

    download_release

    verify_archive

    extract_binary

    install_preflight

    install_binary

    echo
    info "========================================"
    ok "sing-box 安装完成！"
    info "========================================"

    echo "版本: $VERSION"
    echo "架构: $ARCH"
    echo "C库: musl"
    echo "路径: $DEST"
    echo "校验: SHA256 OK"
    echo "回滚: 已提交"
    echo "服务: 未自动启动"

    echo "----------------------------------------"

    "$DEST" version

    echo
    ok "V3 安装流程全部完成"
}

main "$@"
