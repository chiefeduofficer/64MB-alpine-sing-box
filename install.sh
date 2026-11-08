#!/bin/bash
# sing-box Alpine 64MB Installer v5.1

set -Eeuo pipefail
umask 077

VERSION_SCRIPT="5.1"
REPO="SagerNet/sing-box"
API="https://api.github.com/repos/${REPO}/releases/latest"

INSTALL_DIR="/usr/local/bin"
DEST="${INSTALL_DIR}/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG="${CONFIG_DIR}/config.json"
SERVICE="/etc/init.d/sing-box"

WORK=""
CANDIDATE=""
NEW_BINARY=""

log()  { echo "[INFO] $*"; }
ok()   { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

cleanup() {
    local rc=$?
    if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
    if [ -n "${NEW_BINARY:-}" ]; then
        rm -f "$NEW_BINARY"
    fi
    exit "$rc"
}
trap cleanup EXIT

check_environment() {
    log "检查运行环境..."

    [ "$(id -u)" = "0" ] || die "请使用 root 运行"
    [ -f /etc/alpine-release ] || die "仅支持 Alpine Linux"

    for cmd in wget jq sha256sum tar awk grep wc df mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令 $cmd，请先单独安装该依赖"
    done

    [ -d /sys/fs/cgroup ] || warn "未检测到 cgroup 目录"

    if [ -r /sys/fs/cgroup/memory.max ]; then
        log "内存限制: $(cat /sys/fs/cgroup/memory.max) bytes"
    fi

    if [ -r /sys/fs/cgroup/memory.current ]; then
        log "当前内存使用: $(cat /sys/fs/cgroup/memory.current) bytes"
    fi

    ok "环境检查通过，不安装额外依赖"
}

detect_arch() {
    case "$(uname -m)" in
        aarch64|arm64) ARCH="arm64" ;;
        x86_64|amd64) ARCH="amd64" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac

    ok "CPU 架构: $ARCH"
}

prepare_workspace() {
    mkdir -p /var/tmp
    WORK="$(mktemp -d /var/tmp/sing-box.XXXXXX)"
    chmod 700 "$WORK"

    ARCHIVE="${WORK}/release.tar.gz"
    RELEASE_JSON="${WORK}/release.json"
    CANDIDATE="${WORK}/sing-box"

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    [ ! -L "$CONFIG_DIR" ] || die "配置目录是符号链接，拒绝继续"
    [ ! -L "$DEST" ] || die "正式二进制是符号链接，拒绝继续"
}

get_release() {
    log "获取官方稳定版本..."

    wget -qO "$RELEASE_JSON" \
        --timeout=30 \
        --tries=3 \
        --user-agent="Alpine-sing-box-Installer" \
        "$API" || die "获取 GitHub Release 失败"

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
    ' "$RELEASE_JSON")" || die "没有找到对应架构的安装包"

    URL="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .browser_download_url
    ' "$RELEASE_JSON")" || die "无法读取下载地址"

    DIGEST="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .digest
    ' "$RELEASE_JSON")" || die "官方 Release 未提供 SHA256，停止安装"

    ASSET_SIZE="$(jq -er --arg name "$ASSET" '
        .assets[]
        | select(.name == $name)
        | .size
    ' "$RELEASE_JSON")" || die "无法读取安装包大小"

    case "$URL" in
        https://github.com/SagerNet/sing-box/releases/download/*) ;;
        *) die "下载地址不是官方 Release 地址" ;;
    esac

    DIGEST="${DIGEST#sha256:}"

    [ "${#DIGEST}" -eq 64 ] || die "SHA256 长度错误"

    case "$DIGEST" in
        *[!0-9a-fA-F]*|'') die "SHA256 格式错误" ;;
    esac

    case "$ASSET_SIZE" in
        ''|*[!0-9]*) die "安装包大小格式错误" ;;
    esac

    ok "稳定版本: $VERSION"
    ok "安装包: $ASSET"
}

check_disk() {
    local free_kb
    free_kb="$(df -Pk /var/tmp | awk 'END {print $4}')"

    case "$free_kb" in
        ''|*[!0-9]*) die "无法检查磁盘空间" ;;
    esac

    local need_kb=$((ASSET_SIZE / 1024 * 3 + 8192))

    log "临时目录可用空间: $((free_kb / 1024)) MB"

    [ "$free_kb" -ge "$need_kb" ] || die "磁盘空间不足"
}

download_release() {
    log "下载官方安装包..."

    wget -qO "$ARCHIVE" \
        --timeout=60 \
        --tries=3 \
        "$URL" || die "下载失败"

    local actual_size
    actual_size="$(wc -c < "$ARCHIVE")"

    [ "$actual_size" -eq "$ASSET_SIZE" ] || die "下载文件大小不匹配"

    ok "下载完成"
}

verify_sha256() {
    log "验证 SHA256..."

    local actual
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    [ "${actual,,}" = "${DIGEST,,}" ] || die "SHA256 校验失败"

    ok "SHA256 校验通过"
}

extract_binary() {
    log "提取二进制文件..."

    local top_dir
    top_dir="${ASSET%.tar.gz}"

    tar -tzf "$ARCHIVE" > "${WORK}/files.txt" || die "压缩包损坏"

    grep -Fxq "${top_dir}/sing-box" "${WORK}/files.txt" \
        || die "压缩包中找不到 sing-box"

    tar -xOzf "$ARCHIVE" "${top_dir}/sing-box" > "$CANDIDATE" \
        || die "提取二进制失败"

    [ -s "$CANDIDATE" ] || die "提取出的文件为空"
    chmod 755 "$CANDIDATE"

    ok "二进制提取完成"
}

verify_binary() {
    log "验证新二进制..."

    local output
    if ! output="$("$CANDIDATE" version 2>&1)"; then
        warn "$output"
        die "新二进制执行失败，拒绝安装"
    fi

    case "$output" in
        *"$VERSION"*) ;;
        *) die "二进制版本与 Release 版本不一致" ;;
    esac

    ok "二进制执行正常"
    echo "$output"
}

prepare_config() {
    log "检查配置文件..."

    [ ! -L "$CONFIG" ] || die "配置文件是符号链接，拒绝覆盖"

    if [ ! -e "$CONFIG" ]; then
        log "创建默认配置..."

        local config_tmp
        config_tmp="${WORK}/config.json"

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

        "$CANDIDATE" check -c "$config_tmp" \
            || die "默认配置检查失败"

        install -o root -g root -m 600 "$config_tmp" "$CONFIG"
        ok "默认配置创建成功"
    else
        [ -f "$CONFIG" ] || die "配置路径不是普通文件"

        "$CANDIDATE" check -c "$CONFIG" \
            || die "现有配置无法通过新版本检查"

        ok "保留并验证现有配置"
    fi

    chown root:root "$CONFIG_DIR" "$CONFIG"
    chmod 755 "$CONFIG_DIR"
    chmod 600 "$CONFIG"
}

install_binary() {
    log "安装正式二进制..."

    NEW_BINARY="${INSTALL_DIR}/.sing-box.new.$$"

    cp "$CANDIDATE" "$NEW_BINARY"
    chown root:root "$NEW_BINARY"
    chmod 755 "$NEW_BINARY"

  

    mv -f "$NEW_BINARY" "$DEST"
    NEW_BINARY=""

    chown root:root "$DEST"
    chmod 755 "$DEST"

    ok "二进制安装完成"
}

create_service() {
    log "创建 OpenRC 服务..."

    [ -x /sbin/openrc-run ] || die "找不到 /sbin/openrc-run"

    local service_tmp
    service_tmp="${WORK}/sing-box.init"

    cat > "$service_tmp" <<'EOF'
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

    install -o root -g root -m 755 "$service_tmp" "$SERVICE"

    rc-update add sing-box default \
        || die "设置开机启动失败"

    ok "OpenRC 服务创建完成"
    ok "已设置 default 开机启动"
}

main() {
    echo "========================================"
    echo " sing-box Alpine Installer v${VERSION_SCRIPT}"
    echo "========================================"

    check_environment
    detect_arch
    prepare_workspace
    get_release
    check_disk
    download_release
    verify_sha256
    extract_binary
    verify_binary
    prepare_config
    install_binary
    create_service

    echo "========================================"
    echo "安装完成"
    echo "版本: ${VERSION}"
    echo "架构: ${ARCH}"
    echo "二进制: ${DEST}"
    echo "配置: ${CONFIG}"
    echo "服务: ${SERVICE}"
    echo "开机启动: 已设置"
    echo "自动启动: 未执行"
    echo "========================================"

    ok "安装成功"
}

main "$@"
