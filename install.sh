
#!/usr/bin/env bash

# ============================================================
# sing-box Alpine Linux Installer
# Version: 4.0
# Platform: Alpine Linux / musl
# Architectures: amd64 / arm64 / armv7
# Service: OpenRC
#
# Install path: /usr/local/bin/sing-box
# Config path:  /etc/sing-box/config.json
# Service path: /etc/init.d/sing-box
#
# IMPORTANT:
# - Stable release only
# - SHA256 verification required
# - Existing config will not be overwritten
# - Enable OpenRC startup
# - DO NOT start service automatically
# ============================================================

set -Eeuo pipefail

readonly REPO_API="https://api.github.com/repos/SagerNet/sing-box"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly SERVICE_FILE="/etc/init.d/sing-box"

WORK_DIR=""
ARCH=""
VERSION=""
DOWNLOAD_URL=""
EXPECTED_SHA256=""

# ============================================================
# Logging
# ============================================================

info() {
    printf '\033[
        36m[INFO
        ]\033[
            0m %s\n' "$*"
        }

ok() {
    printf '\033[
                32m[ OK
                ]\033[
                    0m %s\n' "$*"
                }

warn() {
    printf '\033[
                        33m[WARN
                        ]\033[
                            0m %s\n' "$*" >&2
                        }

die() {
    printf '\033[
                                31m[ERROR
                                ]\033[
                                    0m %s\n' "$*" >&2
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
# Environment checks
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

    ok "Alpine Linux 环境检测通过"

    info "检查 CPU 架构..."

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
            die "不支持的 CPU 架构: $(uname -m)"
            ;;
    esac

    ok "CPU 架构: ${ARCH}"
                                }

# ============================================================
# Install dependencies
# ============================================================

install_dependencies() {
    info "安装必要依赖..."

    apk add --no-cache \
        ca-certificates \
        wget \
        tar \
        jq \
        coreutils

    update-ca-certificates >/dev/null 2>&1 || true

    command -v wget >/dev/null 2>&1 || \
        die "wget 安装失败"

    command -v jq >/dev/null 2>&1 || \
        die "jq 安装失败"

    command -v sha256sum >/dev/null 2>&1 || \
        die "sha256sum 不可用"

    ok "依赖安装完成"
                                }

# ============================================================
# Prepare temporary directory
# ============================================================

prepare_workspace() {
    WORK_DIR="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || \
        die "无法创建临时目录"

    mkdir -p \
        "${WORK_DIR}/extract" \
        "${INSTALL_DIR}" \
        "${CONFIG_DIR}"

    chmod 755 "${INSTALL_DIR}""${CONFIG_DIR}"
                                }

# ============================================================
# Get latest stable release
# ============================================================

get_latest_release() {
    info "获取 sing-box 最新稳定版..."

    local release_json="${WORK_DIR}/release.json"

    wget -q \
        --timeout=20 \
        --tries=3 \
        --header="Accept: application/vnd.github+json" \
        --header="X-GitHub-Api-Version: 2022-11-28" \
        -O "$release_json" \
        "${REPO_API}/releases/latest" || \
        die "获取 GitHub Release 信息失败"

    VERSION="$(jq -er '.tag_name | sub("^v"; "")' \"$release_json")" || \
        die "无法解析 sing-box 版本号"[ -n "$VERSION"
                                    ] || die "版本号为空"

    # 选择对应架构的 Linux tar.gz 文件。
    # 如果存在 musl 后缀版本，优先选择 musl 版本。

    local asset_json

    asset_json="$(jq -cer \
        --arg version "$VERSION" \
        --arg arch "$ARCH" '
        [
            .assets[]
            | select(
                (.name | startswith(
                    "sing-box-" + $version + "-linux-" + $arch
                ))
                and
                (.name | endswith(".tar.gz"))
            )
                                    ]
        | sort_by(
            if (.name | contains("musl")) then 0 else 1 end
        )
        | .[
                                        0
                                    ] // empty
        ' "$release_json")" || \
        die "没有找到对应架构的官方安装包"

    DOWNLOAD_URL="$(printf '%s' "$asset_json" | jq -er '.browser_download_url')" || \
        die "无法获取安装包下载地址"

    local digest

    digest="$(printf '%s' "$asset_json" | jq -r '.digest // empty')"

    case "$digest" in
        sha256:*)
            EXPECTED_SHA256="${digest#sha256:}"
            ;;
        *)
            die "GitHub Release 未提供有效 SHA256 摘要，停止安装"
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

    ok "最新稳定版: ${VERSION}"
    ok "目标架构: ${ARCH}"
                                }

# ============================================================
# Download package
# ============================================================

download_package() {
    info "下载 sing-box..."

    local archive="${WORK_DIR}/sing-box.tar.gz"

    wget \
        --timeout=30 \
        --tries=3 \
        --retry-connrefused \
        -O "$archive" \
        "$DOWNLOAD_URL" || \
        die "安装包下载失败"[ -s "$archive"
                                    ] || die "下载文件为空"

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
# Extract and verify binary
# ============================================================

extract_binary() {
    info "解压安装包..."

    local archive="${WORK_DIR}/sing-box.tar.gz"

    tar -tzf "$archive" >/dev/null 2>&1 || \
        die "安装包损坏或不是有效的 gzip tar 文件"

    tar -xzf "$archive" -C "${WORK_DIR}/extract" || \
        die "安装包解压失败"

    local binary

    binary="$(find "${WORK_DIR
                                    }/extract" \
        -type f -name sing-box -print -quit)"[ -n "$binary"
                                    ] && [ -x "$binary"
                                    ] || \
        die "安装包中没有找到可执行的 sing-box""$binary" version >/dev/null 2>&1 || \
        die "sing-box 二进制文件无法运行"

    ok "二进制文件检查通过"

    NEW_BINARY="$binary"
                                }

# ============================================================
# Prepare configuration
# ============================================================

prepare_config() {
    info "检查 sing-box 配置..."

    local default_config="${WORK_DIR}/config.json"

    if [ ! -f "$CONFIG_FILE"
                                    ]; then

        cat > "$default_config" <<'EOF'
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
                                        ],
                                        "route": {
                                            "final": "direct"
                                        }
                                    }
EOF

        chmod 600 "$default_config""$NEW_BINARY" check -c "$default_config" || \
            die "默认配置文件校验失败"

        install -o root -g root -m 600 \
            "$default_config""$CONFIG_FILE"

        ok "默认配置文件创建成功"

    else

        "$NEW_BINARY" check -c "$CONFIG_FILE" || \
            die "现有配置文件校验失败，请先检查配置"

        chmod 600 "$CONFIG_FILE"
        chown root:root "$CONFIG_FILE"

        ok "保留现有配置文件"

    fi

    chown root:root "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
                                }

# ============================================================
# Install binary
# ============================================================

install_binary() {
    info "安装 sing-box..."

    local new_binary="${INSTALL_DIR}/sing-box.new"

    install -o root -g root -m 755 \
        "$NEW_BINARY""$new_binary"

    mv -f "$new_binary""${INSTALL_DIR}/sing-box""${INSTALL_DIR}/sing-box" version || \
        die "安装后的 sing-box 无法运行"

    ok "sing-box 安装完成"
                                }

# ============================================================
# Configure OpenRC service
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

    ok "OpenRC 服务脚本创建成功"

    info "设置 OpenRC 开机启动..."

    rc-update add sing-box default || \
        die "设置 OpenRC 开机启动失败"

    ok "已设置开机启动"
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
        die "OpenRC 服务脚本不存在""${INSTALL_DIR}/sing-box" check -c "$CONFIG_FILE" || \
        die "最终配置检查失败"

    echo
    echo "========================================"
    echo "         sing-box 安装完成"
    echo "========================================"
    echo
    echo "版本:       ${VERSION}"
    echo "架构:       ${ARCH}"
    echo "二进制:     ${INSTALL_DIR}/sing-box"
    echo "配置文件:   ${CONFIG_FILE}"
    echo "服务文件:   ${SERVICE_FILE}"
    echo
    echo "配置权限:   600"
    echo "目录权限:   755"
    echo "开机启动:   已设置"
    echo "当前状态:   未启动"
    echo
    echo "手动启动:"
    echo "  rc-service sing-box start"
    echo
    echo "查看状态:"
    echo "  rc-service sing-box status"
    echo
    echo "查看日志:"
    echo "  tail -f /var/log/messages"
    echo
    echo "========================================"
    echo
    ok "安装成功！服务没有自动启动。"
                                }

# ============================================================
# Main
# ============================================================

main() {
    echo
    echo "========================================"
    echo "       sing-box Alpine Installer"
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
