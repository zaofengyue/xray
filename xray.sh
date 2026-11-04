#!/bin/bash
# ==============================================================================
# xray.sh - 旗舰级 Xray 跨平台 VPS 一体化智能管理运维系统
# 核心引擎: XTLS/Xray-core 原生驱动
# 功能矩阵: 
#   - 直连协议: VLESS-Reality (Vision 原生流控), Shadowsocks 2022, Socks5, Trojan-TCP
#   - 隧道穿透: Cloudflare Argo 单端口 6合1 智能复用 (xhttp, vless-ws, vmess-ws, trojan-ws)
#   - 出口分流: Cloudflare WARP 原生 WireGuard 出口 (智能解锁 Netflix/ChatGPT/Gemini)
#   - 域名证书: acme.sh 自动化申请、Cron 定时自动续签、真实证书多协议绑定
#   - 网络兼容: 纯 IPv6 VPS 动态 NAT64 递归容灾、端口冲突智能回避、多端口监听
#   - 订阅分发: Base64 订阅、Raw 节点明细、Clash Meta (Mihomo) YAML、Xray 客户端 JSON
#   - 运维守护: Systemd 原生单元、在线无感热升级、探针监控、快捷指令集
# ==============================================================================

# ── 1. Bash 兼容性与运行环境加固 ──────────────────────────────────────────────
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  elif [ "$(id -u)" = "0" ] && command -v apk >/dev/null 2>&1; then
    echo "检测到 Alpine 系统，正在自动安装 bash..."
    apk add --no-cache bash >/dev/null 2>&1 || true
    exec bash "$0" "$@"
  else
    echo "错误: 本管理系统依赖 Bash 环境，请先执行 apt/yum/apk install -y bash"
    exit 1
  fi
fi

set -u
export TERM="${TERM:-xterm-256color}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ── 2. 颜色与日志终端输出 ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[0;97m'
NC='\033[0m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[XRAY]${NC} $*"; }

# ── 3. 基础目录与常量规范 ──────────────────────────────────────────────────────
HOME_DIR="${HOME:-/root}"
APP_DIR="$HOME_DIR/xray"
STATE_DIR="$APP_DIR/state"
ENV_FILE="$APP_DIR/config.env"
OUTBOUND_FILE="$STATE_DIR/outbound.env"
WARP_CONF="$STATE_DIR/warp.conf"
DOMAIN_CERT_DIR="$STATE_DIR/certs"
USED_PORTS_FILE="$STATE_DIR/used_ports.txt"

CONFIG_FILE="$STATE_DIR/config.json"
REALITY_KEY_FILE="$STATE_DIR/reality-keys.txt"
UUID_FILE="$STATE_DIR/uuid.txt"

SUB_FILE="$APP_DIR/sub.txt"
SUB_RAW_FILE="$APP_DIR/sub_raw.txt"
CLASH_META_FILE="$APP_DIR/clash_meta.yaml"
XRAY_CLIENT_FILE="$APP_DIR/xray_client.json"

LOG_FILE="$APP_DIR/run.log"
CF_LOG="$APP_DIR/cf.log"
KM_LOG="$APP_DIR/komari.log"
TURN2SOCKS_LOG="$APP_DIR/turn2socks.log"
PID_FILE="$APP_DIR/xray.pid"
TURN2SOCKS_PID="$APP_DIR/turn2socks.pid"
SVC_NAME="xray"

# 受保护的二进制目录
BIN_DIR="/tmp/xray-bin-$(id -u 2>/dev/null || echo 0)"
XRAY_BIN="$BIN_DIR/xray"
CF_BIN="$BIN_DIR/cloudflared"
KM_BIN="$BIN_DIR/komari-agent"
TURN2SOCKS_BIN="$BIN_DIR/turn2socks"
ACME_HOME="$STATE_DIR/acme"

mkdir -p "$APP_DIR" "$STATE_DIR" "$BIN_DIR" "$DOMAIN_CERT_DIR" 2>/dev/null || true
[ "$(id -u)" != "0" ] && chmod 700 "$BIN_DIR" "$STATE_DIR" 2>/dev/null || true
export XRAY_LOCATION_ASSET="$BIN_DIR"

# ── 4. 安全配置环境变量工具 ────────────────────────────────────────────────────
get_val() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  local val
  val="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

set_val() {
  local key="$1" val="$2"
  mkdir -p "$APP_DIR"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
  else
    echo "${key}=\"${val}\"" >> "$ENV_FILE"
  fi
}

load_env() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      '#'*|'') continue ;;
      *)
        v="${v#\"}"
        v="${v%\"}"
        eval "export $k=\"\$v\"" 2>/dev/null || true
        ;;
    esac
  done < "$ENV_FILE"
}

# ── 5. NAT64 容灾与纯 IPv6 VPS 动态补丁 ────────────────────────────────────────
_NAT64_APPLIED=0
_NAT64_TARGET_CONF=""
_NAT64_ORIG_CONTENT=""

nat64_recover_leftover() {
  [ -f /etc/resolv.conf.xray-orig ] || return 0
  local _rc="/etc/resolv.conf"
  [ -L "$_rc" ] && _rc="$(readlink -f "$_rc" 2>/dev/null || echo "/etc/resolv.conf")"
  if [ -w "$_rc" ] && grep -q "2a01:4f8:c2c:123f::1" "$_rc" 2>/dev/null; then
    cat /etc/resolv.conf.xray-orig > "$_rc" 2>/dev/null || true
  fi
  rm -f /etc/resolv.conf.xray-orig 2>/dev/null || true
}

nat64_enable_temp() {
  [ "$(id -u)" = "0" ] || return 0
  nat64_recover_leftover
  local _has_v4=0
  if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null | grep -q default && _has_v4=1
  elif command -v route >/dev/null 2>&1; then
    route -n 2>/dev/null | grep -q '^0.0.0.0' && _has_v4=1
  fi
  [ "$_has_v4" = "1" ] && return 0

  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 2 -m 3 https://api.github.com >/dev/null 2>&1 && return 0
  fi

  local _rc="/etc/resolv.conf"
  [ -e "$_rc" ] || return 0
  [ -L "$_rc" ] && _rc="$(readlink -f "$_rc" 2>/dev/null || echo "/etc/resolv.conf")"
  [ -w "$_rc" ] || return 0

  local _n1="2a01:4f8:c2c:123f::1" _n2="2001:67c:2b0::4"
  if ! grep -q "$_n1" "$_rc" 2>/dev/null && ! grep -q "$_n2" "$_rc" 2>/dev/null; then
    cp -f "$_rc" /etc/resolv.conf.xray-orig 2>/dev/null || return 0
    trap 'nat64_restore_temp' EXIT INT TERM HUP
    _NAT64_TARGET_CONF="$_rc"
    _NAT64_ORIG_CONTENT="$(cat "$_rc" 2>/dev/null)"
    log "检测到纯 IPv6 环境无法直连 IPv4，临时挂载公共 NAT64/DNS64 辅助通信..."
    printf 'nameserver %s\nnameserver %s\n%s\n' "$_n1" "$_n2" "$_NAT64_ORIG_CONTENT" > "$_rc" 2>/dev/null || true
    _NAT64_APPLIED=1
  fi
}

nat64_restore_temp() {
  if [ "$_NAT64_APPLIED" = "1" ] && [ -n "$_NAT64_TARGET_CONF" ] && [ -w "$_NAT64_TARGET_CONF" ]; then
    if [ -f /etc/resolv.conf.xray-orig ]; then
      cat /etc/resolv.conf.xray-orig > "$_NAT64_TARGET_CONF" 2>/dev/null || true
    elif [ -n "$_NAT64_ORIG_CONTENT" ]; then
      printf '%s\n' "$_NAT64_ORIG_CONTENT" > "$_NAT64_TARGET_CONF" 2>/dev/null || true
    fi
    rm -f /etc/resolv.conf.xray-orig 2>/dev/null || true
    trap - EXIT INT TERM HUP
  fi
  _NAT64_APPLIED=0
}

# ── 6. 基础系统依赖检测与安装 ──────────────────────────────────────────────────
try_install_pkg() {
  local _pkg="$1"
  [ "$(id -u)" = "0" ] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq $_pkg >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $_pkg >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $_pkg >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q $_pkg >/dev/null 2>&1 || true
  fi
}

ensure_cron() {
  command -v crontab >/dev/null 2>&1 && return 0
  [ "$(id -u)" = "0" ] || return 1
  log "检测到缺少 cron 定时服务，正在自动安装..."
  if command -v apt-get >/dev/null 2>&1; then
    try_install_pkg "cron"
    (systemctl enable --now cron 2>/dev/null || service cron start 2>/dev/null || /etc/init.d/cron start 2>/dev/null) &
  elif command -v apk >/dev/null 2>&1; then
    try_install_pkg "cronie"
    (crond 2>/dev/null || rc-service cronie start 2>/dev/null || true) &
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    try_install_pkg "crontabs"
    systemctl enable --now crond 2>/dev/null || true
  fi
  sleep 1
  command -v crontab >/dev/null 2>&1 && return 0
  return 1
}

ensure_basic_deps() {
  nat64_enable_temp
  local _missing=""
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _missing="$_missing curl"
  command -v tar >/dev/null 2>&1 || _missing="$_missing tar"
  command -v unzip >/dev/null 2>&1 || _missing="$_missing unzip"
  command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
  command -v socat >/dev/null 2>&1 || _missing="$_missing socat"
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _missing="$_missing iproute2"

  if [ -n "$_missing" ]; then
    warn "正在自动安装基础运维组件:${_missing}..."
    try_install_pkg "$_missing"
  fi
  ensure_cron || true
  nat64_restore_temp
}

# ── 7. 架构探测与多协议下载工具 ────────────────────────────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "64" ;;
    aarch64|arm64)  echo "arm64-v8a" ;;
    armv7l|armhf)   echo "arm32-v7a" ;;
    s390x)          echo "s390x" ;;
    i386|i686)      echo "32" ;;
    *)              echo "64" ;;
  esac
}

detect_cf_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "linux-amd64" ;;
    aarch64|arm64)  echo "linux-arm64" ;;
    armv7l|armhf)   echo "linux-arm" ;;
    i386|i686)      echo "linux-386" ;;
    *)              echo "linux-amd64" ;;
  esac
}

detect_km_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "linux_amd64" ;;
    aarch64|arm64)  echo "linux_arm64" ;;
    armv7l|armhf)   echo "linux_armv7" ;;
    *)              echo "linux_amd64" ;;
  esac
}

download_file() {
  local url="$1" dest="$2"
  nat64_enable_temp
  local success=1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 -m 60 "$url" -o "$dest" && success=0
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=15 "$url" -O "$dest" && success=0
  fi
  nat64_restore_temp
  return $success
}

extract_zip() {
  local zip_file="$1" target_dir="$2"
  mkdir -p "$target_dir"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip_file" -d "$target_dir"
  elif command -v tar >/dev/null 2>&1 && tar -tf "$zip_file" >/dev/null 2>&1; then
    tar -xf "$zip_file" -C "$target_dir"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$zip_file" "$target_dir"
  elif command -v python >/dev/null 2>&1; then
    python -m zipfile -e "$zip_file" "$target_dir"
  else
    die "缺少 zip 解压工具，请执行: apt-get install -y unzip"
  fi
}

download_xray() {
  local target_ver="${1:-latest}"
  log "正在下载 Xray-core (${target_ver})..."
  local xarch url tmpzip
  xarch="$(detect_arch)"
  if [ "$target_ver" = "latest" ]; then
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xarch}.zip"
  else
    target_ver="v${target_ver#v}"
    url="https://github.com/XTLS/Xray-core/releases/download/${target_ver}/Xray-linux-${xarch}.zip"
  fi
  tmpzip="/tmp/xray_dl_$$.zip"
  download_file "$url" "$tmpzip" || { warn "下载 Xray 失败: $url"; return 1; }
  local extract_tmp="/tmp/xray_ext_$$"
  mkdir -p "$extract_tmp"
  extract_zip "$tmpzip" "$extract_tmp"
  mv -f "$extract_tmp/xray" "$XRAY_BIN"
  [ -f "$extract_tmp/geoip.dat" ] && mv -f "$extract_tmp/geoip.dat" "$BIN_DIR/"
  [ -f "$extract_tmp/geosite.dat" ] && mv -f "$extract_tmp/geosite.dat" "$BIN_DIR/"
  rm -rf "$tmpzip" "$extract_tmp"
  chmod +x "$XRAY_BIN"
  log "Xray-core 部署就绪: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  return 0
}

download_cloudflared() {
  log "正在下载 cloudflared (Argo)..."
  local cfarch url
  cfarch="$(detect_cf_arch)"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${cfarch}"
  download_file "$url" "$CF_BIN" || { warn "下载 cloudflared 失败"; return 1; }
  chmod +x "$CF_BIN"
  log "Cloudflared 部署就绪"
  return 0
}

download_komari() {
  log "正在下载 komari-agent (探针)..."
  local kmarch url
  kmarch="$(detect_km_arch)"
  url="https://github.com/komari-monitoring/komari-agent/releases/latest/download/komari-agent_${kmarch}"
  download_file "$url" "$KM_BIN" || { warn "下载 komari-agent 失败"; return 1; }
  chmod +x "$KM_BIN"
  log "Komari-agent 部署就绪"
  return 0
}

download_turn2socks() {
  local t2s_arch="amd64"
  case "$(uname -m)" in
    aarch64|arm64) t2s_arch="arm64" ;;
    *)             t2s_arch="amd64" ;;
  esac

  if [ -x "$TURN2SOCKS_BIN" ]; then
    return 0
  fi

  # 优先检测本地源码目录并尝试由本地 Go 编译
  if [ -d "$APP_DIR/turn2socks" ] && command -v go >/dev/null 2>&1; then
    log "检测到本地 Go 环境，正在编译 turn2socks..."
    if (cd "$APP_DIR/turn2socks" && CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o "$TURN2SOCKS_BIN" .) >/dev/null 2>&1; then
      chmod +x "$TURN2SOCKS_BIN"
      log "turn2socks 本地编译成功"
      return 0
    fi
  fi

  log "正在下载 turn2socks 二进制 (${t2s_arch})..."
  local url="https://github.com/zaofengyue/singbox/releases/latest/download/turn2socks-linux-${t2s_arch}"
  if download_file "$url" "$TURN2SOCKS_BIN"; then
    chmod +x "$TURN2SOCKS_BIN"
    log "turn2socks 部署就绪"
    return 0
  fi
  warn "turn2socks 下载或编译失败"
  return 1
}

stop_turn2socks() {
  if [ -f "$TURN2SOCKS_PID" ]; then
    local p
    p="$(cat "$TURN2SOCKS_PID" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    rm -f "$TURN2SOCKS_PID" 2>/dev/null || true
  fi
  pkill -x "turn2socks" 2>/dev/null || true
}

start_turn2socks() {
  [ -f "$OUTBOUND_FILE" ] || return 0
  local o_type
  o_type="$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  [ "$o_type" = "turn" ] || return 0

  local addr port user pass lport
  addr="$(grep '^HOST=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  port="$(grep '^PORT=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  user="$(grep '^USER=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  pass="$(grep '^PASS=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  lport="$(grep '^LOCAL_PORT=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  [ -z "$lport" ] && lport=10808
  [ -z "$port" ] && port=3478
  [ -z "$addr" ] && return 0

  stop_turn2socks
  if [ ! -x "$TURN2SOCKS_BIN" ]; then
    download_turn2socks || { warn "无法启动 turn2socks: 二进制不存在"; return 1; }
  fi

  local turn_host="$addr"
  case "$turn_host" in
    *:*)
      turn_host="${turn_host#\[}"
      turn_host="${turn_host%\]*}"
      turn_host="[${turn_host}]"
      ;;
  esac
  local args=(-listen "127.0.0.1:${lport}" -turn "${turn_host}:${port}")
  [ -n "$user" ] && args+=(-user "$user")

  TURN_PASS="$pass" nohup "$TURN2SOCKS_BIN" "${args[@]}" >> "$TURN2SOCKS_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$TURN2SOCKS_PID"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    log "turn2socks 转接服务已就绪 (PID: $pid, 本地监听 127.0.0.1:${lport})"
    return 0
  else
    warn "turn2socks 启动失败，请检查 $TURN2SOCKS_LOG"
    return 1
  fi
}

ensure_binaries() {
  [ -x "$XRAY_BIN" ] || download_xray || die "Xray-core 初始化失败"
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ ! -x "$CF_BIN" ]; then
    download_cloudflared || warn "Cloudflared 准备失败，Argo 功能可能受限"
  fi
  if [ -n "$(get_val KOMARI_DOMAIN)" ] && [ -n "$(get_val KOMARI_TOKEN)" ] && [ ! -x "$KM_BIN" ]; then
    download_komari || warn "Komari 探针下载失败"
  fi
}

# ── 8. 网络、端口与 IP 探测工具 ────────────────────────────────────────────────
port_in_use_os() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${p} " && return 0
    ss -lun 2>/dev/null | grep -q ":${p} " && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${p} " && return 0
    netstat -lun 2>/dev/null | grep -q ":${p} " && return 0
  fi
  return 1
}

port_ok() {
  local p="$1"
  [ -z "$p" ] && return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -lt 1 ] || [ "$p" -gt 65535 ] && return 1
  [ -f "$USED_PORTS_FILE" ] && grep -qx "$p" "$USED_PORTS_FILE" 2>/dev/null && return 1
  port_in_use_os "$p" && return 1
  echo "$p" >> "$USED_PORTS_FILE"
  return 0
}

get_free_port() {
  local default_port="${1:-10086}"
  if port_ok "$default_port"; then
    echo "$default_port"
    return
  fi
  local _tries=0 _rand
  while [ $_tries -lt 30 ]; do
    _rand=$(( (RANDOM % 28000) + 12000 ))
    if port_ok "$_rand"; then
      echo "$_rand"
      return
    fi
    _tries=$((_tries + 1))
  done
  echo "$default_port"
}

wait_port() {
  local host="$1" port="$2" max_wait="${3:-10}"
  local count=0
  while [ $count -lt $max_wait ]; do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$host" "$port" 2>/dev/null && return 0
    elif command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -q ":${port} " && return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

get_public_ip() {
  local custom_ip
  custom_ip="$(get_val PUBLIC_IP)"
  if [ -n "$custom_ip" ]; then
    echo "$custom_ip"
    return
  fi
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -sL --max-time 3 https://api.ipify.org 2>/dev/null || curl -4 -sL --max-time 3 https://ipinfo.io/ip 2>/dev/null || true)"
    if [ -z "$ip" ]; then
      ip="$(curl -6 -sL --max-time 3 https://api64.ipify.org 2>/dev/null || true)"
    fi
  elif command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

format_addr() {
  local a="$1"
  if [[ "$a" =~ : ]]; then
    echo "[$a]"
  else
    echo "$a"
  fi
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

press_any_key() {
  echo ""
  read -n 1 -s -r -p "按任意键继续..."
  echo ""
}

# ── 9. UUID 与 Reality 密钥体系 ────────────────────────────────────────────────
get_uuid() {
  local u
  u="$(get_val UUID)"
  [ -z "$u" ] && [ -f "$UUID_FILE" ] && u="$(cat "$UUID_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$u" ]; then
    if [ -x "$XRAY_BIN" ]; then
      u="$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]')"
    elif command -v uuidgen >/dev/null 2>&1; then
      u="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    else
      u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a1b2c3d4-e5f6-7890-abcd-ef1234567890")"
    fi
    set_val UUID "$u"
    echo "$u" > "$UUID_FILE"
  fi
  echo "$u"
}

get_reality_keys() {
  local priv="" pub=""
  if [ -f "$REALITY_KEY_FILE" ]; then
    priv="$(grep '^PrivateKey:' "$REALITY_KEY_FILE" 2>/dev/null | head -1 | cut -d' ' -f2-)"
    pub="$(grep '^PublicKey:' "$REALITY_KEY_FILE" 2>/dev/null | head -1 | cut -d' ' -f2-)"
  fi
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    if [ -x "$XRAY_BIN" ]; then
      local kp
      kp="$("$XRAY_BIN" x25519 2>/dev/null)"
      priv="$(echo "$kp" | grep -i "Private key:" | awk '{print $NF}')"
      pub="$(echo "$kp" | grep -i "Public key:" | awk '{print $NF}')"
      if [ -n "$priv" ] && [ -n "$pub" ]; then
        echo "PrivateKey: $priv" > "$REALITY_KEY_FILE"
        echo "PublicKey: $pub" >> "$REALITY_KEY_FILE"
        chmod 600 "$REALITY_KEY_FILE"
      fi
    fi
  fi
  echo "$priv $pub"
}

# ── 10. ACME.sh 自动化域名证书系统 ─────────────────────────────────────────────
ensure_acme() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  log "正在安装 acme.sh 自动化证书引擎..."
  mkdir -p "$STATE_DIR"
  local tmp_acme="$STATE_DIR/acme-dl-$$"
  rm -rf "$tmp_acme" && mkdir -p "$tmp_acme"
  if ! download_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" "$tmp_acme/acme.sh"; then
    warn "下载 acme.sh 失败，请检查网络"
    rm -rf "$tmp_acme"
    return 1
  fi
  chmod +x "$tmp_acme/acme.sh"
  ensure_cron || true
  (cd "$tmp_acme" && ./acme.sh --install --home "$ACME_HOME" --force >/dev/null 2>&1)
  rm -rf "$tmp_acme"
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  return 1
}

_list_domain_certs() {
  [ -d "$DOMAIN_CERT_DIR" ] || return 0
  for d in "$DOMAIN_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    local dom
    dom="$(basename "$d")"
    [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ] && echo "$dom"
  done
}

apply_domain_to_all_protos() {
  local dom="$1"
  set_val SERVER_DOMAIN "$dom"
  set_val TROJAN_CERT_DOMAIN "$dom"
  set_val VLESS_TLS_CERT_DOMAIN "$dom"
  log "已将 ${CYAN}${dom}${GREEN} 设为全局连接域名，并绑定至 TLS 直连协议！"
  do_restart
}

menu_domain_cert() {
  while true; do
    clear
    echo -e "${GREEN}==================== 域名证书 (acme.sh) ====================${RESET}"
    local certs _s_dom
    certs="$(_list_domain_certs)"
    _s_dom="$(get_val SERVER_DOMAIN)"
    echo -e "${GRAY}已签发/导入证书:${RESET} ${CYAN}${certs:-暂无}${RESET}"
    echo -e "${GRAY}当前连接域名:${RESET}   ${CYAN}${_s_dom:-使用公网IP直连}${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"
    echo -e "${WHITE}1. 申请 Let's Encrypt 证书 (需 80 端口可用且已解析)${RESET}"
    echo -e "${WHITE}2. 导入外部已有证书 (cert.pem + key.pem)${RESET}"
    echo -e "${WHITE}3. 强制续期指定域名证书${RESET}"
    echo -e "${WHITE}4. 删除已存域名证书${RESET}"
    echo -e "${WHITE}0. 返回上一级菜单${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"
    read -p "请输入选项: " c_opt
    case "$c_opt" in
      1)
        ensure_acme || { warn "acme.sh 初始化失败"; press_any_key; continue; }
        read -p "请输入解析到本机的域名 (如 vps.example.com): " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        if [ -n "$domain" ]; then
          mkdir -p "$DOMAIN_CERT_DIR/$domain"
          "$ACME_HOME/acme.sh" --home "$ACME_HOME" --register-account -m "admin@${domain}" --server letsencrypt >/dev/null 2>&1 || true
          log "正在向 Let's Encrypt 申请证书..."
          if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt --force; then
            "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
              --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
              --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" \
              --reloadcmd "pkill -f 'xray run' 2>/dev/null || true" >/dev/null 2>&1
            chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem"
            log "证书申请安装成功！"
            read -p "是否将此域名应用到全部直连协议？[Y/n]: " _apply_all
            case "$_apply_all" in
              n|N) ;;
              *) apply_domain_to_all_protos "$domain" ;;
            esac
          else
            warn "证书签发失败，请确认域名已正确解析到本机公网 IP 且 80 端口未被占用"
            rm -rf "$DOMAIN_CERT_DIR/$domain"
          fi
          press_any_key
        fi
        ;;
      2)
        read -p "请输入域名标识: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        read -p "cert.pem 绝对路径: " cpath
        read -p "key.pem 绝对路径: " kpath
        if [ -f "$cpath" ] && [ -f "$kpath" ] && [ -n "$domain" ]; then
          mkdir -p "$DOMAIN_CERT_DIR/$domain"
          cp -f "$cpath" "$DOMAIN_CERT_DIR/$domain/cert.pem"
          cp -f "$kpath" "$DOMAIN_CERT_DIR/$domain/key.pem"
          chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem"
          log "证书导入成功！"
          read -p "是否将此域名应用到全部直连协议？[Y/n]: " _apply_all
          case "$_apply_all" in
            n|N) ;;
            *) apply_domain_to_all_protos "$domain" ;;
          esac
        else
          warn "文件不存在或路径无效"
        fi
        press_any_key
        ;;
      3)
        read -p "请输入要续期的域名: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        if [ -d "$DOMAIN_CERT_DIR/$domain" ] && [ -x "$ACME_HOME/acme.sh" ]; then
          log "正在续期证书..."
          if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --renew -d "$domain" --force --standalone --httpport 80; then
            "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
              --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
              --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" >/dev/null 2>&1
            log "证书续期并挂载成功！"
            do_restart
          else
            warn "证书续期失败"
          fi
        else
          warn "未找到此域名的证书目录或 acme.sh 未就绪"
        fi
        press_any_key
        ;;
      4)
        read -p "请输入要删除的域名: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        if [ -n "$domain" ]; then
          rm -rf "$DOMAIN_CERT_DIR/$domain"
          [ -x "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --home "$ACME_HOME" --remove -d "$domain" >/dev/null 2>&1 || true
          [ "$(get_val SERVER_DOMAIN)" = "$domain" ] && set_val SERVER_DOMAIN ""
          log "证书已移除"
          do_restart
        fi
        press_any_key
        ;;
      0) return ;;
    esac
  done
}

# ── 11. Cloudflare WARP WireGuard 原生出口与智能分流 ───────────────────────────
setup_warp_outbound() {
  clear
  echo -e "${GREEN}==================== 设置 Cloudflare WARP 原生出口 ====================${RESET}"
  local need_reg=1
  if [ -f "$WARP_CONF" ]; then
    local old_v4 old_v6
    old_v4="$(grep '^IPV4=' "$WARP_CONF" 2>/dev/null | cut -d'=' -f2-)"
    old_v6="$(grep '^IPV6=' "$WARP_CONF" 2>/dev/null | cut -d'=' -f2-)"
    echo -e "检测到已保存的 WARP 凭据 (IPv4: ${CYAN}${old_v4:-未知}${RESET}, IPv6: ${CYAN}${old_v6:-未知}${RESET})"
    echo -e "${WHITE}1. 使用已保存凭据  2. 重新向 Cloudflare 注册新账号  0. 取消${RESET}"
    read -p "请选择 [默认 1]: " warp_opt
    warp_opt="${warp_opt:-1}"
    case "$warp_opt" in
      1) need_reg=0 ;;
      2) need_reg=1 ;;
      *) return ;;
    esac
  fi

  if [ "$need_reg" = "1" ]; then
    log "正在生成 WireGuard X25519 密钥对..."
    local priv_key pub_key
    read -r priv_key pub_key <<< "$(get_reality_keys)"
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
      priv_key="$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 2>/dev/null)"
      pub_key="$(openssl pkey -in <(openssl genpkey -algorithm ed25519 2>/dev/null) -pubout -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null || echo "")"
    fi
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
      read -p "自动生成失败，请手动输入 WireGuard PrivateKey: " priv_key
      read -p "请输入 WireGuard PublicKey: " pub_key
    fi

    log "正在向 Cloudflare Client API 官方注册设备凭据..."
    local reg_url="https://api.cloudflareclient.com/v0a2158/reg"
    local tos
    tos="$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    local post_data="{\"key\":\"${pub_key}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${tos}\",\"model\":\"PC\",\"type\":\"Android\",\"locale\":\"zh_CN\"}"
    local resp=""
    if command -v curl >/dev/null 2>&1; then
      resp="$(curl -s -X POST "$reg_url" -H "Content-Type: application/json; charset=UTF-8" -H "User-Agent: okhttp/3.12.1" -d "$post_data" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      resp="$(wget -q -O- --header="Content-Type: application/json; charset=UTF-8" --header="User-Agent: okhttp/3.12.1" --post-data="$post_data" "$reg_url" 2>/dev/null || true)"
    fi

    local peer_pub client_id v6
    peer_pub="$(echo "$resp" | grep -o '"public_key": *"[^"]*"' | head -1 | cut -d'"' -f4)"
    client_id="$(echo "$resp" | grep -o '"client_id": *"[^"]*"' | head -1 | cut -d'"' -f4)"

    if [ -z "$peer_pub" ]; then
      warn "Cloudflare API 注册失败，返回内容: $(echo "$resp" | head -n 3)"
      press_any_key
      return 1
    fi

    v6="$(echo "$resp" | grep -o '"v6": *"[^"]*"' | tail -1 | cut -d'"' -f4 | sed 's|/.*||')"
    local reserved="0, 0, 0"
    if [ -n "$client_id" ]; then
      local _dec=""
      if command -v python3 >/dev/null 2>&1; then
        _dec="$(python3 -c "import base64,sys; b=base64.b64decode(sys.argv[1]); print(f'{b[0]}, {b[1]}, {b[2]}')" "$client_id" 2>/dev/null || true)"
      fi
      [ -n "$_dec" ] && reserved="$_dec"
    fi

    cat > "$WARP_CONF" << EOF
PRIV_KEY=${priv_key}
PEER_PUB_KEY=${peer_pub:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}
IPV4=172.16.0.2
IPV6=${v6}
RESERVED=${reserved}
ENDPOINT=engage.cloudflareclient.com:2408
EOF
    chmod 600 "$WARP_CONF"
    log "WARP 凭据生成成功！(分配内部 IPv4: 172.16.0.2, IPv6: ${v6:-无})"
  fi

  echo -e "${GRAY}------------------------------------------------------------${RESET}"
  echo -e "请选择出口分流模式:"
  echo -e "${WHITE}1. 智能分流 (推荐: 仅 Netflix, ChatGPT, Gemini, Disney 走 WARP 解锁，其余直连)${RESET}"
  echo -e "${WHITE}2. 全局代理 (所有出站流量统一走 WARP 伪装落地 IP)${RESET}"
  read -p "请选择 [默认 1]: " r_mode_opt
  local r_mode="split"
  [ "${r_mode_opt:-1}" = "2" ] && r_mode="global"

  cat > "$OUTBOUND_FILE" << EOF
TYPE=warp
ROUTE_MODE=${r_mode}
EOF
  chmod 600 "$OUTBOUND_FILE"
  log "WARP 出口配置已就绪，正在重启 Xray 服务生效..."
  do_restart
  press_any_key
}

prompt_route_mode() {
  echo -e "${GRAY}------------------------------------------------------------${RESET}" >&2
  echo -e "请选择分流模式:" >&2
  echo -e "${WHITE}1. 智能分流 (推荐: 仅 Netflix/ChatGPT/Gemini/流媒体走出口代理，其余直连)${RESET}" >&2
  echo -e "${WHITE}2. 全局代理 (所有出站流量统一走出口代理)${RESET}" >&2
  echo -e "${GRAY}------------------------------------------------------------${RESET}" >&2
  local rm_opt
  read -p "选项 [默认 1]: " rm_opt
  if [ "${rm_opt:-1}" = "2" ]; then
    printf 'global'
  else
    printf 'split'
  fi
}

menu_outbound() {
  clear
  echo -e "${GREEN}==================== 出口设置与落地分流 ====================${RESET}"
  local cur_type="direct" cur_mode="直连" cur_addr="" cur_port=""
  if [ -f "$OUTBOUND_FILE" ]; then
    cur_type="$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    cur_addr="$(grep '^HOST=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    cur_port="$(grep '^PORT=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    local r_m
    r_m="$(grep '^ROUTE_MODE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    [ "$r_m" = "split" ] && cur_mode="智能分流 (AI/流媒体解锁)"
    [ "$r_m" = "global" ] && cur_mode="全局代理 (全走出口)"
  fi
  if [ "$cur_type" = "direct" ]; then
    echo -e "当前出站模式: ${CYAN}原生直连 (默认)${RESET}"
  elif [ "$cur_type" = "warp" ]; then
    echo -e "当前出站模式: ${CYAN}Cloudflare WARP (WireGuard)${RESET} [模式: ${GREEN}${cur_mode}${RESET}]"
  else
    echo -e "当前出站模式: ${CYAN}${cur_type}${RESET} -> ${CYAN}${cur_addr}:${cur_port}${RESET} [模式: ${GREEN}${cur_mode}${RESET}]"
  fi
  echo -e "${GREEN}------------------------------------------------------------${RESET}"
  echo -e "${WHITE}1. 设置 SOCKS5 出口代理${RESET}"
  echo -e "${WHITE}2. 设置 HTTP 出口代理${RESET}"
  echo -e "${WHITE}3. 设置 TURN 穿透出口 (基于 turn2socks 转接)${RESET}"
  echo -e "${WHITE}4. 设置 Cloudflare WARP 原生出口 (WireGuard 解锁 AI/流媒体)${RESET}"
  echo -e "${WHITE}5. 切换分流模式 (智能分流 / 全局代理)${RESET}"
  echo -e "${WHITE}6. 恢复原生直连出口 (清除全部外置出站)${RESET}"
  echo -e "${WHITE}0. 返回上一级菜单${RESET}"
  echo -e "${GREEN}------------------------------------------------------------${RESET}"
  read -p "请输入选项 [0-6]: " o_opt
  case "$o_opt" in
    1|2)
      local proto="socks"
      [ "$o_opt" = "2" ] && proto="http"
      read -p "代理服务器 IP/域名: " p_host
      read -p "代理端口: " p_port
      read -p "用户名 (留空无认证): " p_user
      local p_pass=""
      [ -n "$p_user" ] && read -p "密码: " p_pass
      if [ -n "$p_host" ] && [ -n "$p_port" ]; then
        local r_m
        r_m="$(prompt_route_mode)"
        stop_turn2socks 2>/dev/null || true
        cat > "$OUTBOUND_FILE" << EOF
TYPE=${proto}
HOST=${p_host}
PORT=${p_port}
USER=${p_user}
PASS=${p_pass}
ROUTE_MODE=${r_m}
EOF
        chmod 600 "$OUTBOUND_FILE"
        log "${proto^^} 出口配置已保存，正在重启服务生效..."
        do_restart
        press_any_key
      fi
      ;;
    3)
      read -p "TURN 服务器地址: " t_host
      read -p "TURN 服务器端口 [默认 3478]: " t_port
      t_port="${t_port:-3478}"
      read -p "用户名 (留空无认证): " t_user
      local t_pass=""
      [ -n "$t_user" ] && read -p "密码: " t_pass
      read -p "本地 SOCKS5 转接端口 [默认 10808]: " t_lport
      t_lport="${t_lport:-10808}"
      if [ -n "$t_host" ]; then
        local r_m
        r_m="$(prompt_route_mode)"
        cat > "$OUTBOUND_FILE" << EOF
TYPE=turn
HOST=${t_host}
PORT=${t_port}
USER=${t_user}
PASS=${t_pass}
LOCAL_PORT=${t_lport}
ROUTE_MODE=${r_m}
EOF
        chmod 600 "$OUTBOUND_FILE"
        log "TURN 出口配置已保存，正在启动 turn2socks 并重启服务..."
        start_turn2socks
        do_restart
        press_any_key
      fi
      ;;
    4)
      setup_warp_outbound
      ;;
    5)
      if [ ! -f "$OUTBOUND_FILE" ]; then
        warn "当前未设置任何外置出口，无法切换分流模式"
      else
        local new_mode
        new_mode="$(prompt_route_mode)"
        if grep -q '^ROUTE_MODE=' "$OUTBOUND_FILE" 2>/dev/null; then
          sed -i "s/^ROUTE_MODE=.*/ROUTE_MODE=${new_mode}/" "$OUTBOUND_FILE"
        else
          echo "ROUTE_MODE=${new_mode}" >> "$OUTBOUND_FILE"
        fi
        local m_desc="智能分流"
        [ "$new_mode" = "global" ] && m_desc="全局代理"
        log "分流模式已切换为: ${m_desc}，正在重启服务生效..."
        do_restart
      fi
      press_any_key
      ;;
    6)
      rm -f "$OUTBOUND_FILE"
      stop_turn2socks 2>/dev/null || true
      log "已恢复原生直连出站"
      do_restart
      press_any_key
      ;;
    0) return ;;
  esac
}

# ── 12. Xray 原生 JSON 配置生成引擎 ───────────────────────────────────────────
generate_config() {
  load_env
  local uuid reality_port reality_domain reality_priv ss_port ss_pass s5_port s5_user s5_pass trojan_port
  uuid="$(get_uuid)"
  reality_port="$(get_val REALITY_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r reality_priv reality_pub <<< "$(get_reality_keys)"

  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_val SS_PASS)"
  [ -z "$ss_pass" ] && ss_pass="$(openssl rand -base64 16 2>/dev/null || echo "XrayPasswd12345678")"

  s5_port="$(get_val S5_PORT)"
  s5_user="$(get_val S5_USER)"
  [ -z "$s5_user" ] && s5_user="${uuid:0:8}"
  s5_pass="$(get_val S5_PASS)"
  [ -z "$s5_pass" ] && s5_pass="${uuid:24}"

  trojan_port="$(get_val TROJAN_PORT)"

  cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
EOF

  local first_inbound=1
  append_inbound() {
    [ "$first_inbound" = "0" ] && echo "," >> "$CONFIG_FILE"
    echo "$1" >> "$CONFIG_FILE"
    first_inbound=0
  }

  # 1. Argo 穿透入站组
  if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
    append_inbound '    {
      "tag": "vmess-ws-in",
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "'"$uuid"'", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } }
    }'
    append_inbound '    {
      "tag": "vless-ws-in",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "'"$uuid"'" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } }
    }'
    append_inbound '    {
      "tag": "trojan-ws-in",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "'"$uuid"'" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } }
    }'
    append_inbound '    {
      "tag": "vless-xhttp-in",
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "'"$uuid"'" }], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/vless-xhttp", "mode": "packet-up" } }
    }'
  fi

  # 2. 直连 Reality 入站
  if [ -n "$reality_port" ] && [ -n "$reality_priv" ]; then
    append_inbound '    {
      "tag": "reality-in",
      "port": '"$reality_port"',
      "listen": "::",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "'"$uuid"'", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "'"$reality_domain"':443",
          "xver": 0,
          "serverNames": ["'"$reality_domain"'"],
          "privateKey": "'"$reality_priv"'",
          "shortIds": [""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }'
  fi

  # 3. 直连 Shadowsocks 2022 入站
  if [ -n "$ss_port" ]; then
    append_inbound '    {
      "tag": "ss-in",
      "port": '"$ss_port"',
      "listen": "::",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "'"$ss_pass"'",
        "network": "tcp,udp"
      }
    }'
  fi

  # 4. 直连 Socks5 入站
  if [ -n "$s5_port" ]; then
    append_inbound '    {
      "tag": "s5-in",
      "port": '"$s5_port"',
      "listen": "::",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [{ "user": "'"$s5_user"'", "pass": "'"$s5_pass"'" }],
        "udp": true
      }
    }'
  fi

  # 5. 直连 Trojan-TCP (支持 ACME 证书绑定)
  if [ -n "$trojan_port" ]; then
    local trojan_cert_dom cert_snippet
    trojan_cert_dom="$(get_val TROJAN_CERT_DOMAIN)"
    [ -z "$trojan_cert_dom" ] && trojan_cert_dom="$(get_val SERVER_DOMAIN)"
    if [ -n "$trojan_cert_dom" ] && [ -f "$DOMAIN_CERT_DIR/$trojan_cert_dom/cert.pem" ]; then
      cert_snippet='"security": "tls", "tlsSettings": { "certificates": [{ "certificateFile": "'"$DOMAIN_CERT_DIR/$trojan_cert_dom/cert.pem"'", "keyFile": "'"$DOMAIN_CERT_DIR/$trojan_cert_dom/key.pem"'" }] }'
    else
      cert_snippet='"security": "none"'
    fi
    append_inbound '    {
      "tag": "trojan-direct-in",
      "port": '"$trojan_port"',
      "listen": "::",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "'"$uuid"'" }] },
      "streamSettings": { "network": "tcp", '"$cert_snippet"' }
    }'
  fi

  cat >> "$CONFIG_FILE" << EOF
  ],
  "outbounds": [
EOF

  # 处理 Outbound 出口与分流策略
  local out_type="" out_route_mode="direct" active_outbound_tag=""
  if [ -f "$OUTBOUND_FILE" ]; then
    out_type="$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    out_route_mode="$(grep '^ROUTE_MODE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
  fi

  local first_outbound=1
  append_outbound() {
    [ "$first_outbound" = "0" ] && echo "," >> "$CONFIG_FILE"
    echo "$1" >> "$CONFIG_FILE"
    first_outbound=0
  }

  if [ "$out_type" = "warp" ] && [ -f "$WARP_CONF" ]; then
    active_outbound_tag="warp-out"
    local w_priv w_peer w_v4 w_v6 w_res w_end
    w_priv="$(grep '^PRIV_KEY=' "$WARP_CONF" | cut -d'=' -f2-)"
    w_peer="$(grep '^PEER_PUB_KEY=' "$WARP_CONF" | cut -d'=' -f2-)"
    w_v4="$(grep '^IPV4=' "$WARP_CONF" | cut -d'=' -f2-)"
    w_v6="$(grep '^IPV6=' "$WARP_CONF" | cut -d'=' -f2-)"
    w_res="$(grep '^RESERVED=' "$WARP_CONF" | cut -d'=' -f2-)"
    w_end="$(grep '^ENDPOINT=' "$WARP_CONF" | cut -d'=' -f2-)"

    local addr_arr="\"${w_v4}/32\""
    [ -n "$w_v6" ] && addr_arr="\"${w_v4}/32\", \"${w_v6}/128\""

    local warp_block='    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "'"$w_priv"'",
        "address": ['"$addr_arr"'],
        "peers": [{
          "publicKey": "'"$w_peer"'",
          "endpoint": "'"$w_end"'",
          "reserved": ['"$w_res"']
        }]
      }
    }'

    if [ "$out_route_mode" = "global" ]; then
      append_outbound "$warp_block"
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
    else
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
      append_outbound "$warp_block"
    fi
  elif [ "$out_type" = "socks" ] || [ "$out_type" = "http" ]; then
    active_outbound_tag="proxy-out"
    local p_h p_p p_u p_pass
    p_h="$(grep '^HOST=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    p_p="$(grep '^PORT=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    p_u="$(grep '^USER=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    p_pass="$(grep '^PASS=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    local u_block=""
    [ -n "$p_u" ] && u_block='"users": [{ "user": "'"$p_u"'", "pass": "'"$p_pass"'" }]'

    local proxy_block='    {
      "tag": "proxy-out",
      "protocol": "'"$out_type"'",
      "settings": {
        "servers": [{ "address": "'"$p_h"'", "port": '"$p_p"', '"$u_block"' }]
      }
    }'
    if [ "$out_route_mode" = "global" ]; then
      append_outbound "$proxy_block"
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
    else
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
      append_outbound "$proxy_block"
    fi
  elif [ "$out_type" = "turn" ]; then
    active_outbound_tag="turn-out"
    local t_lp
    t_lp="$(grep '^LOCAL_PORT=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    [ -z "$t_lp" ] && t_lp=10808
    local turn_block='    {
      "tag": "turn-out",
      "protocol": "socks",
      "settings": {
        "servers": [{ "address": "127.0.0.1", "port": '"$t_lp"' }]
      }
    }'
    if [ "$out_route_mode" = "global" ]; then
      append_outbound "$turn_block"
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
    else
      append_outbound '    { "protocol": "freedom", "tag": "direct" }'
      append_outbound "$turn_block"
    fi
  else
    append_outbound '    { "protocol": "freedom", "tag": "direct" }'
  fi
  append_outbound '    { "protocol": "blackhole", "tag": "block" }'

  cat >> "$CONFIG_FILE" << EOF
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
EOF

  if [ -n "$active_outbound_tag" ] && [ "$out_route_mode" = "split" ]; then
    cat >> "$CONFIG_FILE" << EOF
      {
        "type": "field",
        "outboundTag": "${active_outbound_tag}",
        "domain": [
          "geosite:openai",
          "geosite:netflix",
          "geosite:disney",
          "geosite:spotify",
          "geosite:hbo",
          "geosite:youtube"
        ]
      },
EOF
  elif [ -n "$active_outbound_tag" ] && [ "$out_route_mode" = "global" ]; then
    cat >> "$CONFIG_FILE" << EOF
      {
        "type": "field",
        "outboundTag": "${active_outbound_tag}",
        "network": "tcp,udp"
      },
EOF
  fi

  cat >> "$CONFIG_FILE" << EOF
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
}

# ── 13. 全协议多格式订阅分发生成器 ─────────────────────────────────────────────
generate_sub() {
  local uuid prefer_host argo_domain pub_ip name node_host
  uuid="$(get_uuid)"
  prefer_host="$(get_val CF_PREFER_HOST)"
  [ -z "$prefer_host" ] && prefer_host="www.visa.com.tw"
  argo_domain="$(get_val ARGO_DOMAIN)"
  [ -z "$argo_domain" ] && argo_domain="your-domain.com"
  pub_ip="$(get_public_ip)"
  name="$(get_val NAME)"
  [ -z "$name" ] && name="xray"

  node_host="$(get_val SERVER_DOMAIN)"
  [ -z "$node_host" ] && node_host="$(format_addr "$pub_ip")"

  local links=()
  local clash_proxies=()
  local clash_names=()

  # 1. Argo 穿透链路
  if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
    # VLESS-xhttp
    links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=xhttp&host=${argo_domain}&path=%2Fvless-xhttp&mode=packet-up&sni=${argo_domain}#${name}-VLESS-xhttp")
    clash_names+=("\"${name}-VLESS-xhttp\"")
    clash_proxies+=("  - name: \"${name}-VLESS-xhttp\"
    type: vless
    server: ${prefer_host}
    port: 443
    uuid: ${uuid}
    network: xhttp
    tls: true
    udp: true
    servername: ${argo_domain}
    xhttp-opts:
      path: /vless-xhttp
      mode: packet-up
      headers:
        Host: ${argo_domain}")

    # VLESS-WS
    links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=ws&host=${argo_domain}&path=%2Fvless-ws&sni=${argo_domain}#${name}-VLESS-WS")
    clash_names+=("\"${name}-VLESS-WS\"")
    clash_proxies+=("  - name: \"${name}-VLESS-WS\"
    type: vless
    server: ${prefer_host}
    port: 443
    uuid: ${uuid}
    network: ws
    tls: true
    udp: true
    servername: ${argo_domain}
    ws-opts:
      path: /vless-ws
      headers:
        Host: ${argo_domain}")

    # VMess-WS
    local vm_json
    vm_json="$(printf '{"v":"2","ps":"%s-VMess-WS","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess-ws","tls":"tls","sni":"%s"}' "$name" "$prefer_host" "$uuid" "$argo_domain" "$argo_domain")"
    links+=("vmess://$(b64 "$vm_json")")
    clash_names+=("\"${name}-VMess-WS\"")
    clash_proxies+=("  - name: \"${name}-VMess-WS\"
    type: vmess
    server: ${prefer_host}
    port: 443
    uuid: ${uuid}
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    udp: true
    servername: ${argo_domain}
    ws-opts:
      path: /vmess-ws
      headers:
        Host: ${argo_domain}")

    # Trojan-WS
    links+=("trojan://${uuid}@${prefer_host}:443?security=tls&type=ws&host=${argo_domain}&path=%2Ftrojan-ws&sni=${argo_domain}#${name}-Trojan-WS")
    clash_names+=("\"${name}-Trojan-WS\"")
    clash_proxies+=("  - name: \"${name}-Trojan-WS\"
    type: trojan
    server: ${prefer_host}
    port: 443
    password: ${uuid}
    network: ws
    tls: true
    udp: true
    sni: ${argo_domain}
    ws-opts:
      path: /trojan-ws
      headers:
        Host: ${argo_domain}")
  fi

  # 2. 直连 VLESS-Reality
  local reality_port reality_domain
  reality_port="$(get_val REALITY_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r _ reality_pub <<< "$(get_reality_keys)"

  if [ -n "$reality_port" ] && [ -n "$reality_pub" ] && [ -n "$pub_ip" ]; then
    local r_host="${node_host#[}"
    r_host="${r_host%]}"
    links+=("vless://${uuid}@${node_host}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&type=tcp#${name}-Reality")
    clash_names+=("\"${name}-Reality\"")
    clash_proxies+=("  - name: \"${name}-Reality\"
    type: vless
    server: ${r_host}
    port: ${reality_port}
    uuid: ${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${reality_domain}
    reality-opts:
      public-key: ${reality_pub}
    client-fingerprint: chrome")
  fi

  # 3. 直连 Shadowsocks 2022
  local ss_port ss_pass
  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_val SS_PASS)"
  if [ -n "$ss_port" ] && [ -n "$pub_ip" ]; then
    local ss_uinfo
    ss_uinfo="$(b64 "2022-blake3-aes-128-gcm:${ss_pass}")"
    links+=("ss://${ss_uinfo}@${node_host}:${ss_port}#${name}-SS2022")
    local s_host="${node_host#[}"
    s_host="${s_host%]}"
    clash_names+=("\"${name}-SS2022\"")
    clash_proxies+=("  - name: \"${name}-SS2022\"
    type: ss
    server: ${s_host}
    port: ${ss_port}
    cipher: 2022-blake3-aes-128-gcm
    password: \"${ss_pass}\"
    udp: true")
  fi

  # 4. 直连 Socks5
  local s5_port s5_user s5_pass
  s5_port="$(get_val S5_PORT)"
  s5_user="$(get_val S5_USER)"
  s5_pass="$(get_val S5_PASS)"
  [ -z "$s5_user" ] && s5_user="${uuid:0:8}"
  [ -z "$s5_pass" ] && s5_pass="${uuid:24}"
  if [ -n "$s5_port" ] && [ -n "$pub_ip" ]; then
    local s5_uinfo
    s5_uinfo="$(b64 "${s5_user}:${s5_pass}")"
    links+=("socks://${s5_uinfo}@${node_host}:${s5_port}#${name}-Socks5")
  fi

  # 5. 直连 Trojan-TCP
  local trojan_port
  trojan_port="$(get_val TROJAN_PORT)"
  if [ -n "$trojan_port" ] && [ -n "$pub_ip" ]; then
    local tr_sni tr_sec="none"
    tr_sni="$(get_val TROJAN_CERT_DOMAIN)"
    [ -z "$tr_sni" ] && tr_sni="$(get_val SERVER_DOMAIN)"
    [ -n "$tr_sni" ] && tr_sec="tls"
    links+=("trojan://${uuid}@${node_host}:${trojan_port}?security=${tr_sec}&sni=${tr_sni:-bing.com}#${name}-Trojan-Direct")
  fi

  # 写入原始链接与 Base64
  printf "%s\n" "${links[@]}" > "$SUB_RAW_FILE"
  b64 "$(printf "%s\n" "${links[@]}")" > "$SUB_FILE"
  chmod 600 "$SUB_FILE" "$SUB_RAW_FILE" 2>/dev/null || true

  # 写入 Clash Meta (Mihomo) 配置
  cat > "$CLASH_META_FILE" << EOF
# Xray Universal Proxy Engine - Clash Meta / Mihomo Config
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info

proxies:
$(printf "%s\n\n" "${clash_proxies[@]}")

proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
$(printf "      - %s\n" "${clash_names[@]}")

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXIES
EOF
  chmod 600 "$CLASH_META_FILE" 2>/dev/null || true
}

# ── 14. 服务守护、运行与进程调度 ───────────────────────────────────────────────
do_run() {
  load_env
  ensure_basic_deps
  ensure_binaries
  generate_config

  log "正在预校验 Xray 配置文件语法..."
  if ! "$XRAY_BIN" -test -config "$CONFIG_FILE"; then
    die "Xray 配置语法测试失败，请检查配置文件格式"
  fi
  log "Xray 语法校验通过 (Syntax OK)"

  # 若配置了 TURN 出口，优先拉起 turn2socks 转接守护
  if [ -f "$OUTBOUND_FILE" ] && [ "$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)" = "turn" ]; then
    start_turn2socks || true
  fi

  pkill -f "$XRAY_BIN" 2>/dev/null || true
  "$XRAY_BIN" run -config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  log "Xray 核心已启动 (PID: $(cat "$PID_FILE"))"

  # 启动 Cloudflared (Argo)
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ -x "$CF_BIN" ]; then
    pkill -f "$CF_BIN" 2>/dev/null || true
    local argo_domain argo_auth argo_proto
    argo_domain="$(get_val ARGO_DOMAIN)"
    argo_auth="$(get_val ARGO_AUTH)"
    argo_proto="$(get_val ARGO_PROTOCOL)"
    local cf_args=("tunnel" "--edge-ip-version" "auto" "--no-autoupdate")
    [ -n "$argo_proto" ] && cf_args+=("--protocol" "$argo_proto")

    if [ -n "$argo_domain" ] && [ -n "$argo_auth" ]; then
      cf_args+=("run" "--token" "$argo_auth")
      "$CF_BIN" "${cf_args[@]}" > "$CF_LOG" 2>&1 &
      log "Cloudflare 固定隧道已启动 (${argo_domain})"
    else
      cf_args+=("--url" "http://127.0.0.1:10003")
      "$CF_BIN" "${cf_args[@]}" > "$CF_LOG" 2>&1 &
      log "Cloudflare 临时隧道正在建立连接..."
      # 捕获分配的 trycloudflare 临时域名
      local count=0 new_host=""
      while [ $count -lt 30 ]; do
        new_host="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 | sed 's|https://||')"
        [ -n "$new_host" ] && break
        sleep 1
        count=$((count + 1))
      done
      if [ -n "$new_host" ]; then
        set_val ARGO_DOMAIN "$new_host"
        log "临时域名已成功分配: ${GREEN}https://${new_host}${RESET}"
      fi
    fi
  fi

  # 启动 Komari 探针
  local km_dom km_tok
  km_dom="$(get_val KOMARI_DOMAIN)"
  km_tok="$(get_val KOMARI_TOKEN)"
  if [ -n "$km_dom" ] && [ -n "$km_tok" ] && [ -x "$KM_BIN" ]; then
    pkill -f "$KM_BIN" 2>/dev/null || true
    km_dom="${km_dom#http://}"
    km_dom="${km_dom#https://}"
    "$KM_BIN" -e "$km_dom" -t "$km_tok" > "$KM_LOG" 2>&1 &
    log "Komari 监控探针已启动"
  fi

  generate_sub
  log "所有服务已部署就绪，订阅链接已写入 $SUB_FILE"

  # 看门狗进程
  while true; do
    if ! pgrep -f "$XRAY_BIN" >/dev/null 2>&1; then
      warn "检测到 Xray 核心意外退出，正在自动拉起守护..."
      "$XRAY_BIN" run -config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
      echo $! > "$PID_FILE"
    fi
    if [ -f "$OUTBOUND_FILE" ] && [ "$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)" = "turn" ]; then
      if [ -f "$TURN2SOCKS_PID" ] && ! kill -0 "$(cat "$TURN2SOCKS_PID" 2>/dev/null)" 2>/dev/null; then
        warn "检测到 turn2socks 转接异常退出，正在自动拉起守护..."
        start_turn2socks || true
      fi
    fi
    sleep 10
  done
}

do_stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "$XRAY_BIN" 2>/dev/null || true
  pkill -f "$CF_BIN" 2>/dev/null || true
  pkill -f "$KM_BIN" 2>/dev/null || true
  stop_turn2socks 2>/dev/null || true
  log "Xray 及相关组件已全部停止"
}

do_restart() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
    systemctl restart "$SVC_NAME"
    log "已通过 Systemd 服务重载重启"
  else
    do_stop
    sleep 1
    nohup "$0" run >/dev/null 2>&1 &
    log "已在后台重启服务"
  fi
}

# ── 15. Systemd 守护单元与全局快捷指令 ─────────────────────────────────────────
setup_systemd() {
  if [ "$(id -u)" != "0" ]; then
    warn "非 root 用户，跳过全局 systemd 服务注册"
    return
  fi
  cat > "/etc/systemd/system/${SVC_NAME}.service" << EOF
[Unit]
Description=Xray Universal Proxy Engine
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash ${APP_DIR}/xray.sh run
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
  log "Systemd 系统级服务 (${SVC_NAME}.service) 注册完成"
}

setup_shortcuts() {
  if [ "$(id -u)" = "0" ]; then
    local script_target="$APP_DIR/xray.sh"
    [ -f "$script_target" ] || cp -f "$0" "$script_target"
    chmod +x "$script_target"
    ln -sf "$script_target" /usr/local/bin/xray
    ln -sf "$script_target" /usr/local/bin/xray-sub
    ln -sf "$script_target" /usr/local/bin/xray-log
    ln -sf "$script_target" /usr/local/bin/xray-del
  fi
}

# ── 16. 组件在线无感热升级与脚本自更新 ─────────────────────────────────────────
do_update_script() {
  clear
  echo -e "${GREEN}==================== 更新 xray.sh 管理脚本 ====================${RESET}"
  local SCRIPT_RAW="https://raw.githubusercontent.com/zaofengyue/xray/main/xray.sh"
  log "正在从 GitHub 检测并下载最新脚本..."
  local tmp_sh
  tmp_sh="$(mktemp "/tmp/xray_sh_update.XXXXXX" 2>/dev/null || echo "/tmp/xray_sh_$$.sh")"
  if download_file "$SCRIPT_RAW" "$tmp_sh"; then
    if [ -s "$tmp_sh" ] && bash -n "$tmp_sh" >/dev/null 2>&1 && grep -q 'do_menu' "$tmp_sh" 2>/dev/null; then
      cp -f "$APP_DIR/xray.sh" "$APP_DIR/xray.sh.bak" 2>/dev/null || true
      mv -f "$tmp_sh" "$APP_DIR/xray.sh"
      chmod +x "$APP_DIR/xray.sh"
      log "管理脚本更新成功！正在自动重新进入管理面板..."
      sleep 2
      exec bash "$APP_DIR/xray.sh"
    else
      warn "更新包语法校验失败，已取消替换以保护系统完整性"
      rm -f "$tmp_sh"
    fi
  else
    warn "下载失败，请检查网络连接"
    rm -f "$tmp_sh"
  fi
  press_any_key
}

menu_update() {
  clear
  echo -e "${GREEN}==================== 组件在线升级 ====================${RESET}"
  local cur_xray="未安装"
  [ -x "$XRAY_BIN" ] && cur_xray="$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  echo -e "当前 Xray 核心版本: ${CYAN}${cur_xray}${RESET}"
  echo -e "${GREEN}------------------------------------------------------${RESET}"
  echo -e "${WHITE}1. 升级 Xray-core 至 GitHub 官方最新稳定版${RESET}"
  echo -e "${WHITE}2. 升级 Cloudflared (Argo) 穿透引擎${RESET}"
  echo -e "${WHITE}3. 升级 Komari-agent 探针${RESET}"
  echo -e "${WHITE}4. 更新 xray.sh 本管理脚本${RESET}"
  echo -e "${WHITE}0. 返回上一级菜单${RESET}"
  echo -e "${GREEN}------------------------------------------------------${RESET}"
  read -p "请输入选项: " u_opt
  case "$u_opt" in
    1)
      if download_xray "latest"; then
        log "Xray 核心已更新至最新版！"
        do_restart
      fi
      press_any_key
      ;;
    2)
      download_cloudflared && { log "Cloudflared 已更新！"; do_restart; }
      press_any_key
      ;;
    3)
      download_komari && { log "Komari-agent 已更新！"; do_restart; }
      press_any_key
      ;;
    4) do_update_script ;;
    0) return ;;
  esac
}

# ── 17. 交互式智能安装向导 (do_install) ─────────────────────────────────────────
do_install() {
  clear
  echo -e "${GREEN}================================================================${RESET}"
  echo -e "${WHITE}          Xray Universal Proxy Engine 全自动智能安装向导          ${RESET}"
  echo -e "${GREEN}================================================================${RESET}"
  ensure_basic_deps

  echo -e "${WHITE}请选择安装模式:${RESET}"
  echo -e "  ${CYAN}1. 快速一键推荐安装 (自动分配无冲突端口、开启 Reality + Argo)${RESET}"
  echo -e "  ${CYAN}2. 自定义参数交互安装 (逐项定制协议端口、伪装站点、密码等)${RESET}"
  echo -e "  ${CYAN}0. 取消安装${RESET}"
  read -p "请输入选项 [默认 1]: " inst_mode
  inst_mode="${inst_mode:-1}"

  if [ "$inst_mode" = "0" ]; then
    return
  fi

  local in_uuid in_name in_disable_argo in_argo_domain in_argo_auth in_pref_host
  local in_reality_port in_reality_domain in_ss_port in_ss_pass in_s5_port in_trojan_port

  in_uuid="$(get_uuid)"
  in_name="xray"

  if [ "$inst_mode" = "1" ]; then
    log "正在自动生成优选参数与探测空闲端口..."
    rm -f "$USED_PORTS_FILE"
    in_reality_port="$(get_free_port 443)"
    in_ss_port="$(get_free_port 8388)"
    in_s5_port="$(get_free_port 1080)"
    in_trojan_port=""
    in_disable_argo="false"
    in_argo_domain=""
    in_argo_auth=""
    in_reality_domain="www.iij.ad.jp"
    in_pref_host="www.visa.com.tw"
    in_ss_pass="$(openssl rand -base64 16 2>/dev/null || echo "WnJ5UGFzc3dvcmQxMjM0")"
  else
    echo ""
    echo -e "${YELLOW}--- 基础参数设置 ---${RESET}"
    read -p "用户 UUID [留空自动生成: ${in_uuid}]: " custom_u
    [ -n "$custom_u" ] && in_uuid="$custom_u"
    read -p "节点名称前缀 [留空默认 xray]: " custom_n
    [ -n "$custom_n" ] && in_name="$custom_n"

    echo ""
    echo -e "${YELLOW}--- Cloudflare Argo 穿透设置 ---${RESET}"
    read -p "是否启用 Argo 穿透？[Y/n，默认 Y]: " argo_c
    case "$argo_c" in
      n|N) in_disable_argo="true" ;;
      *)
        in_disable_argo="false"
        read -p "Argo 固定域名 (留空使用自动分配的临时隧道): " in_argo_domain
        if [ -n "$in_argo_domain" ]; then
          read -p "Argo Tunnel Token: " in_argo_auth
        fi
        read -p "Cloudflare 优选域名/IP [默认 www.visa.com.tw]: " in_pref_host
        in_pref_host="${in_pref_host:-www.visa.com.tw}"
        ;;
    esac

    echo ""
    echo -e "${YELLOW}--- 直连协议端口分配 (留空则不开启) ---${RESET}"
    rm -f "$USED_PORTS_FILE"
    local rec_r rec_ss rec_s5
    rec_r="$(get_free_port 443)"
    rec_ss="$(get_free_port 8388)"
    rec_s5="$(get_free_port 1080)"

    read -p "VLESS-Reality 端口 [推荐 ${rec_r}，留空关闭]: " in_reality_port
    if [ -n "$in_reality_port" ]; then
      read -p "Reality 伪装域名 [推荐 www.iij.ad.jp]: " in_reality_domain
      in_reality_domain="${in_reality_domain:-www.iij.ad.jp}"
    fi

    read -p "Shadowsocks 2022 端口 [推荐 ${rec_ss}，留空关闭]: " in_ss_port
    if [ -n "$in_ss_port" ]; then
      read -p "SS 密码 (留空随机生成): " in_ss_pass
      [ -z "$in_ss_pass" ] && in_ss_pass="$(openssl rand -base64 16 2>/dev/null || echo "WnJ5UGFzc3dvcmQxMjM0")"
    fi

    read -p "SOCKS5 端口 [推荐 ${rec_s5}，留空关闭]: " in_s5_port
    read -p "Trojan-TCP 端口 [留空关闭]: " in_trojan_port
  fi

  # 保存配置
  set_val UUID "$in_uuid"
  set_val NAME "$in_name"
  set_val DISABLE_ARGO "${in_disable_argo:-false}"
  set_val ARGO_DOMAIN "${in_argo_domain:-}"
  set_val ARGO_AUTH "${in_argo_auth:-}"
  set_val CF_PREFER_HOST "${in_pref_host:-www.visa.com.tw}"

  set_val REALITY_PORT "${in_reality_port:-}"
  set_val REALITY_DOMAIN "${in_reality_domain:-www.iij.ad.jp}"
  set_val SS_PORT "${in_ss_port:-}"
  set_val SS_PASS "${in_ss_pass:-}"
  set_val S5_PORT "${in_s5_port:-}"
  set_val TROJAN_PORT "${in_trojan_port:-}"

  log "正在准备组件与二进制核心..."
  ensure_binaries
  setup_systemd
  setup_shortcuts

  log "正在启动 Xray 服务..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$SVC_NAME"
  else
    do_stop
    nohup "$0" run >/dev/null 2>&1 &
  fi

  sleep 3
  generate_sub
  log "恭喜！Xray Universal Proxy Engine 部署成功！"
  show_sub
}

# ── 18. 日志查看器 (do_log) ──────────────────────────────────────────────────
do_log() {
  clear
  echo -e "${GREEN}==================== 实时运行日志查看 ====================${RESET}"
  echo -e "${WHITE}1. Xray 核心运行日志${RESET}"
  echo -e "${WHITE}2. Cloudflare Argo 穿透隧道日志${RESET}"
  echo -e "${WHITE}3. Komari 探针监控日志${RESET}"
  echo -e "${WHITE}4. turn2socks (TURN 转接) 日志${RESET}"
  echo -e "${WHITE}0. 返回上一级菜单${RESET}"
  echo -e "${GREEN}----------------------------------------------------------${RESET}"
  read -p "请选择日志项: " log_c
  case "$log_c" in
    1)
      clear
      echo -e "${GREEN}=== Xray 核心日志 (Ctrl+C 退出追踪) ===${RESET}"
      if [ -f "$LOG_FILE" ]; then
        tail -n 60 -f "$LOG_FILE"
      else
        warn "暂无核心日志文件"
        press_any_key
      fi
      ;;
    2)
      clear
      echo -e "${GREEN}=== Argo 隧道日志 (Ctrl+C 退出追踪) ===${RESET}"
      if [ -f "$CF_LOG" ]; then
        tail -n 60 -f "$CF_LOG"
      else
        warn "暂无隧道日志文件"
        press_any_key
      fi
      ;;
    3)
      clear
      echo -e "${GREEN}=== Komari 探针日志 (Ctrl+C 退出追踪) ===${RESET}"
      if [ -f "$KM_LOG" ]; then
        tail -n 60 -f "$KM_LOG"
      else
        warn "暂无探针日志文件"
        press_any_key
      fi
      ;;
    4)
      clear
      echo -e "${GREEN}=== turn2socks 转接日志 (Ctrl+C 退出追踪) ===${RESET}"
      if [ -f "$TURN2SOCKS_LOG" ]; then
        tail -n 60 -f "$TURN2SOCKS_LOG"
      else
        warn "暂无 turn2socks 日志文件"
        press_any_key
      fi
      ;;
    *) return ;;
  esac
}

# ── 19. 节点订阅与配置多端展示 (show_sub) ─────────────────────────────────────
show_sub() {
  while true; do
    clear
    echo -e "${GREEN}==================== 节点订阅与客户端配置 ====================${RESET}"
    if [ ! -f "$SUB_FILE" ]; then
      warn "尚未生成订阅文件，请先启动 Xray 服务"
      press_any_key
      return
    fi

    echo -e "${GRAY}已激活协议矩阵:${RESET}"
    [ -n "$(get_val REALITY_PORT)" ] && echo -e "  ${GREEN}✓ VLESS-Reality${RESET} (Vision 极速流控, 端口: $(get_val REALITY_PORT))"
    [ -n "$(get_val SS_PORT)" ]      && echo -e "  ${GREEN}✓ Shadowsocks 2022${RESET} (blake3-aes-128-gcm, 端口: $(get_val SS_PORT))"
    [ -n "$(get_val S5_PORT)" ]      && echo -e "  ${GREEN}✓ Socks5${RESET} (端口: $(get_val S5_PORT))"
    [ -n "$(get_val TROJAN_PORT)" ]  && echo -e "  ${GREEN}✓ Trojan-TCP${RESET} (端口: $(get_val TROJAN_PORT))"
    if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
      echo -e "  ${GREEN}✓ VLESS-xhttp${RESET} (Argo SplitHTTP 现代流传输)"
      echo -e "  ${GREEN}✓ VLESS-WS${RESET}   (Argo WebSocket CDN 穿透)"
      echo -e "  ${GREEN}✓ VMess-WS${RESET}   (Argo WebSocket CDN 穿透)"
      echo -e "  ${GREEN}✓ Trojan-WS${RESET}  (Argo WebSocket CDN 穿透)"
    fi

    echo -e "${GREEN}--------------------------------------------------------------${RESET}"
    echo -e "${WHITE}1. 查看明文节点链接清单 (直连 & Argo)${RESET}"
    echo -e "${WHITE}2. 查看 Base64 订阅文本 (兼容 V2rayN / Shadowrocket)${RESET}"
    echo -e "${WHITE}3. 查看 Clash Meta (Mihomo) 完整规则配置 YAML${RESET}"
    echo -e "${WHITE}4. 保存全部订阅配置至文本文件${RESET}"
    echo -e "${WHITE}0. 返回主菜单${RESET}"
    echo -e "${GREEN}--------------------------------------------------------------${RESET}"
    read -p "请输入选项: " s_opt
    case "$s_opt" in
      1)
        clear
        echo -e "${GREEN}=== 明文节点链接 (直接导入客户端) ===${RESET}\n"
        [ -f "$SUB_RAW_FILE" ] && cat "$SUB_RAW_FILE"
        press_any_key
        ;;
      2)
        clear
        echo -e "${GREEN}=== Base64 订阅内容 (复制整段内容) ===${RESET}\n"
        [ -f "$SUB_FILE" ] && cat "$SUB_FILE"
        echo -e "\n"
        press_any_key
        ;;
      3)
        clear
        echo -e "${GREEN}=== Clash Meta (Mihomo) 完整配置 ===${RESET}\n"
        [ -f "$CLASH_META_FILE" ] && cat "$CLASH_META_FILE"
        press_any_key
        ;;
      4)
        local out_dump="$APP_DIR/all_sub_export.txt"
        {
          echo "==================== Xray 节点订阅明细 ===================="
          [ -f "$SUB_RAW_FILE" ] && cat "$SUB_RAW_FILE"
          echo -e "\n==================== Base64 订阅 ===================="
          [ -f "$SUB_FILE" ] && cat "$SUB_FILE"
          echo -e "\n==================== Clash Meta 配置 ===================="
          [ -f "$CLASH_META_FILE" ] && cat "$CLASH_META_FILE"
        } > "$out_dump"
        log "已导出完整订阅配置文件至: ${CYAN}${out_dump}${RESET}"
        press_any_key
        ;;
      0) return ;;
    esac
  done
}

# ── 20. 参数与协议精细化管理菜单 (menu_config) ────────────────────────────────
menu_config() {
  while true; do
    clear
    echo -e "${GREEN}==================== 详细参数与协议管理 ====================${RESET}"
    echo -e "${WHITE}1. 用户 UUID:        ${CYAN}$(get_val UUID)${RESET}"
    echo -e "${WHITE}2. VLESS-Reality:   ${CYAN}端口: $(get_val REALITY_PORT:-未启用) | 伪装站点: $(get_val REALITY_DOMAIN:-www.iij.ad.jp)${RESET}"
    echo -e "${WHITE}3. Shadowsocks 2022: ${CYAN}端口: $(get_val SS_PORT:-未启用)${RESET}"
    echo -e "${WHITE}4. Socks5 协议:      ${CYAN}端口: $(get_val S5_PORT:-未启用)${RESET}"
    echo -e "${WHITE}5. Trojan-TCP:       ${CYAN}端口: $(get_val TROJAN_PORT:-未启用)${RESET}"
    echo -e "${WHITE}6. Argo 穿透隧道:    ${CYAN}域名: $(get_val ARGO_DOMAIN:-临时隧道) | 优选: $(get_val CF_PREFER_HOST:-www.visa.com.tw)${RESET}"
    echo -e "${WHITE}7. Komari 探针监控:  ${CYAN}$(get_val KOMARI_DOMAIN:-未配置)${RESET}"
    echo -e "${WHITE}8. 全局连接 IP/域名: ${CYAN}$(get_val SERVER_DOMAIN:-$(get_public_ip))${RESET}"
    echo -e "${WHITE}0. 保存并应用重启${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"
    read -p "请选择修改项: " c_opt
    case "$c_opt" in
      1)
        read -p "请输入新 UUID [留空自动生成]: " new_u
        [ -z "$new_u" ] && new_u="$(get_uuid)"
        set_val UUID "$new_u"
        echo "$new_u" > "$UUID_FILE"
        log "UUID 已更新"
        sleep 1
        ;;
      2)
        read -p "VLESS-Reality 端口 [留空关闭]: " new_rp
        set_val REALITY_PORT "$new_rp"
        if [ -n "$new_rp" ]; then
          read -p "Reality 伪装域名 [默认 www.iij.ad.jp]: " new_rd
          set_val REALITY_DOMAIN "${new_rd:-www.iij.ad.jp}"
          rm -f "$REALITY_KEY_FILE"
        fi
        log "Reality 配置已更新"
        sleep 1
        ;;
      3)
        read -p "Shadowsocks 2022 端口 [留空关闭]: " new_sp
        set_val SS_PORT "$new_sp"
        if [ -n "$new_sp" ]; then
          read -p "Shadowsocks 密码 [留空随机生成]: " new_pass
          [ -z "$new_pass" ] && new_pass="$(openssl rand -base64 16 2>/dev/null || echo "WnJ5UGFzc3dvcmQxMjM0")"
          set_val SS_PASS "$new_pass"
        fi
        log "Shadowsocks 2022 配置已更新"
        sleep 1
        ;;
      4)
        read -p "Socks5 端口 [留空关闭]: " new_s5
        set_val S5_PORT "$new_s5"
        log "Socks5 配置已更新"
        sleep 1
        ;;
      5)
        read -p "Trojan-TCP 端口 [留空关闭]: " new_tp
        set_val TROJAN_PORT "$new_tp"
        log "Trojan 配置已更新"
        sleep 1
        ;;
      6)
        read -p "是否禁用 Argo 隧道？[y/N，默认 N]: " dis_a
        case "$dis_a" in
          y|Y) set_val DISABLE_ARGO "true" ;;
          *)
            set_val DISABLE_ARGO "false"
            read -p "Argo 固定域名 [留空使用临时隧道]: " new_ad
            set_val ARGO_DOMAIN "$new_ad"
            if [ -n "$new_ad" ]; then
              read -p "Argo Token: " new_at
              set_val ARGO_AUTH "$new_at"
            fi
            read -p "Cloudflare 优选域名/IP [默认 www.visa.com.tw]: " new_pref
            set_val CF_PREFER_HOST "${new_pref:-www.visa.com.tw}"
            ;;
        esac
        log "Argo 隧道设置已更新"
        sleep 1
        ;;
      7)
        read -p "Komari 服务端域名 [留空关闭]: " new_kd
        set_val KOMARI_DOMAIN "$new_kd"
        if [ -n "$new_kd" ]; then
          read -p "Komari 探针 Token: " new_kt
          set_val KOMARI_TOKEN "$new_kt"
        fi
        log "Komari 探针配置已更新"
        sleep 1
        ;;
      8)
        read -p "自定义连接域名/IP [留空恢复自动探测]: " new_dom
        set_val SERVER_DOMAIN "$new_dom"
        log "连接域名已更新"
        sleep 1
        ;;
      0)
        do_restart
        return
        ;;
    esac
  done
}

# ── 21. 主交互式运维控制面板 (do_menu) ─────────────────────────────────────────
do_menu() {
  while true; do
    clear
    local st_desc="${RED}● 未运行${RESET}"
    local x_pid=""
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      x_pid="$(cat "$PID_FILE")"
      st_desc="${GREEN}● 运行中 (PID: ${x_pid})${RESET}"
    elif pgrep -f "$XRAY_BIN" >/dev/null 2>&1; then
      st_desc="${GREEN}● 运行中${RESET}"
    fi

    local x_ver="未安装"
    [ -x "$XRAY_BIN" ] && x_ver="$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
    local pub_ip
    pub_ip="$(get_public_ip)"

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${WHITE}          Xray 跨平台 VPS 一体化智能管理运维系统          ${RESET}"
    echo -e "${GRAY}系统状态: ${st_desc} | 核心版本: ${CYAN}${x_ver}${RESET}"
    echo -e "${GRAY}公网 IP:  ${CYAN}${pub_ip}${RESET} | 目录: ${GRAY}${APP_DIR}${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${WHITE} 1. 查看节点订阅 (Base64 / 明文链接 / Clash Meta / JSON 导出)${RESET}"
    echo -e "${WHITE} 2. 启动 Xray 代理服务${RESET}"
    echo -e "${WHITE} 3. 停止 Xray 代理服务${RESET}"
    echo -e "${WHITE} 4. 重启 Xray 代理服务${RESET}"
    echo -e "${GREEN}----------------------------------------------------------------${RESET}"
    echo -e "${WHITE} 5. 交互式重新安装 / 初始化向导${RESET}"
    echo -e "${WHITE} 6. 修改配置 (UUID / Reality / Shadowsocks / Socks5 / 端口)${RESET}"
    echo -e "${WHITE} 7. 出口设置 (Cloudflare WARP 原生出口 / 智能解锁流媒体与AI)${RESET}"
    echo -e "${WHITE} 8. 域名证书 (acme.sh 自动申请 / 证书导入 / 协议绑定)${RESET}"
    echo -e "${WHITE} 9. 查看运行日志 (Xray 核心 / Argo 隧道 / 探针日志)${RESET}"
    echo -e "${GREEN}----------------------------------------------------------------${RESET}"
    echo -e "${WHITE}10. 在线升级组件 (Xray 核心升级 / Cloudflared / 脚本自更新)${RESET}"
    echo -e "${WHITE}11. 彻底卸载清理 Xray 与全部环境数据${RESET}"
    echo -e "${WHITE} 0. 退出管理控制面板${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    read -p "请输入操作指令编号 [0-11]: " opt
    case "$opt" in
      1) show_sub ;;
      2)
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
          systemctl start "$SVC_NAME"
        else
          nohup "$0" run >/dev/null 2>&1 &
        fi
        log "服务已发起启动"
        sleep 2
        ;;
      3)
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
          systemctl stop "$SVC_NAME"
        else
          do_stop
        fi
        log "服务已停止"
        sleep 1
        ;;
      4)
        do_restart
        sleep 2
        ;;
      5) do_install ;;
      6) menu_config ;;
      7) menu_outbound ;;
      8) menu_domain_cert ;;
      9) do_log ;;
      10) menu_update ;;
      11)
        read -p "确定要彻底删除该项目与所有数据吗? [y/N]: " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          do_stop
          systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
          rm -f "/etc/systemd/system/${SVC_NAME}.service" /usr/local/bin/xray*
          rm -rf "$APP_DIR" "$BIN_DIR"
          log "已彻底清理卸载"
          exit 0
        fi
        ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

# ── 22. 命令行与快捷指令入口分发 ───────────────────────────────────────────────
setup_shortcuts

case "${1:-}" in
  run)     do_run ;;
  stop)    do_stop ;;
  restart) do_restart ;;
  sub)     show_sub ;;
  log)     do_log ;;
  install) do_install ;;
  update)  menu_update ;;
  del)
    do_stop
    systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SVC_NAME}.service" /usr/local/bin/xray*
    rm -rf "$APP_DIR" "$BIN_DIR"
    log "已卸载"
    ;;
  *)
    case "$(basename "$0")" in
      xray-sub) show_sub ;;
      xray-log) do_log ;;
      xray-del)
        do_stop
        systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SVC_NAME}.service" /usr/local/bin/xray*
        rm -rf "$APP_DIR" "$BIN_DIR"
        log "已卸载"
        ;;
      *)
        do_menu
        ;;
    esac
    ;;
esac
