#!/usr/bin/env bash
# Alpine Linux 64MB sing-box Installer
# Version: 5.0

set -Eeuo pipefail
umask 077

VERSION_SCRIPT="5.0"
REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

INSTALL_DIR="/usr/local/bin"
DEST="${INSTALL_DIR}/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG="${CONFIG_DIR}/config.json"
SERVICE="/etc/init.d/sing-box"

WORK_BASE="/var/tmp"
WORK=""
ARCHIVE=""
RELEASE_JSON=""
CANDIDATE=""
NEW_BINARY=""
SERVICE_TMP=""

VERSION=""
ARCH=""
ASSET=""
URL=""
DIGEST=""
ASSET_SIZE=""

log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    [ -n "${NEW_BINARY:-}" ] && rm -f "$NEW_BINARY"
    [ -n "${SERVICE_TMP:-}" ] && rm -f "$SERVICE_TMP"
    exit "$status"
}
trap cleanup EXIT

check_environment() {
    log "检查运行环境..."

    [ "$(id -u)" = "0" ] || die "请使用 root 运行"
    [ -f /etc/alpine-release ] || die "此脚本仅支持 Alpine Linux"
    command -v apk >/dev/null 2>&1 || die "找不到 apk"

    log "检查必要依赖..."

    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)

    if [ "${#missing[@]}" -gt 0 ]; then
        log "安装依赖: ${missing[*]}"
        apk add --no-cache "${missing[@]}" || die "依赖安装失败"
    fi

    local cmd
    for cmd in tar sha256sum awk grep df mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
    done

    ok "运行环境检查通过"
}

detect_arch() {
    log "检测 CPU 架构..."

    case "$(uname -m)" in
        aarch64|arm64)
            ARCH="arm64"
            ;;
        x86_64|amd64)
            ARCH="amd64"
            ;;
        *)
            die "不支持的 CPU 架构: $(uname -m)"
            ;;
    esac

    ok "CPU 架构: $ARCH"
}

prepare_workspace() {
    log "准备临时目录..."

    mkdir -p "$WORK_BASE"
    WORK="$(mktemp -d "${WORK_BASE}/sing-box.XXXXXX")"
    chmod 700 "$WORK"

    ARCHIVE="${WORK}/sing-box.tar.gz"
    RELEASE_JSON="${WORK}/release.json"

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    ok "临时目录准备完成"
}

check_disk_space() {
    local available_kb
    available_kb="$(df -Pk "$WORK" | awk 'END {print $4}')"

    [[ "$available_kb" =~ ^[0-9]+$ ]] || die "无法读取剩余磁盘空间"

    local required_kb=$((ASSET_SIZE * 3 / 1024 + 10240))

    log "检查磁盘空间..."
    log "可用空间: $((available_kb / 1024)) MB"
    log "预计需要: $((required_kb / 1024)) MB"

    [ "$available_kb" -ge "$required_kb" ] || die "磁盘空间不足"
}

fetch_release() {
    log "获取 sing-box 最新稳定版本..."

    curl -fLsS \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 3 \
        --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: Alpine-sing-box-Installer" \
        "$API" -o "$RELEASE_JSON" || die "获取 GitHub Release 失败"

    VERSION="$(jq -er '
        select(.draft == false and .prerelease == false)
        | .tag_name
        | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | ltrimstr("v")
    ' "$RELEASE_JSON")" || die "无法识别稳定版本"

    local prefix
    prefix="sing-box-${VERSION}-linux-${ARCH}"

    ASSET="$(jq -er --arg prefix "$prefix" '
        [
            .assets[]
            | select(.name | test("^" + $prefix + "(-musl)?\\.tar\\.gz$"))
        ]
        | sort_by(if (.name | endswith("-musl.tar.gz")) then 0 else 1 end)
        | .[0].name
    ' "$RELEASE_JSON")" || die "没有找到对应架构的官方安装包"

    URL="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .browser_download_url
    ' "$RELEASE_JSON")" || die "无法读取下载地址"

    DIGEST="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .digest
    ' "$RELEASE_JSON")" || die "GitHub 没有提供官方 SHA256 摘要"

    ASSET_SIZE="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .size
    ' "$RELEASE_JSON")" || die "无法读取安装包大小"

    case "$URL" in
        https://github.com/SagerNet/sing-box/releases/download/*)
            ;;
        *)
            die "下载地址不是官方 Release 地址"
            ;;
    esac

    DIGEST="${DIGEST#sha256:}"

    [ "${#DIGEST}" -eq 64 ] || die "SHA256 长度不正确"

    case "$DIGEST" in
        *[!0-9a-fA-F]*|'')
            die "SHA256 格式不正确"
            ;;
    esac

    [[ "$ASSET_SIZE" =~ ^[0-9]+$ ]] || die "安装包大小格式错误"
    [ "$ASSET_SIZE" -gt 0 ] || die "安装包大小为零"

    ok "最新稳定版本: $VERSION"
    ok "目标架构: $ARCH"
    ok "安装包: $ASSET"
    ok "已获取 SHA256 摘要"

    check_disk_space
}

download_release() {
    log "下载 sing-box 安装包..."

    curl -fLsS \
        --connect-timeout 20 \
        --max-time 1800 \
        --retry 3 \
        --retry-delay 3 \
        --retry-all-errors \
        -H "User-Agent: Alpine-sing-box-Installer" \
        "$URL" -o "$ARCHIVE" || die "下载失败"

    local actual_size
    actual_size="$(wc -c < "$ARCHIVE")"

    [ "$actual_size" -eq "$ASSET_SIZE" ] || die "下载文件大小不匹配"

    ok "下载完成"
}

verify_archive() {
    log "验证 SHA256..."

    local actual
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    [ "${actual,,}" = "${DIGEST,,}" ] || die "SHA256 校验失败"

    ok "SHA256 校验通过"
}

extract_binary() {
    log "检查并提取安装包..."

    local top_dir
    local entry

    top_dir="${ASSET%.tar.gz}"
    entry="${top_dir}/sing-box"

    tar -tzf "$ARCHIVE" > "${WORK}/archive.list" || die "压缩包损坏"

    grep -Fxq "$entry" "${WORK}/archive.list" || die "安装包中找不到 sing-box"

    CANDIDATE="${WORK}/sing-box"
    tar -xOzf "$ARCHIVE" "$entry" > "$CANDIDATE" || die "提取二进制失败"

    [ -s "$CANDIDATE" ] || die "提取出的二进制为空"
    chmod 755 "$CANDIDATE"

    ok "二进制文件提取完成"
}

verify_binary() {
    log "验证新二进制文件..."

    local version_output

    version_output="$("$CANDIDATE" version 2>&1)" || {
        warn "$version_output"
        die "新二进制无法运行，拒绝安装"
    }

    case "$version_output" in
        *"$VERSION"*)
            ;;
        *)
            die "二进制版本与 Release 版本不一致"
            ;;
    esac

    ok "二进制运行正常"
    log "$version_output"
}

prepare_config() {
    log "检查配置文件..."

    if [ -L "$CONFIG" ]; then
        die "配置文件是符号链接，拒绝覆盖"
    fi

    if [ -e "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
        die "配置路径不是普通文件"
    fi

    if [ ! -f "$CONFIG" ]; then
        log "创建默认配置文件..."

        local config_tmp
        config_tmp="$(mktemp "${CONFIG_DIR}/.config.XXXXXX")"

        cat > "$config_tmp" <<'JSON'
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
JSON

        chown root:root "$config_tmp"
        chmod 600 "$config_tmp"

        "$CANDIDATE" check -c "$config_tmp" || {
            rm -f "$config_tmp"
            die "默认配置检查失败"
        }

        mv -f "$config_tmp" "$CONFIG"
        ok "默认配置文件创建成功"
    else
        log "发现已有配置，保留原配置"
        "$CANDIDATE" check -c "$CONFIG" || die "现有配置无法通过新版本检查"
    fi

    chown root:root "$CONFIG_DIR" "$CONFIG"
    chmod 755 "$CONFIG_DIR"
    chmod 600 "$CONFIG"

    ok "配置文件检查通过"
}

install_binary() {
    log "安装 sing-box 二进制文件..."

    NEW_BINARY="${INSTALL_DIR}/.sing-box.new.$$"

    cp "$CANDIDATE" "$NEW_BINARY"
    chown root:root "$NEW_BINARY"
    chmod 755 "$NEW_BINARY"

    "$NEW_BINARY" version >/dev/null 2>&1 || die "安装前二次运行检查失败"

    mv -f "$NEW_BINARY" "$DEST"
    NEW_BINARY=""

    chown root:root "$DEST"
    chmod 755 "$DEST"

    ok "sing-box 二进制安装完成"
}

create_service() {
    log "创建 OpenRC 服务..."

    command -v rc-update >/dev/null 2>&1 || {
        log "安装 OpenRC..."
        apk add --no-cache openrc || die "OpenRC 安装失败"
    }

    [ -x /sbin/openrc-run ] || die "找不到 /sbin/openrc-run"

    SERVICE_TMP="/etc/init.d/.sing-box.$$"

    cat > "$SERVICE_TMP" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"

command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
directory="/etc/sing-box"

start_pre() {
    [ -x "$command" ] || {
        eerror "sing-box binary not found"
        return 1
    }

    [ -f /etc/sing-box/config.json ] || {
        eerror "config.json not found"
        return 1
    }

    "$command" check -c /etc/sing-box/config.json
}
EOF

    chown root:root "$SERVICE_TMP"
    chmod 755 "$SERVICE_TMP"
    mv -f "$SERVICE_TMP" "$SERVICE"
    SERVICE_TMP=""

    ok "OpenRC 服务文件创建完成"

    rc-update add sing-box default || die "设置开机启动失败"

    ok "已设置 default 开机启动"
}

main() {
    echo "========================================"
    echo "     sing-box Alpine Installer v${VERSION_SCRIPT}"
    echo "========================================"

    check_environment
    detect_arch
    prepare_workspace
    fetch_release
    download_release
    verify_archive
    extract_binary
    verify_binary
    prepare_config
    install_binary
    create_service

    echo "========================================"
    echo "安装完成"
    echo "sing-box 版本: ${VERSION}"
    echo "CPU 架构: ${ARCH}"
    echo "二进制: ${DEST}"
    echo "配置文件: ${CONFIG}"
    echo "服务文件: ${SERVICE}"
    echo "配置权限: 600"
    echo "开机启动: 已设置"
    echo "自动启动: 未执行"
    echo "========================================"

    ok "安装成功，没有启动 sing-box"
}

main "$@"
