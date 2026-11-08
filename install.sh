#!/usr/bin/env bash
# Alpine 64MB sing-box Lite Installer
# Version: 3.4
# Stream download + SHA256 + BusyBox tar

set -Eeuo pipefail
umask 077

VERSION_SCRIPT="3.4"
REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

DEST="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG="${CONFIG_DIR}/config.json"

WORK="/root/.singbox-install"
LOCK_DIR="/run/sing-box-installer.lock"
LOG="/var/log/sing-box-installer.log"

CONNECT_TIMEOUT=15
DOWNLOAD_TIMEOUT=1800

TMP=""
META=""
DIGEST_FILE=""
NEW=""
BACKUP=""
CONFIG_TMP=""

ARCH=""
RELEASE=""
VERSION=""
ASSET=""
URL=""
EXPECTED_DIGEST=""
ASSET_SIZE=""

LOCKED=0
HAD_OLD=0
ROLLBACK_ACTIVE=0
CONFIG_CREATED=0
SERVICE_CREATED=0

# --------------------------------------------------
# Logging
# --------------------------------------------------

log() {
    local message="$*"
    printf '%s\n' "$message"
    printf '%s\n' "$message" >> "$LOG" 2>/dev/null || true
}

info() {
    log "[INFO] $*"
}

ok() {
    log "[OK]   $*"
}

warn() {
    log "[WARN] $*" >&2
}

err() {
    log "[ERROR] $*" >&2
}

die() {
    err "$*"
    exit 1
}

mkdir -p /var/log
touch "$LOG"
chmod 600 "$LOG"

# --------------------------------------------------
# Exit handling / rollback
# --------------------------------------------------

on_exit() {
    local status=$?

    trap - EXIT INT TERM
    set +e

    if [ "$status" -ne 0 ]; then

        warn "安装未正常完成。"

        if [ "$ROLLBACK_ACTIVE" -eq 1 ]; then

            warn "正在回滚 sing-box 二进制..."

            if [ "$HAD_OLD" -eq 1 ] && [ -f "$BACKUP" ]; then
                mv -f "$BACKUP" "$DEST"
                ok "旧版本已恢复"
            else
                rm -f "$DEST"
                warn "已移除未完成安装的二进制"
            fi
        fi

        if [ "$CONFIG_CREATED" -eq 1 ]; then
            rm -f "$CONFIG"
        fi

        if [ "$SERVICE_CREATED" -eq 1 ]; then
            rm -f /etc/init.d/sing-box
        fi

        [ -n "$NEW" ] && rm -f "$NEW"
        [ -n "$CONFIG_TMP" ] && rm -f "$CONFIG_TMP"

        if [ -n "$TMP" ] && [ -d "$TMP" ]; then
            warn "保留失败现场：$TMP"
        fi

    else
        [ -n "$BACKUP" ] && rm -f "$BACKUP"
        [ -n "$NEW" ] && rm -f "$NEW"
        [ -n "$CONFIG_TMP" ] && rm -f "$CONFIG_TMP"

        [ -n "$TMP" ] && rm -rf "$TMP"

        ok "临时文件已清理"
    fi

    if [ "$LOCKED" -eq 1 ]; then
        rm -rf "$LOCK_DIR"
    fi

    exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------
# Root / Alpine check
# --------------------------------------------------

bootstrap() {
    info "检查系统环境..."

    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

    [ -f /etc/alpine-release ] || \
        die "此脚本仅支持 Alpine Linux"

    command -v apk >/dev/null 2>&1 || \
        die "没有找到 apk"

    command -v bash >/dev/null 2>&1 || \
        die "没有找到 Bash"

    # 只安装真正缺失的依赖
    if ! command -v jq >/dev/null 2>&1; then
        info "安装 jq..."
        apk add --no-cache jq || die "jq 安装失败"
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        info "安装 SHA256 工具..."
        apk add --no-cache coreutils || \
            die "coreutils 安装失败"
    fi

    for cmd in wget tar tee jq sha256sum awk sed find df mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || \
            die "缺少必要命令：$cmd"
    done

    ok "系统环境检查完成"
    info "Shell: Bash ${BASH_VERSION}"

    if tar --version 2>&1 | grep -qi busybox; then
        info "检测到 BusyBox tar"
    else
        info "检测到其他 tar 实现"
    fi
}

# --------------------------------------------------
# Installation lock
# --------------------------------------------------

acquire_lock() {
    info "检查安装锁..."

    mkdir -p /run

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then

        local old_pid=""

        [ -f "$LOCK_DIR/pid" ] && \
            old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"

        if [[ "$old_pid" =~ ^[0-9]+$ ]] && \
           kill -0 "$old_pid" 2>/dev/null; then
            die "另一个安装任务正在运行，PID: $old_pid"
        fi

        warn "发现过期安装锁，清理中..."

        rm -rf "$LOCK_DIR"

        mkdir "$LOCK_DIR" || \
            die "无法创建安装锁"
    fi

    LOCKED=1

    printf '%s\n' "$$" > "$LOCK_DIR/pid"

    ok "安装锁已获取"
}

# --------------------------------------------------
# Architecture
# --------------------------------------------------

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
            die "不支持的 CPU 架构：$machine"
            ;;
    esac

    info "CPU 架构：$ARCH"
    info "系统类型：Alpine Linux / musl"

    ok "架构识别完成"
}

# --------------------------------------------------
# Workspace
# --------------------------------------------------

prepare_workspace() {
    info "准备磁盘临时目录..."

    mkdir -p "$WORK"
    chmod 700 "$WORK"

    # 清理之前被 OOM 杀死留下的目录
    local stale_dir
    local stale_pid

    for stale_dir in "$WORK"/sb-install.*; do

        [ -d "$stale_dir" ] || continue

        stale_pid=""

        if [ -s "$stale_dir/.active" ]; then
            stale_pid="$(cat "$stale_dir/.active" 2>/dev/null || true)"
        fi

        if [[ "$stale_pid" =~ ^[0-9]+$ ]] && \
           kill -0 "$stale_pid" 2>/dev/null; then
            continue
        fi

        warn "清理上次残留目录：$stale_dir"
        rm -rf "$stale_dir"
    done

    TMP="$(mktemp -d "$WORK/sb-install.XXXXXX")" || \
        die "无法创建临时目录"

    printf '%s\n' "$$" > "$TMP/.active"

    META="$TMP/release.json"
    DIGEST_FILE="$TMP/archive.sha256"

    mkdir -p "$(dirname "$DEST")"
    mkdir -p "$CONFIG_DIR"

    NEW="$(dirname "$DEST")/.sing-box.new.$$"
    BACKUP="$(dirname "$DEST")/.sing-box.backup.$$"

    ok "临时目录：$TMP"
}

# --------------------------------------------------
# Disk space
# --------------------------------------------------

check_disk_space() {
    local available_kb

    available_kb="$(df -Pk "$WORK" | awk 'END {print $4}')"

    [[ "$available_kb" =~ ^[0-9]+$ ]] || \
        die "无法检测磁盘空间"

    info "磁盘剩余空间：$((available_kb / 1024)) MB"

    # 解压后的二进制远大于压缩包
    [ "$available_kb" -ge 131072 ] || \
        die "磁盘剩余空间不足，至少建议 128MB"
}

# --------------------------------------------------
# GitHub Release API
# --------------------------------------------------

fetch_release() {
    info "获取 sing-box 官方 Release..."

    wget -qO "$META" "$API" || \
        die "GitHub API 请求失败"

    RELEASE="$(
        jq -er '
            select(.draft == false and .prerelease == false)
            | .tag_name
            | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        ' "$META"
    )" || die "无法识别稳定版 Release"

    VERSION="${RELEASE#v}"

    ASSET="sing-box-${VERSION}-linux-${ARCH}-musl.tar.gz"

    local count

    count="$(
        jq --arg name "$ASSET" \
        '[.assets[] | select(.name == $name)] | length' \
        "$META"
    )"

    [ "$count" = "1" ] || \
        die "没有找到官方安装包：$ASSET"

    URL="$(
        jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "$META"
    )" || die "无法读取下载地址"

    EXPECTED_DIGEST="$(
        jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .digest' \
        "$META"
    )" || die "官方 Release 没有提供 SHA256"

    ASSET_SIZE="$(
        jq -er --arg name "$ASSET" \
        '.assets[] | select(.name == $name) | .size' \
        "$META"
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

    info "Release：$RELEASE"
    info "安装包：$ASSET"
    info "压缩包大小：$((ASSET_SIZE / 1024 / 1024)) MB"

    ok "官方 Release 信息验证通过"
}

# --------------------------------------------------
# Streaming download + SHA256 + extraction
# --------------------------------------------------

stream_download_extract() {
    info "开始流式下载 sing-box..."
    info "不保存完整 tar.gz 文件"
    info "下载、SHA256 和解压同步进行"

    rm -f "$DIGEST_FILE"

    # 创建 SHA256 子进程
    # FD 3 接收 tee 输出的数据
    exec 3> >(sha256sum > "$DIGEST_FILE")

    local hash_pid=$!

    local -a pipeline_status
    local hash_status

    # 这里不使用 set -e，手动检查每个管道状态
    set +e

    wget -qO- "$URL" \
        | tee /dev/fd/3 \
        | tar -xzf - -C "$TMP"

    pipeline_status=( "${PIPESTATUS[@]}" )

    set -e

    # 关闭 FD，让 SHA256 进程收到 EOF
    exec 3>&-

    wait "$hash_pid"
    hash_status=$?

    if [ "${pipeline_status[0]:-1}" -ne 0 ]; then
        die "wget 下载失败"
    fi

    if [ "${pipeline_status[1]:-1}" -ne 0 ]; then
        die "tee 数据转发失败"
    fi

    if [ "${pipeline_status[2]:-1}" -ne 0 ]; then
        die "tar 解压失败"
    fi

    [ "$hash_status" -eq 0 ] || \
        die "SHA256 计算进程失败"

    [ -s "$DIGEST_FILE" ] || \
        die "SHA256 结果文件为空"

    local actual_digest

    actual_digest="$(
        awk '{print $1}' "$DIGEST_FILE"
    )"

    actual_digest="$(printf '%s' "$actual_digest" | tr 'A-F' 'a-f')"

    EXPECTED_DIGEST="$(printf '%s' "$EXPECTED_DIGEST" | tr 'A-F' 'a-f')"

    info "正在校验 SHA256..."

    [ "$actual_digest" = "$EXPECTED_DIGEST" ] || \
        die "SHA256 校验失败，拒绝安装"

    ok "SHA256 校验通过"
    ok "流式下载和解压完成"
}

# --------------------------------------------------
# Find extracted binary
# --------------------------------------------------

find_binary() {
    info "查找 sing-box 二进制..."

    local extracted

    extracted="$(
        find "$TMP" -type f -name sing-box | sed -n '1p'
    )"

    [ -n "$extracted" ] || \
        die "解压后没有找到 sing-box 文件"

    [ -f "$extracted" ] || \
        die "sing-box 文件不存在"

    chmod 755 "$extracted"

    ok "找到 sing-box 二进制"

    printf '%s\n' "$extracted"
}

# --------------------------------------------------
# Stage and verify binary
# --------------------------------------------------

stage_binary() {
    local extracted="$1"

    info "准备安装新版本..."

    mv "$extracted" "$NEW" || \
        die "无法移动新二进制文件"

    chmod 755 "$NEW"

    info "检查二进制能否运行..."

    "$NEW" version >/dev/null 2>&1 || \
        die "新下载的 sing-box 无法运行"

    local actual_version

    actual_version="$(
        "$NEW" version 2>&1 \
        | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' \
        | sed -n '1p'
    )"

    [ "$actual_version" = "$VERSION" ] || \
        die "版本不匹配：期望 $VERSION，实际 ${actual_version:-未知}"

    ok "二进制版本验证通过：$actual_version"
}

# --------------------------------------------------
# Default configuration
# --------------------------------------------------

prepare_config() {
    if [ -s "$CONFIG" ]; then
        info "发现已有配置，不覆盖"
        return 0
    fi

    info "创建默认配置..."

    CONFIG_TMP="${CONFIG_DIR}/.config.json.new.$$"

    cat > "$CONFIG_TMP" <<'EOF'
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
  ]
}
EOF

    chmod 600 "$CONFIG_TMP"

    mv "$CONFIG_TMP" "$CONFIG" || \
        die "无法创建配置文件"

    CONFIG_CREATED=1

    ok "默认配置创建完成"
}

# --------------------------------------------------
# Install binary with rollback
# --------------------------------------------------

install_binary() {
    info "准备替换正式二进制..."

    if [ -f "$DEST" ]; then
        mv "$DEST" "$BACKUP" || \
            die "无法备份旧版本"

        HAD_OLD=1
    fi

    ROLLBACK_ACTIVE=1

    mv "$NEW" "$DEST" || \
        die "无法安装新版本"

    chmod 755 "$DEST"

    ok "sing-box 二进制安装完成"
}

# --------------------------------------------------
# Validate configuration
# --------------------------------------------------

validate_config() {
    info "检查 sing-box 配置..."

    "$DEST" check -c "$CONFIG" || \
        die "配置检查失败，安装将回滚"

    ok "配置检查通过"
}

# --------------------------------------------------
# OpenRC service
# --------------------------------------------------

install_openrc_service() {
    if [ ! -x /sbin/openrc-run ]; then
        info "没有检测到 OpenRC，跳过服务文件创建"
        return 0
    fi

    local service="/etc/init.d/sing-box"

    if [ -f "$service" ]; then
        info "已有 OpenRC 服务文件，不覆盖"
        return 0
    fi

    info "创建 OpenRC 服务文件..."

    cat > "$service" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"

command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"

command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF

    chmod 755 "$service"

    SERVICE_CREATED=1

    ok "OpenRC 服务文件创建完成"
    info "没有自动启用或启动服务"
}

# --------------------------------------------------
# Main
# --------------------------------------------------

main() {
    info "======================================"
    info " Alpine 64MB sing-box Lite Installer"
    info " Version: ${VERSION_SCRIPT}"
    info "======================================"

    bootstrap
    acquire_lock
    detect_arch
    prepare_workspace
    check_disk_space
    fetch_release
    stream_download_extract

    local extracted

    extracted="$(find_binary)"

    stage_binary "$extracted"
    prepare_config
    install_binary
    validate_config
    install_openrc_service

    ROLLBACK_ACTIVE=0

    [ "$HAD_OLD" -eq 1 ] && rm -f "$BACKUP"

    info "======================================"
    ok "sing-box 安装成功"
    info "版本：${VERSION}"
    info "二进制：${DEST}"
    info "配置：${CONFIG}"
    info "日志：${LOG}"
    info "======================================"

    info "服务尚未启动。"
    info "如需启动 OpenRC 服务：rc-service sing-box start"
}

main "$@"
