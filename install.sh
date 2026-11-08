
#!/usr/bin/env bash

# ============================================================
# sing-box Alpine Linux Installer
# Version: 4.0
#
# Supported:
#   Alpine Linux
#   amd64 / arm64 / armv7
#   musl environment
#   OpenRC
#
# Install:
#   /usr/local/bin/sing-box
#   /etc/sing-box/config.json
#   /etc/init.d/sing-box
#
# Features:
#   - Latest stable release
#   - SHA256 verification
#   - Preserve existing config
#   - OpenRC boot startup
#   - Never start service automatically
# ============================================================

set -Eeuo pipefail

readonly REPO_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="/etc/sing-box/config.json"
readonly SERVICE_FILE="/etc/init.d/sing-box"

WORK_DIR=""
ARCH=""
VERSION=""
DOWNLOAD_URL=""
EXPECTED_SHA256=""
NEW_BINARY=""

# ============================================================
# Logging
# ============================================================

info() {
    printf '[INFO
    ] %s\n' "$*"
}

ok() {
    printf '[ OK
    ] %s\n' "$*"
}

warn() {
    printf '[WARN
    ] %s\n' "$*" >&2
}

die() {
    printf '[ERROR
    ] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${WORK_DIR:-}"
    ] && [ -d "$WORK_DIR"
    ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

# ============================================================
# Environment check
# ============================================================

check_environment() {
    info "检查运行环境..."[
        "$(id -u)" -eq 0
    ] || die "请使用 root 运行"[ -f /etc/alpine-release
    ] || \
        die "此脚本仅支持 Alpine Linux"

    command -v apk >/dev/null 2>&1 || \
        die "未找到 apk 包管理器"

    command -v rc-update >/dev/null 2>&1 || \
        die "未找到 OpenRC rc-update"[ -x /sbin/openrc-run
    ] || \
        die "未找到 /sbin/openrc-run"

    ok "Alpine Linux 检测通过"

    info "检测 CPU 架构..."

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
        *)
            die "暂不支持此 CPU 架构: $(uname -m)"
            ;;
    esac

    ok "CPU 架构: ${ARCH}"
}

# ============================================================
# Dependencies
# ============================================================

install_dependencies() {
    info "安装必要依赖..."

    apk add --no-cache \
        ca-certificates \
        curl \
        jq \
        tar \
        coreutils

    command -v curl >/dev/null 2>&1 || \
        die "curl 安装失败"

    command -v jq >/dev/null 2>&1 || \
        die "jq 安装失败"

    command -v sha256sum >/dev/null 2>&1 || \
        die "sha256sum 不可用"

    command -v install >/dev/null 2>&1 || \
        die "install 命令不可用"

    update-ca-certificates >/dev/null 2>&1 || true

    ok "依赖安装完成"
}

# ============================================================
# Workspace
# ============================================================

prepare_workspace() {
    info "准备临时目录..."

    WORK_DIR="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || \
        die "无法创建临时目录"

    mkdir -p \
        "${WORK_DIR}/extract" \
        "${INSTALL_DIR}" \
        "${CONFIG_DIR}"

    chmod 755 "${INSTALL_DIR}""${CONFIG_DIR}"

    ok "临时目录准备完成"
}

# ============================================================
# Get latest stable release
# ============================================================

get_latest_release() {
    info "获取 sing-box 最新稳定版本..."

    local release_json="${WORK_DIR}/release.json"

    curl -fLsS \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 60 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: Alpine-sing-box-installer" \
        -o "$release_json" \
        "$REPO_API" || \
        die "获取 GitHub Release 失败"

    VERSION="$(jq -er '.tag_name | sub("^v"; "")' \"$release_json")" || \
        die "无法解析版本号"[ -n "$VERSION"
    ] || die "版本号为空"

    local asset_json

    asset_json="$(jq -c \
        --arg prefix "sing-box-${VERSION}-linux-${ARCH}" '
        [
            .assets[]
            | select(.name | startswith($prefix))
            | select(.name | endswith(".tar.gz"))
    ]
        | sort_by(
            if (.name | contains("musl")) then 0 else 1 end
        )
        | .[
        0
    ] // empty
        ' "$release_json")" || \
        die "解析安装包信息失败"[ -n "$asset_json"
    ] || \
        die "没有找到 ${ARCH} 对应的 Linux 安装包"

    DOWNLOAD_URL="$(printf '%s' "$asset_json" | \
        jq -er '.browser_download_url')" || \
        die "无法获取下载地址"

    local digest

    digest="$(printf '%s' "$asset_json" | \
        jq -r '.digest // empty')"

    case "$digest" in
        sha256:*)
            EXPECTED_SHA256="${digest#sha256:}"
            ;;
        *)
            die "Release 没有提供 SHA256 摘要，停止安装"
            ;;
    esac

    [
        [
            "$EXPECTED_SHA256" =~ ^[a-fA-F0-9
            ]{
                64
            }$
        ]
    ] || \
        die "SHA256 摘要格式错误"

    ok "最新稳定版本: ${VERSION}"
    ok "目标架构: ${ARCH}"
    ok "已获取 SHA256 摘要"
}

# ============================================================
# Download package
# ============================================================

download_package() {
    info "下载 sing-box 安装包..."

    local archive="${WORK_DIR}/sing-box.tar.gz"

    curl -fLsS \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 300 \
        -o "$archive" \
        "$DOWNLOAD_URL" || \
        die "安装包下载失败"[ -s "$archive"
    ] || \
        die "下载文件为空"

    ok "下载完成"

    info "验证 SHA256..."

    local actual_sha256

    actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"[
        "${actual_sha256,,}" = "${EXPECTED_SHA256,,}"
    ] || \
        die "SHA256 校验失败，拒绝安装"

    ok "SHA256 校验通过"
}

# ============================================================
# Extract binary
# ============================================================

extract_binary() {
    info "检查并解压安装包..."

    local archive="${WORK_DIR}/sing-box.tar.gz"

    tar -tzf "$archive" >/dev/null 2>&1 || \
        die "安装包损坏"

    tar -xzf "$archive" -C "${WORK_DIR}/extract" || \
        die "解压失败"

    NEW_BINARY="$(find "${WORK_DIR
    }/extract" \
        -type f -name sing-box -print -quit)"[ -n "$NEW_BINARY"
] || \
        die "没有找到 sing-box 二进制文件"[ -x "$NEW_BINARY"
] || \
        chmod 755 "$NEW_BINARY""$NEW_BINARY" version >/dev/null 2>&1 || \
        die "二进制文件无法运行"

    ok "二进制文件检查通过"
}

# ============================================================
# Configuration
# ============================================================

prepare_config() {
    info "检查配置文件..."

    if [ -L "$CONFIG_FILE"
]; then
        die "配置文件是符号链接，为安全起见停止安装"
    fi

    if [ ! -f "$CONFIG_FILE"
]; then

        info "创建默认配置文件..."

        cat > "${WORK_DIR}/config.json" <<'EOF'
{
    "log": {
        "level": "warn"
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

        "$NEW_BINARY" check \
            -c "${WORK_DIR}/config.json" || \
            die "默认配置校验失败"

        install -o root -g root -m 600 \
            "${WORK_DIR}/config.json" \
            "$CONFIG_FILE"

        ok "默认配置文件创建成功"

    else

        info "检测到已有配置，保留原配置...""$NEW_BINARY" check -c "$CONFIG_FILE" || \
            die "现有配置校验失败，请检查配置文件"

        chown root:root "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"

        ok "已有配置保留成功"

    fi

    chown root:root "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
}

# ============================================================
# Install binary
# ============================================================

install_binary() {
    info "安装 sing-box 二进制文件..."

    local new_binary="${INSTALL_DIR}/sing-box.new"

    install -o root -g root -m 755 \
        "$NEW_BINARY""$new_binary"

    mv -f "$new_binary""${INSTALL_DIR}/sing-box""${INSTALL_DIR}/sing-box" version || \
        die "安装后的二进制文件检查失败"

    ok "sing-box 安装完成"
}

# ============================================================
# OpenRC service
# ============================================================

configure_openrc_service() {
    info "创建 OpenRC 服务..."

    cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"

command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"

command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

directory="/etc/sing-box"

start_pre() {
    if [ ! -x "$command"
    ]; then
        eerror "sing-box binary not found: $command"
        return 1
    fi

    if [ ! -f /etc/sing-box/config.json
    ]; then
        eerror "Configuration file not found"
        return 1
    fi

    "$command" check -c /etc/sing-box/config.json
}
EOF

    chmod 755 "$SERVICE_FILE"
    chown root:root "$SERVICE_FILE"

    ok "OpenRC 服务脚本创建完成"

    info "设置开机启动..."

    rc-update add sing-box default || \
        die "设置 OpenRC 开机启动失败"

    ok "开机启动设置完成"
}

# ============================================================
# Final verification
# ============================================================

final_check() {
    info "执行最终检查..."[ -x "${INSTALL_DIR}/sing-box"
] || \
        die "sing-box 二进制文件不存在"[ -f "$CONFIG_FILE"
] || \
        die "配置文件不存在"[ -x "$SERVICE_FILE"
] || \
        die "OpenRC 服务文件不存在""${INSTALL_DIR}/sing-box" check \
        -c "$CONFIG_FILE" || \
        die "最终配置校验失败"

    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    chown root:root "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"

    echo
    echo "========================================"
    echo "       sing-box 安装成功"
    echo "========================================"
    echo
    echo "版本:       ${VERSION}"
    echo "架构:       ${ARCH}"
    echo
    echo "二进制:     ${INSTALL_DIR}/sing-box"
    echo "配置文件:   ${CONFIG_FILE}"
    echo "服务文件:   ${SERVICE_FILE}"
    echo
    echo "配置权限:   600"
    echo "目录权限:   755"
    echo "开机启动:   已设置"
    echo "服务状态:   未启动"
    echo
    echo "手动启动:"
    echo "  rc-service sing-box start"
    echo
    echo "查看状态:"
    echo "  rc-service sing-box status"
    echo
    echo "停止服务:"
    echo "  rc-service sing-box stop"
    echo
    echo "========================================"

    ok "安装流程全部完成，服务没有自动启动"
}

# ============================================================
# Main
# ============================================================

main() {
    echo
    echo "========================================"
    echo "     sing-box Alpine Installer v4.0"
    echo "========================================"
    echo

    check_environment
    install_dependencies
    prepare_workspace
    get_latest_release
    download_package
    extract_binary
    prepare_config
    install_binary
    configure_openrc_service
    final_check
}

main "$@"
