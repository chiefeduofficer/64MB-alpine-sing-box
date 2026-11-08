#!/usr/bin/env bash
# Alpine 64MB NAT sing-box Lite Installer
# Version: 3.3
# Low-memory extraction, SHA256 verification, rollback and optional OpenRC service.

set -Eeuo pipefail
umask 077

# ============================================================
# Configuration
# ============================================================
VERSION_SCRIPT="3.3"
REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

DEST="/usr/local/bin/sing-box"
WORK="/root/.singbox-install"
LOCK_DIR="/run/sing-box-installer.lock"

CONFIG_DIR="/etc/sing-box"
CONFIG="${CONFIG_DIR}/config.json"

SERVICE_FILE="/etc/init.d/sing-box"

MAX_RETRIES=3
CONNECT_TIMEOUT=15
DOWNLOAD_TIMEOUT=1800
DISK_RESERVE=$((1024 * 1024))

# ============================================================
# Logging
# ============================================================
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ============================================================
# Global state
# ============================================================
TMP=""
ARCHIVE=""
META=""
OUT=""
NEW=""
BACKUP=""
CONFIG_TMP=""

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
CONFIG_CREATED=0
SERVICE_CREATED=0

# ============================================================
# Exit handling
# ============================================================
on_exit() {
    local status=$?

    trap - EXIT INT TERM
    set +e

    if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then
        warn "安装未完整成功，正在回滚..."

        if [ "$HAD_OLD" -eq 1 ] && [ -f "$BACKUP" ]; then
            mv -f "$BACKUP" "$DEST"
            ok "已恢复旧版 sing-box"
        else
            rm -f "$DEST"
            ok "已移除未完成安装的二进制"
        fi

        if [ "$CONFIG_CREATED" -eq 1 ]; then
            rm -f "$CONFIG"
            ok "已清理本次创建的默认配置"
        fi

        if [ "$SERVICE_CREATED" -eq 1 ]; then
            rm -f "$SERVICE_FILE"
            ok "已清理本次创建的 OpenRC 服务"
        fi
    fi

    [ -n "$NEW" ] && rm -f "$NEW"
    [ -n "$BACKUP" ] && rm -f "$BACKUP"
    [ -n "$CONFIG_TMP" ] && rm -f "$CONFIG_TMP"
    [ -n "$TMP" ] && rm -rf "$TMP"

    if [ "$LOCKED" -eq 1 ]; then
        rm -rf "$LOCK_DIR"
    fi

    exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# Bootstrap
# ============================================================
bootstrap() {
    info "检查运行环境..."

    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
    [ -f /etc/alpine-release ] || die "此脚本仅支持 Alpine Linux"
    command -v apk >/dev/null 2>&1 || die "未找到 apk 包管理器"

    local packages=()
    local cmd

    for cmd in bash curl jq tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                bash)      packages+=(bash) ;;
                curl)      packages+=(curl) ;;
                jq)        packages+=(jq) ;;
                tar)       packages+=(tar) ;;
                sha256sum) packages+=(coreutils) ;;
            esac
        fi
    done

    if [ "${#packages[@]}" -gt 0 ]; then
        info "安装缺失依赖: ${packages[*]}"
        apk add --no-cache "${packages[@]}" || die "依赖安装失败"
    fi

    for cmd in curl jq tar sha256sum awk sed head wc df mktemp uname grep sleep \
               mkdir mv cp chmod chown rm id; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令: $cmd"
    done

    ok "依赖检查完成"
    ok "当前 Shell: Bash ${BASH_VERSION}"
}

# ============================================================
# Installation lock with stale-lock recovery
# ============================================================
acquire_lock() {
    info "获取安装锁..."
    mkdir -p /run

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local old_pid=""

        if [ -f "$LOCK_DIR/pid" ]; then
            old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        fi

        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            die "另一个安装任务正在运行，PID: $old_pid"
        fi

        warn "发现失效安装锁，正在清理"
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || die "无法获取安装锁，请稍后重试"
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
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7) ARCH="armv7" ;;
        *) die "不支持的 CPU 架构: $machine" ;;
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
    info "准备磁盘临时目录..."

    mkdir -p "$WORK"
    chmod 700 "$WORK"

    TMP="$(mktemp -d "$WORK/sb-install.XXXXXX")"
    chmod 700 "$TMP"

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
    [[ "$kb" =~ ^[0-9]+$ ]] || die "无法读取磁盘剩余空间: $path"

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

    [ "$available" -ge "$required" ] || die "磁盘空间不足: $path"
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
        "$url" -o "$output"
}

fetch_release() {
    info "获取 GitHub 最新稳定版..."

    http_get "$API" "$META" || die "获取 GitHub Release 失败"

    RELEASE="$(jq -er '
        select(.draft == false and .prerelease == false)
        | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | .tag_name
    ' "$META")" || die "无法识别最新稳定版"

    VERSION="${RELEASE#v}"
    ASSET="sing-box-${VERSION}-linux-${ARCH}-musl.tar.gz"

    local count
    count="$(jq --arg name "$ASSET" \
        '[.assets[] | select(.name == $name)] | length' "$META")"

    [ "$count" = "1" ] || die "未找到对应架构的官方安装包: $ASSET"

    URL="$(jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .browser_download_url' "$META")" \
        || die "无法读取下载地址"

    EXPECTED_DIGEST="$(jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .digest' "$META")" \
        || die "GitHub Release 没有提供 SHA256 摘要"

    ASSET_SIZE="$(jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .size' "$META")" \
        || die "无法读取安装包大小"

    local expected_url="https://github.com/${REPO}/releases/download/${RELEASE}/${ASSET}"

    [ "$URL" = "$expected_url" ] || die "下载地址验证失败"
    [[ "$EXPECTED_DIGEST" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || die "官方 SHA256 格式无效"
    [[ "$ASSET_SIZE" =~ ^[0-9]+$ ]] || die "安装包大小无效"
    [ "$ASSET_SIZE" -gt 0 ] || die "安装包大小为零"

    EXPECTED_DIGEST="${EXPECTED_DIGEST#sha256:}"

    info "版本: $VERSION"
    info "安装包: $ASSET"
    info "大小: $((ASSET_SIZE / 1024 / 1024)) MB"
    ok "Release 信息验证通过"
}

# ============================================================
# Download to disk (no whole-archive memory buffering)
# ============================================================
download_release() {
    info "检查下载空间..."
    check_disk_space "$WORK" "$((ASSET_SIZE + DISK_RESERVE))"

    local attempt current_size
    rm -f "$ARCHIVE"

    for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
        info "下载尝试 ${attempt}/${MAX_RETRIES}"

        if curl -fLsS \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$DOWNLOAD_TIMEOUT" \
            --retry 2 \
            --retry-delay 2 \
            --retry-connrefused \
            -H "User-Agent: Alpine-sing-box-Lite-Installer" \
            "$URL" -o "$ARCHIVE"; then

            current_size="$(wc -c < "$ARCHIVE")"
            if [ "$current_size" -eq "$ASSET_SIZE" ]; then
                break
            fi
            warn "下载文件大小不匹配，准备重试"
        else
            warn "下载失败，准备重试"
        fi

        rm -f "$ARCHIVE"
        [ "$attempt" -lt "$MAX_RETRIES" ] && sleep "$((attempt * 2))"
    done

    [ -f "$ARCHIVE" ] || die "下载失败"
    current_size="$(wc -c < "$ARCHIVE")"
    [ "$current_size" -eq "$ASSET_SIZE" ] || die "安装包大小不匹配"

    ok "下载完成"
}

# ============================================================
# SHA256 verification
# ============================================================
verify_archive() {
    info "正在校验 SHA256..."

    local actual
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    [ "${actual,,}" = "${EXPECTED_DIGEST,,}" ] || die "SHA256 校验失败，拒绝安装"

    ok "SHA256 校验通过"
}

# ============================================================
# Single-pass extraction
# ============================================================
extract_binary() {
    info "低内存模式：单次提取 sing-box..."

    ENTRY="sing-box-${VERSION}-linux-${ARCH}-musl/sing-box"

    # 直接将目标成员解压到文件，不先扫描整个归档，也不解压其他文件。
    tar -xzf "$ARCHIVE" -O "$ENTRY" > "$OUT" || die "压缩包提取失败"

    [ -s "$OUT" ] || die "提取的二进制为空"
    chmod 755 "$OUT"

    "$OUT" version >/dev/null 2>&1 || \
        die "二进制无法运行，可能存在架构或 musl 兼容问题"

    local actual_version
    actual_version="$("$OUT" version 2>/dev/null |
        sed -n 's/^sing-box version \([^ ]*\).*/\1/p' |
        head -n 1)"

    [ "$actual_version" = "$VERSION" ] || die "二进制版本验证失败"

    ok "二进制提取及版本验证通过"
}

# ============================================================
# Installation preflight
# ============================================================
install_preflight() {
    local new_size old_size=0 required

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
# Configuration initialization
# ============================================================
initialize_config() {
    info "检查 sing-box 配置..."

    mkdir -p "$CONFIG_DIR"
    chown root:root "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"

    [ ! -L "$CONFIG" ] || die "配置文件是符号链接，拒绝操作"
    if [ -e "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
        die "配置路径存在但不是普通文件"
    fi

    if [ ! -f "$CONFIG" ]; then
        info "创建基础默认配置..."

        CONFIG_TMP="$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")"

        cat > "$CONFIG_TMP" <<'JSON'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
JSON

        chown root:root "$CONFIG_TMP"
        chmod 600 "$CONFIG_TMP"

        "$DEST" check -c "$CONFIG_TMP" || die "默认配置校验失败"

        mv "$CONFIG_TMP" "$CONFIG"
        CONFIG_TMP=""
        CONFIG_CREATED=1
        ok "基础配置创建成功"
    else
        info "检测到已有配置，保留原内容"
    fi

    chown root:root "$CONFIG"
    chmod 600 "$CONFIG"

    "$DEST" check -c "$CONFIG" || die "sing-box 配置校验失败"
    ok "配置校验通过"
}

# ============================================================
# OpenRC service installation (does not enable or start it)
# ============================================================
install_openrc_service() {
    info "检查 OpenRC..."

    if [ ! -x /sbin/openrc-run ]; then
        warn "未检测到 OpenRC，跳过服务文件安装"
        return 0
    fi

    if [ -L "$SERVICE_FILE" ]; then
        die "OpenRC 服务文件是符号链接，拒绝覆盖"
    fi

    if [ -e "$SERVICE_FILE" ]; then
        if grep -Fq "# sing-box OpenRC service managed by 64MB Lite Installer" "$SERVICE_FILE"; then
            info "检测到本脚本管理的 OpenRC 服务，保留现有文件"
            return 0
        fi

        warn "检测到用户已有 $SERVICE_FILE，保留原文件"
        return 0
    fi

    local service_tmp
    service_tmp="$(mktemp /etc/init.d/.sing-box.XXXXXX)"

    cat > "$service_tmp" <<'EOF'
#!/sbin/openrc-run
# sing-box OpenRC service managed by 64MB Lite Installer

description="sing-box proxy service"

command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"

start_pre() {
    if [ ! -x "$command" ]; then
        eerror "sing-box binary not found"
        return 1
    fi

    if [ ! -f /etc/sing-box/config.json ]; then
        eerror "sing-box configuration not found"
        return 1
    fi

    "$command" check -c /etc/sing-box/config.json >/dev/null || {
        eerror "sing-box configuration validation failed"
        return 1
    }
}
EOF

    chmod 755 "$service_tmp"
    chown root:root "$service_tmp"
    mv "$service_tmp" "$SERVICE_FILE" || {
        rm -f "$service_tmp"
        die "OpenRC 服务文件安装失败"
    }

    SERVICE_CREATED=1
    ok "OpenRC 服务文件安装完成"
}

# ============================================================
# Atomic binary installation with rollback
# ============================================================
install_binary() {
    info "开始安装..."

    if [ -e "$DEST" ]; then
        [ -f "$DEST" ] && [ ! -L "$DEST" ] || die "目标路径不是普通文件，拒绝覆盖"

        cp -p "$DEST" "$BACKUP" || die "备份旧版本失败"
        HAD_OLD=1
        ok "旧版本备份完成"
    fi

    cp "$OUT" "$NEW" || die "准备新版本失败"
    chmod 755 "$NEW"

    "$NEW" version >/dev/null 2>&1 || die "安装前二次验证失败"

    # 从替换二进制前开始启用回滚
    ROLLBACK_ACTIVE=1

    mv -f "$NEW" "$DEST" || die "替换 sing-box 二进制失败"
    ok "sing-box 二进制已安装"

    initialize_config
    install_openrc_service

    # 所有安装步骤成功后提交
    ROLLBACK_ACTIVE=0
    rm -f "$BACKUP"

    ok "sing-box 安装、配置检查及服务集成完成"
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
    echo "========== sing-box 3.3 Lite =========="
    echo "脚本版本: $VERSION_SCRIPT"
    echo "sing-box: $VERSION"
    echo "架构:     $ARCH"
    echo "程序:     $DEST"
    echo "配置:     $CONFIG"
    echo "SHA256:   OK"
    echo "配置检查: OK"
    if [ -x /sbin/openrc-run ] && [ -f "$SERVICE_FILE" ]; then
        echo "OpenRC:   $SERVICE_FILE"
        echo "启动:     rc-service sing-box start"
        echo "停止:     rc-service sing-box stop"
        echo "重启:     rc-service sing-box restart"
        echo "状态:     rc-service sing-box status"
        echo "开机自启: rc-update add sing-box default"
    else
        echo "OpenRC:   未安装或未创建服务"
    fi
    echo "======================================"
    echo
    "$DEST" version
    echo
    ok "安装完成。服务不会自动启动，也不会自动设置开机自启。"
}

main "$@"
