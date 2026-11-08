
#!/usr/bin/env bash
#
# Alpine 64MB NAT sing-box Lite Installer
# Version: 3.2
#
# Features:
#   - Pipeline-safe bootstrap
#   - Automatic dependency installation
#   - Alpine / musl detection
#   - AMD64 / ARM64 / ARMv7
#   - GitHub latest stable release
#   - Resume download and retry
#   - Official SHA256 verification
#   - Archive structure verification
#   - Disk space preflight
#   - Atomic installation
#   - Automatic rollback
#   - Installation lock
#   - Automatic cleanup
#
# Usage:
#   wget -qO- URL | bash
#   bash install.sh
#
# Does NOT automatically start sing-box.

set -Eeuo pipefail
umask 077

# ============================================================
# Configuration
# ============================================================

VERSION_SCRIPT="3.2"

REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

DEST="/usr/local/bin/sing-box"
WORK="/root/.singbox-install"

LOCK_DIR="/run/sing-box-installer.lock"

MAX_RETRIES=3
CONNECT_TIMEOUT=15
DOWNLOAD_TIMEOUT=1800

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
OUT=""
NEW=""
BACKUP=""

ARCH=""
LIBC="musl"

RELEASE=""
VERSION=""
ASSET=""
URL=""
EXPECTED_DIGEST=""
ASSET_SIZE=""

ENTRY=""

LOCKED=0
ROLLBACK_ACTIVE=0
HAD_OLD=0
PRESERVE_BACKUP=0

# ============================================================
# Bootstrap
# ============================================================

bootstrap() {
    info "检查运行环境..."

    [ "$(id -u)" -eq 0 ] || \
        die "请使用 root 运行"

    [ -f /etc/alpine-release ] || \
        die "此脚本仅支持 Alpine Linux"

    command -v apk >/dev/null 2>&1 || \
        die "未找到 Alpine apk 包管理器"

    info "检查依赖..."

    local packages=()
    local cmd

    for cmd in curl jq tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                curl)      packages+=(curl) ;;
                jq)        packages+=(jq) ;;
                tar)       packages+=(tar) ;;
                sha256sum) packages+=(coreutils) ;;
            esac
        fi
    done

    if [ "${#packages[@]}" -gt 0 ]; then
        info "安装缺失依赖: ${packages[*]}"

        apk add --no-cache "${packages[@]}" || \
            die "依赖安装失败"
    fi

    for cmd in curl jq tar sha256sum awk sed head wc df mktemp uname grep; do
        command -v "$cmd" >/dev/null 2>&1 || \
            die "缺少必要命令: $cmd"
    done

    ok "依赖检查完成"
    ok "当前 Shell: Bash ${BASH_VERSION}"
}

# ============================================================
# Installation lock
# ============================================================

acquire_lock() {
    info "获取安装锁..."

    mkdir -p /run

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "另一个安装任务可能正在运行。
如确认没有安装任务，请检查锁目录: $LOCK_DIR"
    fi

    LOCKED=1

    printf '%s\n' "$$" > "$LOCK_DIR/pid"

    ok "安装锁已获取"
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

    info "系统: Alpine Linux"
    info "架构: $ARCH"
    info "C 库: $LIBC"

    ok "架构识别完成"
}

# ============================================================
# Workspace
# ============================================================

prepare_workspace() {
    info "准备临时工作目录..."

    mkdir -p "$WORK"
    chmod 700 "$WORK"

    TMP="$(mktemp -d "$WORK/sb-install.XXXXXX")"

    ARCHIVE="$TMP/sing-box.tar.gz"
    META="$TMP/release.json"
    OUT="$TMP/sing-box"

    mkdir -p "$(dirname "$DEST")"

    NEW="$(dirname "$DEST")/.sing-box.new.$$"
    BACKUP="$(dirname "$DEST")/.sing-box.backup.$$"

    ok "临时目录: $TMP"
}

# ============================================================
# Disk space
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
    info "可用空间: $((available / 1024 / 1024)) MB"

    [ "$available" -ge "$required" ] || \
        die "磁盘空间不足: $path"
}

# ============================================================
# GitHub API
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
        -H "User-Agent: Alpine-sing-box-Lite-Installer" \
        "$url" \
        -o "$output"
}

fetch_release() {
    info "获取 GitHub 最新稳定版..."

    http_get "$API" "$META" || \
        die "获取 GitHub Release 失败"

    RELEASE="$(
        jq -er '
            select(.draft == false and .prerelease == false)
            | select(
                .tag_name |
                test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")
            )
            | .tag_name
        ' "$META"
    )" || die "无法识别最新稳定版"

    VERSION="${RELEASE#v}"

    ASSET="sing-box-${VERSION}-linux-${ARCH}-musl.tar.gz"

    local count

    count="$(
        jq --arg name "$ASSET" \
            '[.assets[] | select(.name == $name)] | length' \
            "$META"
    )"

    [ "$count" = "1" ] || \
        die "未找到对应架构的官方安装包: $ASSET"

    URL="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .browser_download_url
        ' "$META"
    )" || die "无法读取下载地址"

    EXPECTED_DIGEST="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .digest
        ' "$META"
    )" || die "GitHub Release 没有提供 SHA256 摘要"

    ASSET_SIZE="$(
        jq -er --arg name "$ASSET" '
            .assets[] | select(.name == $name) |
            .size
        ' "$META"
    )" || die "无法读取安装包大小"

    local expected_url

    expected_url="https://github.com/${REPO}/releases/download/${RELEASE}/${ASSET}"

    [ "$URL" = "$expected_url" ] || \
        die "下载地址验证失败"

    [[ "$EXPECTED_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || \
        die "官方 SHA256 格式无效"

    [[ "$ASSET_SIZE" =~ ^[0-9]+$ ]] || \
        die "安装包大小无效"

    [ "$ASSET_SIZE" -gt 0 ] || \
        die "安装包大小为零"

    EXPECTED_DIGEST="${EXPECTED_DIGEST#sha256:}"

    info "版本: $VERSION"
    info "安装包: $ASSET"
    info "大小: $((ASSET_SIZE / 1024 / 1024)) MB"

    ok "Release 信息验证通过"
}

# ============================================================
# Download with resume
# ============================================================

download_once() {
    curl -fLsS \
        -C - \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_TIMEOUT" \
        --retry 0 \
        --progress-bar \
        -H "User-Agent: Alpine-sing-box-Lite-Installer" \
        "$URL" \
        -o "$ARCHIVE"
}

download_release() {
    info "检查下载空间..."

    check_disk_space "$WORK" \
        "$((ASSET_SIZE * 3 + DISK_RESERVE))"

    local attempt
    local current_size

    info "开始下载..."

    for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
        info "下载尝试 ${attempt}/${MAX_RETRIES}"

        if download_once; then
            break
        fi

        current_size=0

        if [ -f "$ARCHIVE" ]; then
            current_size="$(wc -c < "$ARCHIVE")"
        fi

        if [ "$current_size" -eq "$ASSET_SIZE" ]; then
            break
        fi

        warn "下载中断，保留已下载部分并重试"

        [ "$attempt" -lt "$MAX_RETRIES" ] && \
            sleep "$((attempt * 2))"
    done

    [ -f "$ARCHIVE" ] || {
        rm -f "$ARCHIVE"
        die "下载文件不存在"
    }

    current_size="$(wc -c < "$ARCHIVE")"

    if [ "$current_size" -ne "$ASSET_SIZE" ]; then
        warn "续传未完成，重新下载..."

        rm -f "$ARCHIVE"

        curl -fLsS \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$DOWNLOAD_TIMEOUT" \
            --retry 3 \
            --retry-delay 2 \
            --retry-connrefused \
            --progress-bar \
            -H "User-Agent: Alpine-sing-box-Lite-Installer" \
            "$URL" \
            -o "$ARCHIVE" || \
            die "重新下载失败"
    fi

    current_size="$(wc -c < "$ARCHIVE")"

    [ "$current_size" -eq "$ASSET_SIZE" ] || \
        die "安装包大小不匹配"

    ok "下载完成"
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
# Archive verification
# ============================================================

extract_binary() {
    info "检查压缩包结构..."

    ENTRY="sing-box-${VERSION}-linux-${ARCH}-musl/sing-box"

    # FIX 1:
    # Avoid tar | grep -q pipeline and pipefail issues.
    tar -tzf "$ARCHIVE" > "$TMP/archive.list" || \
        die "压缩包目录读取失败"

    grep -Fxq "$ENTRY" "$TMP/archive.list" || \
        die "压缩包中没有找到目标二进制"

    info "提取 sing-box..."

    if ! tar -xzf "$ARCHIVE" -O "$ENTRY" > "$OUT"; then
        die "提取二进制失败"
    fi

    [ -s "$OUT" ] || \
        die "提取的二进制为空"

    chmod 755 "$OUT"

    if ! "$OUT" version >/dev/null 2>&1; then
        die "二进制无法运行，可能存在架构或 musl 兼容问题"
    fi

    local actual_version

    actual_version="$(
        "$OUT" version 2>/dev/null |
        sed -n 's/^sing-box version \([^ ]*\).*/\1/p' |
        head -n 1
    )"

    [ "$actual_version" = "$VERSION" ] || \
        die "二进制版本验证失败"

    ok "二进制结构和版本验证通过"
}

# ============================================================
# Installation preflight
# ============================================================

install_preflight() {
    local new_size
    local old_size=0
    local required

    new_size="$(wc -c < "$OUT")"

    if [ -f "$DEST" ]; then
        old_size="$(wc -c < "$DEST")"
    fi

    required="$((new_size + old_size + DISK_RESERVE))"

    info "检查安装目录空间..."

    check_disk_space "$(dirname "$DEST")" "$required"

    ok "安装目录空间充足"
}

# ============================================================
# Atomic installation
# ============================================================

install_binary() {
    info "开始安装..."

    if [ -e "$DEST" ]; then
        [ -f "$DEST" ] || \
            die "目标路径存在，但不是普通文件"

        cp -p "$DEST" "$BACKUP" || \
            die "备份旧版本失败"

        HAD_OLD=1

        ok "旧版本备份完成"
    fi

    cp "$OUT" "$NEW" || \
        die "复制新版本失败"

    chmod 755 "$NEW"

    if ! "$NEW" version >/dev/null 2>&1; then
        die "安装前二次验证失败"
    fi

    ROLLBACK_ACTIVE=1

    mv -f "$NEW" "$DEST" || \
        die "原子替换失败"

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
        die "安装后的版本号不匹配"

    # FIX 2:
    # Commit transaction BEFORE removing backup.
    # Backup cleanup failure must not trigger rollback.
    ROLLBACK_ACTIVE=0

    if [ "$HAD_OLD" -eq 1 ]; then
        if ! rm -f "$BACKUP"; then
            warn "安装成功，但旧版本备份未能清理: $BACKUP"
        fi
    fi

    ok "安装成功"
}

# ============================================================
# Cleanup and rollback
# ============================================================

cleanup() {
    local rc=$?

    trap - EXIT INT TERM

    if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then
        warn "安装未完成，正在回滚..."

        if [ "$HAD_OLD" -eq 1 ] && [ -f "$BACKUP" ]; then
            if mv -f "$BACKUP" "$DEST"; then
                ok "旧版本恢复成功"
            else
                err "回滚失败，保留备份: $BACKUP"
                PRESERVE_BACKUP=1
                rc=1
            fi
        else
            if ! rm -f "$DEST"; then
                err "无法清除不完整安装文件"
                rc=1
            else
                warn "已清除不完整的新版本"
            fi
        fi
    fi

    [ -n "$NEW" ] && rm -f "$NEW"

    if [ "$PRESERVE_BACKUP" -eq 0 ]; then
        [ -n "$BACKUP" ] && rm -f "$BACKUP"
    fi

    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi

    if [ "$LOCKED" -eq 1 ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi

    exit "$rc"
}

on_signal() {
    local signal="$1"

    warn "收到中断信号: $signal"

    case "$signal" in
        INT)  exit 130 ;;
        TERM) exit 143 ;;
    esac
}

# ============================================================
# Main
# ============================================================

main() {
    bootstrap

    acquire_lock

    detect_arch

    prepare_workspace

    fetch_release

    download_release

    verify_archive

    extract_binary

    install_preflight

    install_binary

    echo
    echo "========================================"
    ok "sing-box 安装完成"
    echo "========================================"

    echo "Installer : V${VERSION_SCRIPT}"
    echo "Version   : ${VERSION}"
    echo "Architecture: ${ARCH}"
    echo "Library   : ${LIBC}"
    echo "Binary    : ${DEST}"
    echo "SHA256    : VERIFIED"
    echo "Rollback  : COMMITTED"
    echo "Service   : NOT STARTED"

    echo "----------------------------------------"

    "$DEST" version

    echo
    ok "V3.2 全部安装流程完成"
}

# ============================================================
# Traps
# ============================================================

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# ============================================================
# Entry
# ============================================================

main "$@"
