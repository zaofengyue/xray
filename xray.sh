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
umask 077

# 当脚本通过 curl | bash 等管道执行且非后台守护 (run) 模式时，若有可用终端则重定向 stdin 以保障交互正常
if [ "${1:-}" != "run" ] && [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
  exec </dev/tty
fi

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

log()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[XRAY]${NC} $*" >&2; }

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
TG_S5_FILE="$APP_DIR/tg_socks.txt"

LOG_FILE="$APP_DIR/run.log"
CF_LOG="$APP_DIR/cf.log"
KM_LOG="$APP_DIR/komari.log"
TURN2SOCKS_LOG="$APP_DIR/turn2socks.log"
PID_FILE="$APP_DIR/xray.pid"
RUN_PID="$APP_DIR/run.pid"
CF_PID="$APP_DIR/cf.pid"
KM_PID="$APP_DIR/km.pid"
TURN2SOCKS_PID="$APP_DIR/turn2socks.pid"
SVC_NAME="xray"

# 持久化受保护的二进制目录（不使用重启即丢的 /tmp）
BIN_DIR="$APP_DIR/bin"
XRAY_BIN="$BIN_DIR/xray"
CF_BIN="$BIN_DIR/cloudflared"
KM_BIN="$BIN_DIR/komari-agent"
TURN2SOCKS_BIN="$BIN_DIR/turn2socks"
ACME_HOME="$STATE_DIR/acme"

mkdir -p "$APP_DIR" "$STATE_DIR" "$BIN_DIR" "$DOMAIN_CERT_DIR" 2>/dev/null || true
chmod 700 "$APP_DIR" "$STATE_DIR" "$BIN_DIR" "$DOMAIN_CERT_DIR" 2>/dev/null || true
export XRAY_LOCATION_ASSET="$BIN_DIR"

# ── 4. 安全配置环境变量工具 ────────────────────────────────────────────────────
get_val() {
  local key="$1" def="${2:-}"
  if [ ! -f "$ENV_FILE" ]; then
    printf '%s' "$def"
    return 0
  fi
  local val
  val="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)"
  val="${val#\"}"
  val="${val%\"}"
  val="$(printf '%s' "$val" | tr -d '\r\n')"
  val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -n "$val" ]; then
    printf '%s' "$val"
  else
    printf '%s' "$def"
  fi
}

set_val() {
  local key="$1" val="${2:-}"
  mkdir -p "$APP_DIR"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  local tmp_f
  tmp_f="$(mktemp "${ENV_FILE}.tmp.XXXXXX" 2>/dev/null || echo "${ENV_FILE}.tmp")"
  grep -v "^${key}=" "$ENV_FILE" 2>/dev/null > "$tmp_f" || true
  printf '%s="%s"\n' "$key" "$val" >> "$tmp_f"
  mv -f "$tmp_f" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

escape_json() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

load_env() {
  [ -f "$ENV_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      '#'*|'') continue ;;
      UUID|NAME|PUBLIC_IP|CUSTOM_PUBLIC_IP|IP|PORT|SUB|ARGO_*|CF_*|REALITY_*|XHTTP_*|SS_*|S5_*|TROJAN_*|KOMARI_*|SERVER_DOMAIN|DISABLE_ARGO|USE_GHPROXY)
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        v="${v#\"}"
        v="${v%\"}"
        printf -v "$k" '%s' "$v"
        export "$k"
        ;;
      *) continue ;;
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

  # 1. 凡是具有系统级 IPv4 默认路由的主机，绝不判定为纯 IPv6，不挂载 NAT64
  local _has_v4=0
  if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null | grep -q default && _has_v4=1
  elif command -v route >/dev/null 2>&1; then
    route -n 2>/dev/null | grep -q '^0.0.0.0' && _has_v4=1
  fi
  [ "$_has_v4" = "1" ] && return 0

  # 2. 纯 IPv6 主机：若系统已有可用的 DNS64/NAT64 能直接连通纯 IPv4 站点，则无需临时挂载
  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 2 -m 3 https://api.github.com >/dev/null 2>&1 && return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=3 https://api.github.com >/dev/null 2>&1 && return 0
  fi

  local _rc="/etc/resolv.conf"
  [ -e "$_rc" ] || return 0
  [ -L "$_rc" ] && _rc="$(readlink -f "$_rc" 2>/dev/null || echo "/etc/resolv.conf")"
  [ -w "$_rc" ] || return 0

  local _n1="2a01:4f8:c2c:123f::1" _n2="2001:67c:2b0::4"
  if ! grep -q "$_n1" "$_rc" 2>/dev/null && ! grep -q "$_n2" "$_rc" 2>/dev/null; then
    cp -f "$_rc" /etc/resolv.conf.xray-orig 2>/dev/null || return 0
    trap 'nat64_restore_temp; exit 130' INT
    trap 'nat64_restore_temp; exit 143' TERM
    trap 'nat64_restore_temp; exit 129' HUP
    trap 'nat64_restore_temp' EXIT
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
_APT_UPDATED=0
try_install_pkg() {
  local _pkg="$1"
  [ "$(id -u)" = "0" ] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$_APT_UPDATED" = "0" ]; then
      apt-get update -qq -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 >/dev/null 2>&1 || true
      _APT_UPDATED=1
    fi
    apt-get install -y -qq -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 $_pkg >/dev/null 2>&1 || true
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
  local pkg_iproute="iproute2"
  local pkg_procps="procps"
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    pkg_iproute="iproute"
    pkg_procps="procps-ng"
  fi

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _missing="$_missing curl"
  command -v tar >/dev/null 2>&1 || _missing="$_missing tar"
  command -v unzip >/dev/null 2>&1 || _missing="$_missing unzip"
  command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
  command -v socat >/dev/null 2>&1 || _missing="$_missing socat"
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _missing="$_missing $pkg_iproute"
  command -v pgrep >/dev/null 2>&1 || _missing="$_missing $pkg_procps"
  command -v sha256sum >/dev/null 2>&1 || _missing="$_missing coreutils"

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
    x86_64|amd64)     echo "linux-amd64" ;;
    aarch64|arm64)    echo "linux-arm64" ;;
    armv7*|armhf|arm) echo "linux-arm" ;;
    i386|i686)        echo "linux-386" ;;
    *)                echo "linux-amd64" ;;
  esac
}

download_file() {
  local url="$1" dest="$2"
  nat64_enable_temp
  local success=1
  local mirrors=("$url")
  if [[ "$url" =~ github.com ]] && [ "$(get_val USE_GHPROXY)" = "true" ]; then
    mirrors+=("https://ghproxy.net/${url}")
  fi

  local part="${dest}.part"
  rm -f "$part"

  for u in "${mirrors[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --retry 3 --connect-timeout 10 -m 300 "$u" -o "$part" 2>/dev/null && [ -s "$part" ]; then
        mv -f "$part" "$dest"
        success=0
        break
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q --tries=3 --connect-timeout=10 --timeout=300 "$u" -O "$part" 2>/dev/null && [ -s "$part" ]; then
        mv -f "$part" "$dest"
        success=0
        break
      fi
    fi
    rm -f "$part"
  done
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

is_valid_elf() {
  local f="$1"
  [ -s "$f" ] || return 1
  local magic
  magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "7f454c46" ]
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
  # 临时工作目录统一收敛在 700 权限的 $APP_DIR 内，杜绝 /tmp 下的 TOCTOU 竞争与可预测文件风险
  local work
  work="$(mktemp -d "$APP_DIR/.dl.XXXXXX" 2>/dev/null || echo "$APP_DIR/.dl_$$")"
  mkdir -p "$work" && chmod 700 "$work"
  local tmpzip="$work/xray.zip"
  local dgst_file="$work/xray.zip.dgst"
  local extract_tmp="$work/extracted"

  if ! download_file "$url" "$tmpzip"; then
    rm -rf "$work"
    warn "下载 Xray 失败: $url"
    return 1
  fi

  # 严格校验 SHA256 安全哈希，防范中间人攻击 (优先直连 GitHub 获取官方哈希防范第三方镜像篡改)
  local exp_sha=""
  if curl -fsSL --max-time 5 "${url}.dgst" -o "$dgst_file" 2>/dev/null; then
    exp_sha="$(awk -F'= ' '/SHA2-256/{print $2}' "$dgst_file" 2>/dev/null | tr -d '[:space:]')"
  elif download_file "${url}.dgst" "$dgst_file"; then
    warn "未能直连 GitHub 获取校验哈希，已回退至镜像源下载 .dgst（请注意第三方镜像供应链风险）"
    exp_sha="$(awk -F'= ' '/SHA2-256/{print $2}' "$dgst_file" 2>/dev/null | tr -d '[:space:]')"
  fi

  if [ -n "$exp_sha" ] && command -v sha256sum >/dev/null 2>&1; then
    local act_sha
    act_sha="$(sha256sum "$tmpzip" 2>/dev/null | awk '{print $1}')"
    if [ "$act_sha" != "$exp_sha" ]; then
      rm -rf "$work"
      warn "Xray 压缩包 SHA256 校验失败！(预期: $exp_sha, 实际: $act_sha)"
      return 1
    fi
    log "Xray 核心 SHA256 安全校验通过 (${act_sha:0:16}...)"
  else
    warn "未能获取 Xray 官方发布哈希或缺少 sha256sum 工具"
    if [ -t 0 ] && { : </dev/tty; } 2>/dev/null; then
      read -p "是否在无安全哈希校验下强行继续？[y/N]: " bypass_chk </dev/tty
      case "$bypass_chk" in
        y|Y) warn "已确认跳过 SHA256 完整性校验" ;;
        *)
          rm -rf "$work"
          warn "已终止未验证的二进制安装流程"
          return 1
          ;;
      esac
    else
      warn "非交互式环境下无安全哈希可供校验，为保障安全已终止安装"
      rm -rf "$work"
      return 1
    fi
  fi

  mkdir -p "$extract_tmp"
  if ! extract_zip "$tmpzip" "$extract_tmp" || [ ! -f "$extract_tmp/xray" ]; then
    rm -rf "$work"
    warn "解压 Xray 安装包失败或核心二进制缺失"
    return 1
  fi
  if ! is_valid_elf "$extract_tmp/xray"; then
    rm -rf "$work"
    warn "解压出的 Xray 二进制非合法 ELF 可执行文件"
    return 1
  fi
  chmod +x "$extract_tmp/xray"
  if ! "$extract_tmp/xray" version >/dev/null 2>&1; then
    rm -rf "$work"
    warn "解压出的 Xray 无法在当前系统架构执行"
    return 1
  fi
  mv -f "$extract_tmp/xray" "$XRAY_BIN"
  [ -f "$extract_tmp/geoip.dat" ] && mv -f "$extract_tmp/geoip.dat" "$BIN_DIR/"
  [ -f "$extract_tmp/geosite.dat" ] && mv -f "$extract_tmp/geosite.dat" "$BIN_DIR/"
  rm -rf "$work"
  chmod +x "$XRAY_BIN"
  log "Xray-core 部署就绪: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  return 0
}

download_cloudflared() {
  log "正在下载 cloudflared (Argo)..."
  local cfarch url
  cfarch="$(detect_cf_arch)"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${cfarch}"

  local work tmp_cf
  work="$(mktemp -d "$APP_DIR/.dl.XXXXXX" 2>/dev/null || echo "$APP_DIR/.dl_$$")"
  mkdir -p "$work" && chmod 700 "$work"
  tmp_cf="$work/cloudflared"

  if ! download_file "$url" "$tmp_cf"; then
    rm -rf "$work"
    warn "下载 cloudflared 失败"
    return 1
  fi

  if ! is_valid_elf "$tmp_cf"; then
    rm -rf "$work"
    warn "cloudflared 下载内容非有效 ELF 架构二进制"
    return 1
  fi

  chmod +x "$tmp_cf"
  local ver_out
  ver_out="$("$tmp_cf" --version 2>/dev/null | head -1)"
  if [[ "$ver_out" != *"cloudflared version"* ]]; then
    rm -rf "$work"
    warn "cloudflared 二进制自检失败 (输出异常或无法在当前架构运行)"
    return 1
  fi

  mv -f "$tmp_cf" "$CF_BIN"
  chmod +x "$CF_BIN"
  rm -rf "$work"
  log "Cloudflared 部署就绪: ${ver_out}"
  return 0
}

download_komari() {
  log "正在下载 komari-agent (探针)..."
  local kmarch url
  kmarch="$(detect_km_arch)"
  url="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${kmarch}"

  local work tmp_km
  work="$(mktemp -d "$APP_DIR/.dl.XXXXXX" 2>/dev/null || echo "$APP_DIR/.dl_$$")"
  mkdir -p "$work" && chmod 700 "$work"
  tmp_km="$work/komari-agent"

  if ! download_file "$url" "$tmp_km"; then
    rm -rf "$work"
    warn "下载 komari-agent 失败"
    return 1
  fi

  if ! is_valid_elf "$tmp_km"; then
    rm -rf "$work"
    warn "komari-agent 下载内容非有效 ELF 架构二进制"
    return 1
  fi

  chmod +x "$tmp_km"
  if ! "$tmp_km" --help >/dev/null 2>&1 && ! "$tmp_km" -h >/dev/null 2>&1 && ! "$tmp_km" -v >/dev/null 2>&1; then
    rm -rf "$work"
    warn "komari-agent 二进制自检失败，无法在当前系统执行"
    return 1
  fi

  mv -f "$tmp_km" "$KM_BIN"
  chmod +x "$KM_BIN"
  rm -rf "$work"
  log "Komari-agent 部署就绪"
  return 0
}

download_turn2socks() {
  local t2s_arch="amd64" exp_t2s_sha=""
  case "$(uname -m)" in
    aarch64|arm64)
      t2s_arch="arm64"
      exp_t2s_sha="9ea50c94d2ef65c5aa4d85cd4acf0e1501a358ebab64fb726555421e916394d8"
      ;;
    *)
      t2s_arch="amd64"
      exp_t2s_sha="1d65aaf21837ebcd8dae9ed08294a4c21547b50a9b4afd63cd1a0329da42847e"
      ;;
  esac

  if [ -x "$TURN2SOCKS_BIN" ]; then
    return 0
  fi

  # 1. 优先检测本地仓库源码及 Go 编译环境
  local local_src=""
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for d in "$script_dir/turn2socks" "$APP_DIR/turn2socks"; do
    if [ -f "$d/main.go" ]; then
      local_src="$d"
      break
    fi
  done

  # 1.1 若本地有预置的同架构二进制，需经 ELF 完整性与安全哈希核验后复用
  for b in "$script_dir/turn2socks-linux-${t2s_arch}" "$script_dir/bin/turn2socks" "$script_dir/turn2socks"; do
    if [ -x "$b" ] && [ ! -d "$b" ] && is_valid_elf "$b"; then
      if [ -n "$exp_t2s_sha" ] && command -v sha256sum >/dev/null 2>&1; then
        local b_sha
        b_sha="$(sha256sum "$b" 2>/dev/null | awk '{print $1}')"
        if [ "$b_sha" != "$exp_t2s_sha" ]; then
          continue
        fi
      fi
      cp -f "$b" "$TURN2SOCKS_BIN"
      chmod +x "$TURN2SOCKS_BIN"
      log "turn2socks 组件已就绪 (复用哈希核验通过的本地预置: $b)"
      return 0
    fi
  done

  # 1.2 若检测到本地源码且具备 go 编译器，直接本地原生编译
  if [ -n "$local_src" ] && command -v go >/dev/null 2>&1; then
    log "检测到本地项目仓库源码及 Go 编译环境，正在就地编译 turn2socks..."
    if (cd "$local_src" && CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o "$TURN2SOCKS_BIN" .) >/dev/null 2>&1; then
      chmod +x "$TURN2SOCKS_BIN"
      log "turn2socks 本地源码编译成功"
      return 0
    fi
  fi

  # 2. 无法本地编译时，从本仓库官方 Release 获取配套二进制
  log "正在部署本仓库官方配套组件 turn2socks..."
  local primary_url="https://github.com/zaofengyue/singbox/releases/download/latest/turn2socks-linux-${t2s_arch}"
  local fallback_url="https://github.com/zaofengyue/xray/releases/download/latest/turn2socks-linux-${t2s_arch}"

  local work
  work="$(mktemp -d "$APP_DIR/.dl.XXXXXX" 2>/dev/null || echo "$APP_DIR/.dl_$$")"
  mkdir -p "$work" && chmod 700 "$work"
  local tmp_t2s="$work/turn2socks"
  local used_url=""

  if download_file "$primary_url" "$tmp_t2s"; then
    used_url="$primary_url"
  elif download_file "$fallback_url" "$tmp_t2s"; then
    used_url="$fallback_url"
  fi

  if [ -n "$used_url" ] && [ -s "$tmp_t2s" ]; then
    # 优先在线拉取 Release 配套 .sha256 文件进行严格校验；若获取失败则自动降级使用预置哈希保底
    local sha_url="${used_url}.sha256"
    local dgst_file="$work/t2s.sha256"
    if curl -fsSL --max-time 5 "$sha_url" -o "$dgst_file" 2>/dev/null || download_file "$sha_url" "$dgst_file"; then
      local dyn_sha
      dyn_sha="$(awk '{print $1}' "$dgst_file" 2>/dev/null | tr -d '[:space:]')"
      [ -n "$dyn_sha" ] && exp_t2s_sha="$dyn_sha"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      local act_t2s_sha
      act_t2s_sha="$(sha256sum "$tmp_t2s" 2>/dev/null | awk '{print $1}')"
      if [ -n "$exp_t2s_sha" ] && [ "$act_t2s_sha" != "$exp_t2s_sha" ]; then
        rm -rf "$work"
        warn "turn2socks SHA256 校验失败 (安全哈希不匹配)"
        return 1
      fi
      log "turn2socks SHA256 校验通过 (${act_t2s_sha:0:16}...)"
    fi
    if ! is_valid_elf "$tmp_t2s"; then
      rm -rf "$work"
      warn "turn2socks 二进制格式异常 (非合法 ELF)"
      return 1
    fi
    mv -f "$tmp_t2s" "$TURN2SOCKS_BIN"
    chmod +x "$TURN2SOCKS_BIN"
    rm -rf "$work"
    log "turn2socks 部署就绪"
    return 0
  fi
  rm -rf "$work"
  warn "turn2socks 下载或编译失败"
  return 1
}

stop_turn2socks() {
  stop_pid_file "$TURN2SOCKS_PID" "$TURN2SOCKS_BIN"
  pkill -f "$BIN_DIR/turn2socks" 2>/dev/null || true
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
  local my_pid="" t2s_pid=""
  [ -f "$PID_FILE" ] && my_pid="$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -f "$TURN2SOCKS_PID" ] && t2s_pid="$(cat "$TURN2SOCKS_PID" 2>/dev/null | tr -d '[:space:]')"
  if command -v ss >/dev/null 2>&1; then
    local match
    match="$(ss -ltnp 2>/dev/null | grep ":${p} ")"
    if [ -n "$match" ]; then
      if [ -n "$my_pid" ] && echo "$match" | grep -q "pid=${my_pid},"; then
        return 1
      fi
      if [ -n "$t2s_pid" ] && echo "$match" | grep -q "pid=${t2s_pid},"; then
        return 1
      fi
      return 0
    fi
    match="$(ss -lunp 2>/dev/null | grep ":${p} ")"
    if [ -n "$match" ]; then
      if [ -n "$my_pid" ] && echo "$match" | grep -q "pid=${my_pid},"; then
        return 1
      fi
      if [ -n "$t2s_pid" ] && echo "$match" | grep -q "pid=${t2s_pid},"; then
        return 1
      fi
      return 0
    fi
  elif command -v netstat >/dev/null 2>&1; then
    local n_match
    n_match="$(netstat -ltnp 2>/dev/null | grep ":${p} ")"
    if [ -n "$n_match" ]; then
      if [ -n "$my_pid" ] && echo "$n_match" | grep -q "[ /]${my_pid}/"; then
        return 1
      fi
      if [ -n "$t2s_pid" ] && echo "$n_match" | grep -q "[ /]${t2s_pid}/"; then
        return 1
      fi
      return 0
    fi
    n_match="$(netstat -lunp 2>/dev/null | grep ":${p} ")"
    if [ -n "$n_match" ]; then
      if [ -n "$my_pid" ] && echo "$n_match" | grep -q "[ /]${my_pid}/"; then
        return 1
      fi
      if [ -n "$t2s_pid" ] && echo "$n_match" | grep -q "[ /]${t2s_pid}/"; then
        return 1
      fi
      return 0
    fi
  fi
  return 1
}

is_reserved_port() {
  case "$1" in
    8001|10000|10001|10002|10003|10808) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_port_or_empty() {
  local p="$1"
  [ -z "$p" ] && return 0
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

prompt_port() {
  local prompt_text="$1" default_val="${2:-}" exclude_ports="${3:-}"
  local res
  while true; do
    read -p "$prompt_text" res
    res="${res:-$default_val}"
    [ "$res" = "0" ] || [ "$res" = "未启用" ] && { echo ""; return 0; }
    if ! is_valid_port_or_empty "$res"; then
      warn "端口格式错误，必须为 1-65535 的数字 (填 0 关闭)"
      continue
    fi
    if is_reserved_port "$res"; then
      warn "端口 $res 为脚本内部保留端口 (8001, 10000-10003, 10808)，请换用其他端口"
      continue
    fi
    if [ -n "$exclude_ports" ] && [[ " $exclude_ports " =~ " $res " ]]; then
      warn "端口 $res 已被其他协议入站选用，请勿重复使用"
      continue
    fi
    if port_in_use_os "$res"; then
      warn "端口 $res 已被系统其他进程占用，请换用其他端口"
      continue
    fi
    echo "$res"
    return 0
  done
}

prompt_remote_port() {
  local prompt_text="$1" default_val="${2:-}"
  local res
  while true; do
    read -p "$prompt_text" res
    res="${res:-$default_val}"
    [ -z "$res" ] || [ "$res" = "0" ] && { echo ""; return 0; }
    if is_valid_port_or_empty "$res"; then
      echo "$res"
      return 0
    fi
    warn "端口格式错误，必须为 1-65535 的有效端口数字 (填 0 或留空取消)"
  done
}

prompt_relay_port() {
  local prompt_text="$1" default_val="${2:-10808}"
  local res
  while true; do
    read -p "$prompt_text" res
    res="${res:-$default_val}"
    if ! is_valid_port_or_empty "$res" || [ -z "$res" ]; then
      warn "端口格式错误，必须为 1-65535 的有效端口数字"
      continue
    fi
    case "$res" in
      8001|10000|10001|10002|10003)
        warn "端口 $res 为内部分流端口 (8001, 10000-10003)，不可用作转接监听"
        continue
        ;;
    esac
    echo "$res"
    return 0
  done
}

port_ok() {
  local p="$1"
  [ -z "$p" ] && return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -lt 1 ] || [ "$p" -gt 65535 ] && return 1
  # 内部保留端口（Argo 分流 8001、内部入站 10000-10003、本地客户端代理 10808-10809）严禁占用
  is_reserved_port "$p" && return 1
  [ -f "$USED_PORTS_FILE" ] && grep -qx "$p" "$USED_PORTS_FILE" 2>/dev/null && return 1
  port_in_use_os "$p" && return 1
  echo "$p" >> "$USED_PORTS_FILE"
  return 0
}

get_random_high_port() {
  local _tries=0 _rand
  while [ $_tries -lt 60 ]; do
    _rand=$(( (RANDOM % 48000) + 12000 ))
    if port_ok "$_rand"; then
      echo "$_rand"
      return 0
    fi
    _tries=$((_tries + 1))
  done
  # 极端情况兜底：顺序扫描 12000-65000，确保必须通过 port_ok 校验
  local p
  for ((p=12000; p<=65000; p++)); do
    if port_ok "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "23456"
}

get_free_port() {
  local p="${1:-}"
  if [ -n "$p" ] && port_ok "$p"; then
    echo "$p"
    return
  fi
  get_random_high_port
}

open_firewall_port() {
  local entry="$1" proto="${2:-}"
  [ -z "$entry" ] && return 0
  local p
  if [[ "$entry" =~ ^([0-9]+)/(tcp|udp|both)$ ]]; then
    p="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[2]}"
  else
    p="$entry"
    proto="${proto:-both}"
  fi
  [ "$p" = "0" ] && return 0
  [ "$(id -u)" = "0" ] || return 0

  # 1. UFW 防火墙
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    case "$proto" in
      tcp)  ufw allow "$p"/tcp >/dev/null 2>&1 || true ;;
      udp)  ufw allow "$p"/udp >/dev/null 2>&1 || true ;;
      *)    ufw allow "$p"/tcp >/dev/null 2>&1 || true; ufw allow "$p"/udp >/dev/null 2>&1 || true ;;
    esac
  fi

  # 2. firewalld 防火墙
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    case "$proto" in
      tcp)  firewall-cmd --add-port="$p"/tcp --permanent >/dev/null 2>&1 || true ;;
      udp)  firewall-cmd --add-port="$p"/udp --permanent >/dev/null 2>&1 || true ;;
      *)    firewall-cmd --add-port="$p"/tcp --permanent >/dev/null 2>&1 || true; firewall-cmd --add-port="$p"/udp --permanent >/dev/null 2>&1 || true ;;
    esac
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  # 3. 原生 iptables / ip6tables (适配 Oracle Linux 等自带 strict DROP 拦截规则的云主机镜像)
  if command -v iptables >/dev/null 2>&1; then
    case "$proto" in
      tcp)  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      udp)  iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      *)    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
    esac
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    case "$proto" in
      tcp)  ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      udp)  ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      *)    ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
    esac
  fi
  persist_firewall_rules
}

persist_firewall_rules() {
  [ "$(id -u)" = "0" ] || return 0
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif command -v iptables-save >/dev/null 2>&1; then
    if [ -d /etc/iptables ]; then
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      [ -f /etc/iptables/rules.v6 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
  fi
}

close_firewall_port() {
  local entry="$1" proto="${2:-}"
  [ -z "$entry" ] && return 0
  local p
  if [[ "$entry" =~ ^([0-9]+)/(tcp|udp|both)$ ]]; then
    p="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[2]}"
  else
    p="$entry"
    proto="${proto:-both}"
  fi
  [ "$p" = "0" ] && return 0
  [ "$(id -u)" = "0" ] || return 0

  # 1. UFW 防火墙
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    case "$proto" in
      tcp)  ufw delete allow "$p"/tcp >/dev/null 2>&1 || true ;;
      udp)  ufw delete allow "$p"/udp >/dev/null 2>&1 || true ;;
      *)    ufw delete allow "$p"/tcp >/dev/null 2>&1 || true; ufw delete allow "$p"/udp >/dev/null 2>&1 || true ;;
    esac
  fi

  # 2. firewalld 防火墙
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    case "$proto" in
      tcp)  firewall-cmd --remove-port="$p"/tcp --permanent >/dev/null 2>&1 || true ;;
      udp)  firewall-cmd --remove-port="$p"/udp --permanent >/dev/null 2>&1 || true ;;
      *)    firewall-cmd --remove-port="$p"/tcp --permanent >/dev/null 2>&1 || true; firewall-cmd --remove-port="$p"/udp --permanent >/dev/null 2>&1 || true ;;
    esac
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  # 3. 原生 iptables / ip6tables
  if command -v iptables >/dev/null 2>&1; then
    case "$proto" in
      tcp)  iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      udp)  iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      *)    iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
    esac
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    case "$proto" in
      tcp)  ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      udp)  ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
      *)    ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true ;;
    esac
  fi
  persist_firewall_rules
}

is_valid_ip() {
  local test_ip="$1"
  [ -z "$test_ip" ] && return 1
  if [[ "$test_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    read -r i1 i2 i3 i4 <<< "$test_ip"
    [ "$i1" -le 255 ] && [ "$i2" -le 255 ] && [ "$i3" -le 255 ] && [ "$i4" -le 255 ] && return 0
  fi
  if [[ "$test_ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$test_ip" =~ : ]] && [[ ! "$test_ip" =~ ::: ]]; then
    return 0
  fi
  return 1
}

get_public_ip() {
  local custom_ip
  custom_ip="$(get_val CUSTOM_PUBLIC_IP)"
  [ -z "$custom_ip" ] && custom_ip="$(get_val IP)"
  if [ -n "$custom_ip" ] && is_valid_ip "$custom_ip"; then
    echo "$custom_ip"
    return
  fi

  local cache_file="$STATE_DIR/.cached_ip"
  if [ -f "$cache_file" ]; then
    local c_ip c_time now
    read -r c_ip c_time < "$cache_file" 2>/dev/null || true
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$c_ip" ] && is_valid_ip "$c_ip" && [ -n "$c_time" ] && [ $((now - c_time)) -lt 43200 ]; then
      echo "$c_ip"
      return
    fi
  fi

  local ip=""
  local has_v4=0
  if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null | grep -q default && has_v4=1
  elif command -v route >/dev/null 2>&1; then
    route -n 2>/dev/null | grep -q '^0.0.0.0' && has_v4=1
  fi

  if [ "$has_v4" = "1" ]; then
    ip="$(curl -4 -fsL --max-time 3 https://api.ipify.org 2>/dev/null || curl -4 -fsL --max-time 3 https://ipinfo.io/ip 2>/dev/null || true)"
    ip="$(echo "$ip" | tr -d '[:space:]')"
  fi
  if [ -z "$ip" ] || ! is_valid_ip "$ip"; then
    ip="$(curl -6 -fsL --max-time 3 https://api64.ipify.org 2>/dev/null || curl -fsL --max-time 3 https://ipinfo.io/ip 2>/dev/null || true)"
    ip="$(echo "$ip" | tr -d '[:space:]')"
  fi
  if is_valid_ip "$ip" && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "::1" ]; then
    echo "$ip $(date +%s 2>/dev/null || echo 0)" > "$cache_file" 2>/dev/null || true
    echo "$ip"
  else
    local old_pub
    old_pub="$(get_val PUBLIC_IP)"
    if [ -n "$old_pub" ] && is_valid_ip "$old_pub" && [ "$old_pub" != "127.0.0.1" ] && [ "$old_pub" != "::1" ]; then
      echo "$old_pub"
    else
      echo ""
    fi
  fi
}

get_node_name_prefix() {
  local custom_name
  custom_name="$(get_val NAME)"
  if [ -n "$custom_name" ] && [ "$custom_name" != "xray" ] && [ "$custom_name" != "xr" ] && [ "$custom_name" != "xr-Node" ]; then
    echo "$custom_name"
    return
  fi

  # 若近期（10 分钟内）已探测失败过，直接返回兜底名，避免每次重绘菜单因网络阻塞卡顿
  local fail_file="$STATE_DIR/.geoip_fail"
  if [ -f "$fail_file" ]; then
    local last_fail now
    last_fail="$(cat "$fail_file" 2>/dev/null || echo 0)"
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ $((now - last_fail)) -lt 600 ]; then
      echo "xr-Node"
      return
    fi
  fi

  local nat64_was_on=0
  if [ "$(id -u)" = "0" ] && [ ! -f /etc/resolv.conf.xray-orig ]; then
    nat64_enable_temp
    nat64_was_on=1
  fi

  local country="" org="" raw_json=""

  # 1. 优先尝试 api.ip.sb/geoip (IPv4/IPv6 双栈高速)
  raw_json="$(curl -sL -A "Mozilla/5.0" --connect-timeout 3 -m 6 https://api.ip.sb/geoip 2>/dev/null || wget -qO- -U "Mozilla/5.0" --timeout=6 https://api.ip.sb/geoip 2>/dev/null || true)"
  if [ -n "$raw_json" ]; then
    country="$(echo "$raw_json" | grep -o '"country_code":"[^"]*"' | head -1 | cut -d'"' -f4)"
    org="$(echo "$raw_json" | grep -o '"asn_organization":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"isp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"organization":"[^"]*"' | head -1 | cut -d'"' -f4)"
  fi

  # 2. 备用尝试 ipwho.is (IPv4/IPv6 双栈)
  if [ -z "$country" ] || [ -z "$org" ]; then
    raw_json="$(curl -sL -A "Mozilla/5.0" --connect-timeout 3 -m 6 https://ipwho.is 2>/dev/null || wget -qO- -U "Mozilla/5.0" --timeout=6 https://ipwho.is 2>/dev/null || true)"
    if [ -n "$raw_json" ]; then
      [ -z "$country" ] && country="$(echo "$raw_json" | grep -o '"country_code":"[^"]*"' | head -1 | cut -d'"' -f4)"
      [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"org":"[^"]*"' | head -1 | cut -d'"' -f4)"
      [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"isp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi
  fi

  # 3. 备用尝试 ip-api.com
  if [ -z "$country" ] || [ -z "$org" ]; then
    raw_json="$(curl -sL -A "Mozilla/5.0" --connect-timeout 3 -m 6 http://ip-api.com/json 2>/dev/null || wget -qO- -U "Mozilla/5.0" --timeout=6 http://ip-api.com/json 2>/dev/null || true)"
    if [ -n "$raw_json" ]; then
      [ -z "$country" ] && country="$(echo "$raw_json" | grep -o '"countryCode":"[^"]*"' | head -1 | cut -d'"' -f4)"
      [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"org":"[^"]*"' | head -1 | cut -d'"' -f4)"
      [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"isp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi
  fi

  # 4. 备用尝试 ipinfo.io
  if [ -z "$country" ] || [ -z "$org" ]; then
    raw_json="$(curl -sL -A "Mozilla/5.0" --connect-timeout 3 -m 6 https://ipinfo.io/json 2>/dev/null || wget -qO- -U "Mozilla/5.0" --timeout=6 https://ipinfo.io/json 2>/dev/null || true)"
    if [ -n "$raw_json" ]; then
      [ -z "$country" ] && country="$(echo "$raw_json" | grep -o '"country":"[^"]*"' | head -1 | cut -d'"' -f4)"
      [ -z "$org" ] && org="$(echo "$raw_json" | grep -o '"org":"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi
  fi

  [ "$nat64_was_on" = "1" ] && nat64_restore_temp

  country="$(echo "$country" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')"
  org="$(echo "$org" | sed -e 's/^AS[0-9]* //' -e 's/,\? *Inc\.*//I' -e 's/,\? *LLC\.*//I' -e 's/,\? *Corp\.*//I' -e 's/,\? *L\.P\.*//I' | tr -s ' ' '_' | cut -c1-16 | tr -cd 'a-zA-Z0-9_-')"

  local name_tag
  if [ -n "$country" ] && [ -n "$org" ]; then
    name_tag="${country}-${org}"
    set_val NAME "$name_tag"
    rm -f "$fail_file" 2>/dev/null || true
  elif [ -n "$country" ]; then
    name_tag="${country}-Node"
    set_val NAME "$name_tag"
    rm -f "$fail_file" 2>/dev/null || true
  else
    name_tag="xr-Node"
    date +%s > "$fail_file" 2>/dev/null || true
  fi
  echo "$name_tag"
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

b64_urlsafe() {
  printf '%s' "$1" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='
}

press_any_key() {
  echo ""
  read -n 1 -s -r -p "按任意键继续..."
  echo ""
}

# ── 9. UUID 与 Reality 密钥体系 ────────────────────────────────────────────────
is_valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

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
      u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
      if [ -z "$u" ] && [ -r /dev/urandom ]; then
        u="$(od -x -N16 /dev/urandom 2>/dev/null | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')"
      fi
    fi
    set_val UUID "$u"
    echo "$u" > "$UUID_FILE"
  fi
  echo "$u"
}

get_reality_keys() {
  local priv="" pub=""
  if [ -f "$REALITY_KEY_FILE" ]; then
    priv="$(grep -Ei '^(PrivateKey|Private key):' "$REALITY_KEY_FILE" 2>/dev/null | head -1 | awk '{print $NF}')"
    pub="$(grep -Ei '(Password \(PublicKey\)|PublicKey|Public key):' "$REALITY_KEY_FILE" 2>/dev/null | head -1 | awk '{print $NF}')"
  fi
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    if [ -x "$XRAY_BIN" ]; then
      local kp
      kp="$("$XRAY_BIN" x25519 2>/dev/null)"
      priv="$(echo "$kp" | grep -Ei "(Private key|PrivateKey):" | head -1 | awk '{print $NF}')"
      pub="$(echo "$kp" | grep -Ei "(Password \(PublicKey\)|Public key|PublicKey):" | head -1 | awk '{print $NF}')"
      if [ -n "$priv" ] && [ -n "$pub" ]; then
        echo "PrivateKey: $priv" > "$REALITY_KEY_FILE"
        echo "PublicKey: $pub" >> "$REALITY_KEY_FILE"
        chmod 600 "$REALITY_KEY_FILE"
      fi
    fi
  fi
  echo "$priv $pub"
}

get_ss2022_key() {
  local in_p="${1:-}"
  local key=""
  if [ -n "$in_p" ]; then
    local dec_len
    dec_len="$(printf '%s' "$in_p" | base64 -d 2>/dev/null | wc -c || echo 0)"
    if [ "$dec_len" = "16" ]; then
      key="$in_p"
    elif command -v openssl >/dev/null 2>&1; then
      key="$(printf '%s' "$in_p" | openssl dgst -sha256 -binary 2>/dev/null | head -c 16 | base64 2>/dev/null)"
    fi
  fi
  if [ -z "$key" ]; then
    if command -v openssl >/dev/null 2>&1; then
      key="$(openssl rand -base64 16 2>/dev/null)"
    fi
    if [ -z "$key" ] && [ -r /dev/urandom ]; then
      key="$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\r\n')"
    fi
    if [ -z "$key" ] && command -v python3 >/dev/null 2>&1; then
      key="$(python3 -c 'import secrets, base64; print(base64.b64encode(secrets.token_bytes(16)).decode())' 2>/dev/null)"
    fi
    if [ -z "$key" ] && command -v python >/dev/null 2>&1; then
      key="$(python -c 'import os, base64; print(base64.b64encode(os.urandom(16)).decode())' 2>/dev/null)"
    fi
  fi
  printf '%s' "$key" | tr -d '\r\n'
}

get_ss_pass() {
  local k
  k="$(get_val SS_PASS)"
  if [ -z "$k" ]; then
    k="$(get_ss2022_key "")"
    set_val SS_PASS "$k"
  fi
  echo "$k"
}

get_random_hex() {
  local num="${1:-4}"
  local h=""
  if command -v openssl >/dev/null 2>&1; then
    h="$(openssl rand -hex "$num" 2>/dev/null || true)"
  fi
  if [ -z "$h" ] && [ -r /dev/urandom ]; then
    h="$(od -An -tx1 -N"$num" /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  if [ -z "$h" ]; then
    h="$(date +%s%N 2>/dev/null | sha256sum 2>/dev/null | head -c "$((num * 2))" || echo "$$")"
  fi
  printf '%s' "$h"
}

get_socks5_creds() {
  local u p
  u="$(get_val S5_USER)"
  p="$(get_val S5_PASS)"
  if [ -z "$u" ]; then
    u="user$(get_random_hex 3)"
    set_val S5_USER "$u"
  fi
  if [ -z "$p" ]; then
    p="pass$(get_random_hex 6)"
    set_val S5_PASS "$p"
  fi
  echo "$u $p"
}

get_reality_short_id() {
  local sid
  sid="$(get_val REALITY_SHORT_ID)"
  if [ -z "$sid" ] || [[ ! "$sid" =~ ^[0-9a-fA-F]{8}$ ]]; then
    sid="$(get_random_hex 4)"
    [ -z "$sid" ] && sid="$(printf '%08x' "$$")"
    set_val REALITY_SHORT_ID "$sid"
  fi
  echo "$sid"
}

get_trojan_pass() {
  local p
  p="$(get_val TROJAN_PASS)"
  if [ -z "$p" ]; then
    p="$(get_random_hex 12)"
    set_val TROJAN_PASS "$p"
  fi
  echo "$p"
}

get_inbound_listen_addr() {
  if [ -f /proc/net/if_inet6 ] || (command -v ip >/dev/null 2>&1 && ip -6 addr show 2>/dev/null | grep -q "inet6"); then
    echo "::"
  else
    echo "0.0.0.0"
  fi
}

ensure_self_signed_cert() {
  local cert_dir="$DOMAIN_CERT_DIR/self_signed"
  local c_file="$cert_dir/cert.pem"
  local k_file="$cert_dir/key.pem"
  if [ ! -f "$c_file" ] || [ ! -f "$k_file" ]; then
    mkdir -p "$cert_dir"
    if command -v openssl >/dev/null 2>&1; then
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$k_file" -out "$c_file" \
        -days 3650 -subj "/CN=bing.com/O=Microsoft/C=US" >/dev/null 2>&1 || true
      chmod 600 "$k_file" 2>/dev/null || true
    fi
  fi
}

# ── 10. ACME.sh 自动化域名证书系统 ─────────────────────────────────────────────
ensure_acme() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  log "正在安装 acme.sh 自动化证书引擎..."
  mkdir -p "$STATE_DIR"
  local tmp_acme
  tmp_acme="$(mktemp -d "$STATE_DIR/.acme.XXXXXX" 2>/dev/null || echo "$STATE_DIR/.acme_$$")"
  rm -rf "$tmp_acme" && mkdir -p "$tmp_acme"
  if ! download_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/3.1.0/acme.sh" "$tmp_acme/acme.sh"; then
    warn "下载 acme.sh 失败，请检查网络"
    rm -rf "$tmp_acme"
    return 1
  fi
  chmod +x "$tmp_acme/acme.sh"
  ensure_cron || true
  (cd "$tmp_acme" && ./acme.sh --install --home "$ACME_HOME" --noprofile --force >/dev/null 2>&1)
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

validate_domain_name() {
  local d="$1"
  [ -z "$d" ] && return 1
  if [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ ! "$d" =~ \.\. ]]; then
    return 0
  fi
  return 1
}

apply_domain_to_all_protos() {
  local dom="$1"
  set_val SERVER_DOMAIN "$dom"
  set_val TROJAN_CERT_DOMAIN "$dom"
  log "已将 ${CYAN}${dom}${GREEN} 设为全局连接域名，并绑定至 TLS 直连协议！"
  do_restart
}

menu_domain_cert() {
  while true; do
    clear
    echo -e "${GREEN}==================== 域名证书管理 ====================${RESET}"
    local certs _s_dom
    certs="$(_list_domain_certs)"
    _s_dom="$(get_val SERVER_DOMAIN)"
    echo -e "${GRAY}已签发证书:${RESET} ${CYAN}${certs:-暂无}${RESET}"
    echo -e "${GRAY}当前域名:  ${RESET} ${CYAN}${_s_dom:-使用公网 IP 直连}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 1. 申请 ACME 证书${RESET}"
    echo -e "${WHITE} 2. 导入外部证书${RESET}"
    echo -e "${WHITE} 3. 强制续期证书${RESET}"
    echo -e "${WHITE} 4. 删除域名证书${RESET}"
    echo -e "${WHITE} 0. 返回面板${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    read -p "请输入选项: " c_opt
    case "$c_opt" in
      1)
        ensure_acme || { warn "acme.sh 初始化失败"; press_any_key; continue; }
        read -p "请输入解析到本机的域名 (如 vps.example.com): " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        validate_domain_name "$domain" || { warn "域名格式非法，包含非法字符"; press_any_key; continue; }
        if port_in_use_os 80; then
          warn "检测到 80 端口已被其他进程占用 (如 Nginx / Apache / Caddy)"
          warn "Let's Encrypt standalone 模式需要监听 80 端口，请先临时停止占用 80 端口的服务"
          press_any_key
          continue
        fi
        open_firewall_port 80 tcp
        local had_valid_cert=0
        if [ -s "$DOMAIN_CERT_DIR/$domain/cert.pem" ] && [ -s "$DOMAIN_CERT_DIR/$domain/key.pem" ]; then
          had_valid_cert=1
        fi
        mkdir -p "$DOMAIN_CERT_DIR/$domain"
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --register-account -m "admin@${domain}" --server letsencrypt >/dev/null 2>&1 || true
        log "正在向 Let's Encrypt 申请证书..."
        if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt; then
          "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
            --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
            --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" \
            --reloadcmd "pkill -f '$BIN_DIR/xray' 2>/dev/null || true" >/dev/null 2>&1
          chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem"
          log "证书申请安装成功！"
          read -p "是否将此域名应用到全部直连协议？[Y/n]: " _apply_all
          case "$_apply_all" in
            n|N) ;;
            *) apply_domain_to_all_protos "$domain" ;;
          esac
        else
          if [ "$had_valid_cert" = "1" ]; then
            warn "证书更新跳过或未完成，但本地已有有效证书，继续保留使用"
          else
            warn "证书签发失败，请确认域名已正确解析到本机公网 IP 且 80 端口未被占用"
            rm -rf "${DOMAIN_CERT_DIR:?}/${domain}"
          fi
        fi
        press_any_key
        ;;
      2)
        read -p "请输入域名标识: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        validate_domain_name "$domain" || { warn "域名格式非法，包含非法字符"; press_any_key; continue; }
        read -p "cert.pem 绝对路径: " cpath
        read -p "key.pem 绝对路径: " kpath
        if [ -f "$cpath" ] && [ -f "$kpath" ]; then
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
        validate_domain_name "$domain" || { warn "域名格式非法，包含非法字符"; press_any_key; continue; }
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
        validate_domain_name "$domain" || { warn "域名格式非法，包含非法字符"; press_any_key; continue; }
        if [ -d "$DOMAIN_CERT_DIR/$domain" ]; then
          rm -rf "${DOMAIN_CERT_DIR:?}/${domain}"
          [ -x "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --home "$ACME_HOME" --remove -d "$domain" >/dev/null 2>&1 || true
          [ "$(get_val SERVER_DOMAIN)" = "$domain" ] && set_val SERVER_DOMAIN ""
          log "证书已安全删除: $domain"
          do_restart
        else
          warn "未找到此域名的证书目录"
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
    log "正在生成独立 WireGuard X25519 密钥对..."
    local priv_key="" pub_key=""
    if [ -x "$XRAY_BIN" ]; then
      local kp
      kp="$("$XRAY_BIN" x25519 2>/dev/null)"
      priv_key="$(echo "$kp" | grep -Ei "(Private key|PrivateKey):" | head -1 | awk '{print $NF}')"
      pub_key="$(echo "$kp" | grep -Ei "(Password \(PublicKey\)|Public key|PublicKey):" | head -1 | awk '{print $NF}')"
    fi
    # URL-safe Base64 转为标准 Base64 (tr '_-' '/+') 并规范补齐等号填充
    if [ -n "$priv_key" ]; then
      priv_key="$(printf '%s' "$priv_key" | tr '_-' '/+')"
      while [ $(( ${#priv_key} % 4 )) -ne 0 ]; do priv_key="${priv_key}="; done
    fi
    if [ -n "$pub_key" ]; then
      pub_key="$(printf '%s' "$pub_key" | tr '_-' '/+')"
      while [ $(( ${#pub_key} % 4 )) -ne 0 ]; do pub_key="${pub_key}="; done
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
      elif command -v od >/dev/null 2>&1; then
        _dec="$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null | awk '{print $1", "$2", "$3}')"
      fi
      [ -n "$_dec" ] && reserved="$_dec"
    fi

    cat > "$WARP_CONF" << EOF
PRIV_KEY=${priv_key}
PEER_PUB_KEY=${peer_pub}
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
  echo -e "${GREEN}================ 出口设置与落地分流 ================${RESET}"
  local cur_type="direct" cur_mode="直连" cur_addr="" cur_port=""
  if [ -f "$OUTBOUND_FILE" ]; then
    cur_type="$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    cur_addr="$(grep '^HOST=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    cur_port="$(grep '^PORT=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    local r_m
    r_m="$(grep '^ROUTE_MODE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)"
    [ "$r_m" = "split" ] && cur_mode="智能分流"
    [ "$r_m" = "global" ] && cur_mode="全局代理"
  fi
  if [ "$cur_type" = "direct" ]; then
    echo -e "当前出站模式: ${CYAN}原生直连${RESET}"
  elif [ "$cur_type" = "warp" ]; then
    echo -e "当前出站模式: ${CYAN}WARP 原生出口${RESET} [模式: ${GREEN}${cur_mode}${RESET}]"
  else
    echo -e "当前出站模式: ${CYAN}${cur_type}${RESET} -> ${CYAN}${cur_addr}:${cur_port}${RESET} [模式: ${GREEN}${cur_mode}${RESET}]"
  fi
  echo -e "${GREEN}----------------------------------------------------${RESET}"
  echo -e "${WHITE} 1. 设置 Socks5 出口${RESET}"
  echo -e "${WHITE} 2. 设置 HTTP 出口${RESET}"
  echo -e "${WHITE} 3. 设置 TURN 出口${RESET}"
  echo -e "${WHITE} 4. 设置 WARP 出口${RESET}"
  echo -e "${WHITE} 5. 分流模式${RESET}"
  echo -e "${WHITE} 6. 恢复直连${RESET}"
  echo -e "${WHITE} 0. 返回面板${RESET}"
  echo -e "${GREEN}----------------------------------------------------${RESET}"
  read -p "请输入选项 [0-6]: " o_opt
  case "$o_opt" in
    1|2)
      local proto="socks" p_host p_port p_user p_pass=""
      [ "$o_opt" = "2" ] && proto="http"
      read -p "代理服务器 IP/域名: " p_host
      p_host="$(printf '%s' "$p_host" | tr -d '[:space:]')"
      if [ -z "$p_host" ] || [[ "$p_host" =~ [\"\\\'\<\>\;\&] ]]; then
        warn "代理服务器地址格式非法，请勿包含引号或特殊符号"
        press_any_key
        return
      fi
      p_port="$(prompt_remote_port "代理端口: " "")"
      if [ -z "$p_port" ]; then
        warn "代理端口不能为空"
        press_any_key
        return
      fi
      read -p "用户名 (留空无认证): " p_user
      if [ -n "$p_user" ]; then
        read -s -p "密码: " p_pass
        echo ""
      fi
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
      ;;
    3)
      echo -e "${CYAN}提示: TURN 出口将由配套组件 turn2socks 进行本地转接${RESET}"
      local t_host t_port t_user t_pass="" t_lport
      read -p "TURN 服务器地址: " t_host
      t_host="$(printf '%s' "$t_host" | tr -d '[:space:]')"
      if [ -z "$t_host" ] || [[ "$t_host" =~ [\"\\\'\<\>\;\&] ]]; then
        warn "TURN 服务器地址格式非法，请勿包含引号或特殊符号"
        press_any_key
        return
      fi
      t_port="$(prompt_remote_port "TURN 服务器端口 [默认 3478]: " "3478")"
      if [ -z "$t_port" ]; then
        warn "TURN 端口不能为空"
        press_any_key
        return
      fi
      read -p "用户名 (留空无认证): " t_user
      if [ -n "$t_user" ]; then
        read -s -p "密码: " t_pass
        echo ""
      fi
      t_lport="$(prompt_relay_port "本地 SOCKS5 转接端口 [默认 10808]: " "10808")"
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
        stop_turn2socks 2>/dev/null || true
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
  local uuid reality_port xhttp_port reality_domain reality_priv reality_pub reality_sid ss_port ss_pass s5_port s5_user s5_pass trojan_port trojan_pass listen_addr
  local pub_ip s5_ip_field=""
  pub_ip="$(get_public_ip)"
  if [ -n "$pub_ip" ] && [ "$pub_ip" != "127.0.0.1" ] && [ "$pub_ip" != "::1" ]; then
    s5_ip_field=', "ip": "'"$pub_ip"'"'
  fi
  uuid="$(get_uuid)"
  reality_port="$(get_val REALITY_PORT)"
  xhttp_port="$(get_val XHTTP_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r reality_priv reality_pub <<< "$(get_reality_keys)"
  reality_sid="$(get_reality_short_id)"

  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_ss_pass)"

  s5_port="$(get_val S5_PORT)"
  read -r s5_user s5_pass <<< "$(get_socks5_creds)"

  trojan_port="$(get_val TROJAN_PORT)"
  trojan_pass="$(get_trojan_pass)"

  listen_addr="$(get_inbound_listen_addr)"

  local tmp_cfg
  tmp_cfg="${STATE_DIR}/config.tmp.$$.json"

  cat > "$tmp_cfg" << EOF
{
  "log": {
    "access": "none",
    "loglevel": "warning"
  },
  "inbounds": [
EOF

  local first_inbound=1
  append_inbound() {
    [ "$first_inbound" = "0" ] && echo "," >> "$tmp_cfg"
    echo "$1" >> "$tmp_cfg"
    first_inbound=0
  }

  # 1. Argo 穿透入站组
  if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
    local argo_dom_val argo_auth_val is_fixed_argo=false
    argo_dom_val="$(get_val ARGO_DOMAIN)"
    argo_auth_val="$(get_val ARGO_AUTH)"
    [ -n "$argo_dom_val" ] && [ "$argo_dom_val" != "your-domain.com" ] && [ -n "$argo_auth_val" ] && is_fixed_argo=true

    local argo_fallbacks='          {
            "path": "/vmess-ws",
            "dest": 10000,
            "xver": 0
          },
          {
            "path": "/vless-ws",
            "dest": 10001,
            "xver": 0
          },
          {
            "path": "/trojan-ws",
            "dest": 10002,
            "xver": 0
          }'
    if $is_fixed_argo; then
      argo_fallbacks+=',
          {
            "path": "/vless-xhttp",
            "dest": 10003,
            "xver": 0
          }'
    fi

    append_inbound '    {
      "tag": "argo-dispatcher-in",
      "port": 8001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "'"$uuid"'", "level": 0 }],
        "decryption": "none",
        "fallbacks": [
'"$argo_fallbacks"'
        ]
      },
      "streamSettings": {
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }'
    append_inbound '    {
      "tag": "vmess-ws-in",
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "'"$uuid"'", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-ws" } },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }'
    append_inbound '    {
      "tag": "vless-ws-in",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "'"$uuid"'" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }'
    append_inbound '    {
      "tag": "trojan-ws-in",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "'"$trojan_pass"'" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }'
    if $is_fixed_argo; then
      append_inbound '    {
        "tag": "vless-xhttp-in",
        "port": 10003,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": { "clients": [{ "id": "'"$uuid"'" }], "decryption": "none" },
        "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/vless-xhttp", "mode": "auto" } },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"],
          "routeOnly": true
        }
      }'
    fi
  fi

  # 2. 直连 Reality 入站 (TCP Vision)
  if [ -n "$reality_port" ] && [ -n "$reality_priv" ]; then
    append_inbound '    {
      "tag": "reality-in",
      "port": '"$reality_port"',
      "listen": "'"$listen_addr"'",
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
          "shortIds": ["'"$reality_sid"'"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }'
  fi

  # 3. 直连 Reality xhttp 入站
  if [ -n "$xhttp_port" ] && [ -n "$reality_priv" ]; then
    append_inbound '    {
      "tag": "reality-xhttp-in",
      "port": '"$xhttp_port"',
      "listen": "'"$listen_addr"'",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "'"$uuid"'", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "'"$reality_domain"':443",
          "xver": 0,
          "serverNames": ["'"$reality_domain"'"],
          "privateKey": "'"$reality_priv"'",
          "shortIds": ["'"$reality_sid"'"]
        },
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }'
  fi

  # 3. 直连 Shadowsocks 2022 入站
  if [ -n "$ss_port" ]; then
    append_inbound '    {
      "tag": "ss-in",
      "port": '"$ss_port"',
      "listen": "'"$listen_addr"'",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "'"$ss_pass"'",
        "network": "tcp,udp"
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }'
  fi

  # 4. 直连 Socks5 入站
  if [ -n "$s5_port" ]; then
    append_inbound '    {
      "tag": "s5-in",
      "port": '"$s5_port"',
      "listen": "'"$listen_addr"'",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [{ "user": "'"$s5_user"'", "pass": "'"$s5_pass"'" }],
        "udp": true'"$s5_ip_field"'
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }'
  fi

  # 5. 直连 Trojan-TCP (支持 ACME 证书与自签证书)
  if [ -n "$trojan_port" ]; then
    local trojan_cert_dom cert_snippet c_file="" k_file=""
    trojan_cert_dom="$(get_val TROJAN_CERT_DOMAIN)"
    [ -z "$trojan_cert_dom" ] && trojan_cert_dom="$(get_val SERVER_DOMAIN)"
    if [ -n "$trojan_cert_dom" ] && [ -f "$DOMAIN_CERT_DIR/$trojan_cert_dom/cert.pem" ]; then
      c_file="$DOMAIN_CERT_DIR/$trojan_cert_dom/cert.pem"
      k_file="$DOMAIN_CERT_DIR/$trojan_cert_dom/key.pem"
    else
      ensure_self_signed_cert
      c_file="$DOMAIN_CERT_DIR/self_signed/cert.pem"
      k_file="$DOMAIN_CERT_DIR/self_signed/key.pem"
    fi
    cert_snippet='"security": "tls", "tlsSettings": { "certificates": [{ "certificateFile": "'"$c_file"'", "keyFile": "'"$k_file"'" }] }'
    append_inbound '    {
      "tag": "trojan-direct-in",
      "port": '"$trojan_port"',
      "listen": "'"$listen_addr"'",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "'"$trojan_pass"'" }] },
      "streamSettings": { "network": "tcp", '"$cert_snippet"' },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }'
  fi

  cat >> "$tmp_cfg" << EOF
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
    [ "$first_outbound" = "0" ] && echo "," >> "$tmp_cfg"
    echo "$1" >> "$tmp_cfg"
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
          "endpoint": "'"$w_end"'"
        }],
        "reserved": ['"$w_res"']
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
    if ! [[ "$p_p" =~ ^[0-9]+$ ]] || [ "$p_p" -lt 1 ] || [ "$p_p" -gt 65535 ]; then
      p_p=1080
    fi
    local u_block=""
    if [ -n "$p_u" ]; then
      local esc_u esc_pass
      esc_u="$(escape_json "$p_u")"
      esc_pass="$(escape_json "$p_pass")"
      u_block=', "users": [{ "user": "'"$esc_u"'", "pass": "'"$esc_pass"'" }]'
    fi

    local esc_h
    esc_h="$(escape_json "$p_h")"
    local proxy_block='    {
      "tag": "proxy-out",
      "protocol": "'"$out_type"'",
      "settings": {
        "servers": [{ "address": "'"$esc_h"'", "port": '"$p_p"''"$u_block"' }]
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
    if ! [[ "$t_lp" =~ ^[0-9]+$ ]] || [ "$t_lp" -lt 1 ] || [ "$t_lp" -gt 65535 ]; then
      t_lp=10808
    fi
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

  cat >> "$tmp_cfg" << EOF
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "ip": ["geoip:private"]
      },
EOF

  if [ -n "$active_outbound_tag" ] && [ "$out_route_mode" = "split" ]; then
    cat >> "$tmp_cfg" << EOF
      {
        "type": "field",
        "outboundTag": "${active_outbound_tag}",
        "domain": [
          "geosite:openai",
          "geosite:google-gemini",
          "geosite:netflix",
          "geosite:disney",
          "geosite:spotify",
          "geosite:hbo"
        ]
      },
EOF
  elif [ -n "$active_outbound_tag" ] && [ "$out_route_mode" = "global" ]; then
    cat >> "$tmp_cfg" << EOF
      {
        "type": "field",
        "outboundTag": "${active_outbound_tag}",
        "network": "tcp,udp"
      },
EOF
  fi

  cat >> "$tmp_cfg" << EOF
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
  chmod 600 "$tmp_cfg"
  if [ -x "$XRAY_BIN" ]; then
    if "$XRAY_BIN" run -test -format json -config "$tmp_cfg" >/dev/null 2>&1; then
      mv -f "$tmp_cfg" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
      return 0
    else
      warn "新生成的 Xray 配置文件未能通过语法测试，已保留原配置以防止崩溃"
      rm -f "$tmp_cfg"
      return 1
    fi
  else
    mv -f "$tmp_cfg" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    return 0
  fi
}

# ── 13. 全协议多格式订阅分发生成器 ─────────────────────────────────────────────
generate_sub() {
  local uuid prefer_host argo_domain pub_ip name node_host reality_sid trojan_pass
  uuid="$(get_uuid)"
  prefer_host="$(get_val CF_PREFER_HOST)"
  [ -z "$prefer_host" ] && prefer_host="www.visa.com.tw"
  argo_domain="$(get_val ARGO_DOMAIN)"
  pub_ip="$(get_public_ip)"
  name="$(get_node_name_prefix)"
  reality_sid="$(get_reality_short_id)"
  trojan_pass="$(get_trojan_pass)"

  node_host="$(get_val SERVER_DOMAIN)"
  [ -z "$node_host" ] && node_host="$(format_addr "$pub_ip")"

  local links=()
  local clash_proxies=()
  local clash_names=()

  # 1. Argo 穿透链路 (仅当域名有效且非占位符时下发)
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ -n "$argo_domain" ] && [ "$argo_domain" != "your-domain.com" ]; then
    local argo_dom_val argo_auth_val is_fixed_argo=false
    argo_dom_val="$argo_domain"
    argo_auth_val="$(get_val ARGO_AUTH)"
    [ -n "$argo_auth_val" ] && is_fixed_argo=true

    # 仅固定隧道且域名验证通过时启用 Argo VLESS-xhttp
    if $is_fixed_argo; then
      local n_argo_xh="${name}-Argo-xhttp"
      links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=xhttp&host=${argo_domain}&path=%2Fvless-xhttp&mode=auto&sni=${argo_domain}#${n_argo_xh}")
      clash_names+=("\"${n_argo_xh}\"")
      clash_proxies+=("  - name: \"${n_argo_xh}\"
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
      mode: auto
      headers:
        Host: ${argo_domain}")
    fi

    # VLESS-WS
    local n_argo_vless="${name}-Argo-VLESS"
    links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=ws&host=${argo_domain}&path=%2Fvless-ws&sni=${argo_domain}#${n_argo_vless}")
    clash_names+=("\"${n_argo_vless}\"")
    clash_proxies+=("  - name: \"${n_argo_vless}\"
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
    local n_argo_vmess="${name}-Argo-VMess"
    local vm_json
    vm_json="$(printf '{\"v\":\"2\",\"ps\":\"%s\",\"add\":\"%s\",\"port\":\"443\",\"id\":\"%s\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"%s\",\"path\":\"/vmess-ws\",\"tls\":\"tls\",\"sni\":\"%s\"}' "$n_argo_vmess" "$prefer_host" "$uuid" "$argo_domain" "$argo_domain")"
    links+=("vmess://$(b64 "$vm_json")")
    clash_names+=("\"${n_argo_vmess}\"")
    clash_proxies+=("  - name: \"${n_argo_vmess}\"
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
    local n_argo_tr="${name}-Argo-Trojan"
    links+=("trojan://${trojan_pass}@${prefer_host}:443?security=tls&type=ws&host=${argo_domain}&path=%2Ftrojan-ws&sni=${argo_domain}#${n_argo_tr}")
    clash_names+=("\"${n_argo_tr}\"")
    clash_proxies+=("  - name: \"${n_argo_tr}\"
    type: trojan
    server: ${prefer_host}
    port: 443
    password: ${trojan_pass}
    network: ws
    tls: true
    udp: true
    sni: ${argo_domain}
    ws-opts:
      path: /trojan-ws
      headers:
        Host: ${argo_domain}")
  fi

  # 2. 直连 VLESS-Reality (TCP Vision)
  local reality_port reality_domain
  reality_port="$(get_val REALITY_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r _ reality_pub <<< "$(get_reality_keys)"

  if [ -n "$reality_port" ] && [ -n "$reality_pub" ] && [ -n "$node_host" ]; then
    local r_host="${node_host#[}"
    r_host="${r_host%]}"
    local n_r_tcp="${name}-Reality-TCP"
    links+=("vless://${uuid}@${node_host}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&sid=${reality_sid}&type=tcp#${n_r_tcp}")
    clash_names+=("\"${n_r_tcp}\"")
    clash_proxies+=("  - name: \"${n_r_tcp}\"
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
      short-id: \"${reality_sid}\"
    client-fingerprint: chrome")
  fi

  # 3. 直连 VLESS-Reality (xhttp)
  local xhttp_port
  xhttp_port="$(get_val XHTTP_PORT)"
  if [ -n "$xhttp_port" ] && [ -n "$reality_pub" ] && [ -n "$node_host" ]; then
    local rx_host="${node_host#[}"
    rx_host="${rx_host%]}"
    local n_r_xh="${name}-Reality-xhttp"
    links+=("vless://${uuid}@${node_host}:${xhttp_port}?encryption=none&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&sid=${reality_sid}&type=xhttp&path=%2Fxhttp&mode=auto#${n_r_xh}")
    clash_names+=("\"${n_r_xh}\"")
    clash_proxies+=("  - name: \"${n_r_xh}\"
    type: vless
    server: ${rx_host}
    port: ${xhttp_port}
    uuid: ${uuid}
    network: xhttp
    tls: true
    udp: true
    flow: \"\"
    servername: ${reality_domain}
    xhttp-opts:
      path: /xhttp
      mode: auto
    reality-opts:
      public-key: ${reality_pub}
      short-id: \"${reality_sid}\"
    client-fingerprint: chrome")
  fi

  # 4. 直连 Shadowsocks 2022
  local ss_port ss_pass
  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_ss_pass)"
  if [ -n "$ss_port" ] && [ -n "$node_host" ]; then
    local ss_uinfo
    ss_uinfo="$(b64_urlsafe "2022-blake3-aes-128-gcm:${ss_pass}")"
    local n_ss="${name}-SS-2022"
    links+=("ss://${ss_uinfo}@${node_host}:${ss_port}#${n_ss}")
    local s_host="${node_host#[}"
    s_host="${s_host%]}"
    clash_names+=("\"${n_ss}\"")
    clash_proxies+=("  - name: \"${n_ss}\"
    type: ss
    server: ${s_host}
    port: ${ss_port}
    cipher: 2022-blake3-aes-128-gcm
    password: \"${ss_pass}\"
    udp: true")
  fi

  # 5. 直连 Socks5
  local s5_port s5_user s5_pass
  s5_port="$(get_val S5_PORT)"
  read -r s5_user s5_pass <<< "$(get_socks5_creds)"
  if [ -n "$s5_port" ] && [ -n "$node_host" ]; then
    local s_host="${node_host#[}"
    s_host="${s_host%]}"
    local n_s5="${name}-Socks5"
    links+=("socks5://${s5_user}:${s5_pass}@${node_host}:${s5_port}#${n_s5}")
    echo "tg://socks?server=${s_host}&port=${s5_port}&user=${s5_user}&pass=${s5_pass}" > "$TG_S5_FILE"
    chmod 600 "$TG_S5_FILE" 2>/dev/null || true
    clash_names+=("\"${n_s5}\"")
    clash_proxies+=("  - name: \"${n_s5}\"
    type: socks5
    server: ${s_host}
    port: ${s5_port}
    username: \"${s5_user}\"
    password: \"${s5_pass}\"
    udp: true")
  fi

  # 6. 直连 Trojan-TCP
  local trojan_port
  trojan_port="$(get_val TROJAN_PORT)"
  if [ -n "$trojan_port" ] && [ -n "$node_host" ]; then
    local tr_sni tr_insec="1" skip_cert="true"
    tr_sni="$(get_val TROJAN_CERT_DOMAIN)"
    [ -z "$tr_sni" ] && tr_sni="$(get_val SERVER_DOMAIN)"
    if [ -n "$tr_sni" ] && [ -f "$DOMAIN_CERT_DIR/$tr_sni/cert.pem" ]; then
      tr_insec="0"
      skip_cert="false"
    else
      tr_sni="bing.com"
      tr_insec="1"
      skip_cert="true"
    fi
    local n_tr="${name}-Trojan-TCP"
    links+=("trojan://${trojan_pass}@${node_host}:${trojan_port}?security=tls&sni=${tr_sni}&allowInsecure=${tr_insec}#${n_tr}")
    local tr_host="${node_host#[}"
    tr_host="${tr_host%]}"
    clash_names+=("\"${n_tr}\"")
    clash_proxies+=("  - name: \"${n_tr}\"
    type: trojan
    server: ${tr_host}
    port: ${trojan_port}
    password: ${trojan_pass}
    udp: true
    sni: ${tr_sni}
    skip-cert-verify: ${skip_cert}")
  fi

  # 写入原始链接与 Base64
  printf "%s\n" "${links[@]+"${links[@]}"}" > "$SUB_RAW_FILE"
  b64 "$(printf "%s\n" "${links[@]+"${links[@]}"}")" > "$SUB_FILE"
  chmod 600 "$SUB_FILE" "$SUB_RAW_FILE" 2>/dev/null || true

  # 写入 Clash Meta (Mihomo) 配置 (默认 allow-lan: false 保障安全)
  cat > "$CLASH_META_FILE" << EOF
# Xray Universal Proxy Engine - Clash Meta / Mihomo Config
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info

proxies:
$(printf "%s\n\n" "${clash_proxies[@]+"${clash_proxies[@]}"}")

proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
$(printf "      - %s\n" "${clash_names[@]+"${clash_names[@]}"}")

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXIES
EOF
  chmod 600 "$CLASH_META_FILE" 2>/dev/null || true

  # 写入 Xray 客户端专用配置 JSON (仅当 Reality 启用且主机有效时)
  if [ -n "$reality_port" ] && [ -n "$reality_pub" ] && [ -n "$node_host" ]; then
    local r_target_host="${node_host#[}"
    r_target_host="${r_target_host%]}"
    if [ -n "$r_target_host" ]; then
      cat > "$XRAY_CLIENT_FILE" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks-in", "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http-in", "port": 10809, "listen": "127.0.0.1", "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${r_target_host}",
          "port": ${reality_port},
          "users": [{ "id": "${uuid}", "flow": "xtls-rprx-vision", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "${reality_domain:-www.iij.ad.jp}",
          "publicKey": "${reality_pub}",
          "shortId": "${reality_sid}"
        }
      }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
      chmod 600 "$XRAY_CLIENT_FILE" 2>/dev/null || true
    else
      rm -f "$XRAY_CLIENT_FILE" 2>/dev/null || true
    fi
  else
    rm -f "$XRAY_CLIENT_FILE" 2>/dev/null || true
  fi
}

rotate_log_if_needed() {
  local log_file="$1"
  local max_mb="${2:-10}"
  [ -f "$log_file" ] || return 0
  local size_bytes
  size_bytes="$(wc -c < "$log_file" 2>/dev/null || echo 0)"
  local max_bytes=$((max_mb * 1024 * 1024))
  if [ "$size_bytes" -gt "$max_bytes" ]; then
    # 保留最后 2000 行到 .1 备份，并原地截断 (: >)，保持 inode 避免破坏重定向进程的文件句柄
    tail -n 2000 "$log_file" > "${log_file}.1" 2>/dev/null || true
    : > "$log_file" 2>/dev/null || true
  fi
}

start_xray() {
  stop_pid_file "$PID_FILE" "$XRAY_BIN"
  "$XRAY_BIN" run -config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
}

start_cloudflared() {
  [ "$(get_val DISABLE_ARGO)" = "true" ] && return 0
  [ -x "$CF_BIN" ] || return 0
  stop_pid_file "$CF_PID" "$CF_BIN"
  local argo_domain argo_auth argo_proto
  argo_domain="$(get_val ARGO_DOMAIN)"
  argo_auth="$(get_val ARGO_AUTH)"
  argo_proto="$(get_val ARGO_PROTOCOL "http2")"
  local cf_args=("tunnel" "--edge-ip-version" "auto" "--no-autoupdate" "--protocol" "$argo_proto")

  if [ -n "$argo_domain" ] && [ -n "$argo_auth" ]; then
    cf_args+=("run")
    TUNNEL_TOKEN="$argo_auth" "$CF_BIN" "${cf_args[@]}" >> "$CF_LOG" 2>&1 &
    echo $! > "$CF_PID"
    log "Cloudflare 固定隧道已启动 (${argo_domain})"
    generate_sub
  else
    set_val ARGO_DOMAIN ""
    > "$CF_LOG" 2>/dev/null || true
    cf_args+=("--url" "http://127.0.0.1:8001")
    "$CF_BIN" "${cf_args[@]}" >> "$CF_LOG" 2>&1 &
    echo $! > "$CF_PID"
    log "Cloudflare 临时隧道正在建立连接..."
    (
      local count=0 new_host=""
      while [ $count -lt 30 ]; do
        new_host="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | grep -v 'api\.trycloudflare\.com' | tail -n 1 | sed 's|https://||')"
        [ -n "$new_host" ] && break
        sleep 1
        count=$((count + 1))
      done
      if [ -n "$new_host" ] && [ "$new_host" != "$(get_val ARGO_DOMAIN)" ]; then
        set_val ARGO_DOMAIN "$new_host"
        log "Cloudflare 临时域名已分配: ${GREEN}https://${new_host}${RESET}"
        generate_sub >/dev/null 2>&1 || true
      fi
    ) &
  fi
}

start_komari() {
  local km_dom km_tok
  km_dom="$(get_val KOMARI_DOMAIN)"
  km_tok="$(get_val KOMARI_TOKEN)"
  if [ -n "$km_dom" ] && [ -n "$km_tok" ] && [ -x "$KM_BIN" ]; then
    stop_pid_file "$KM_PID" "$KM_BIN"
    case "$km_dom" in
      http://*|https://*) ;;
      *) km_dom="https://${km_dom}" ;;
    esac
    local km_conf="$STATE_DIR/komari.json"
    cat > "$km_conf" << EOF
{
  "endpoint": "${km_dom}",
  "token": "${km_tok}",
  "disable_web_ssh": true,
  "disable_auto_update": true
}
EOF
    chmod 600 "$km_conf"
    AGENT_ENDPOINT="$km_dom" AGENT_TOKEN="$km_tok" "$KM_BIN" --disable-web-ssh --disable-auto-update --config "$km_conf" >> "$KM_LOG" 2>&1 &
    echo $! > "$KM_PID"
    log "Komari 监控探针已启动 (已禁用远程命令执行与自动更新)"
  fi
}

stop_pid_file() {
  local p_file="$1" expected_bin="${2:-}"
  if [ -f "$p_file" ]; then
    local p
    p="$(cat "$p_file" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      if [ -n "$expected_bin" ] && [ -d "/proc/$p" ]; then
        if [ "$expected_bin" = "run" ] || [ "$expected_bin" = "xray.sh" ]; then
          if ! grep -q "xray.sh" "/proc/$p/cmdline" 2>/dev/null; then
            rm -f "$p_file" 2>/dev/null || true
            return 0
          fi
        else
          local exe_target
          exe_target="$(readlink -f "/proc/$p/exe" 2>/dev/null || true)"
          exe_target="${exe_target% (deleted)}"
          if [ -n "$exe_target" ] && [ "$exe_target" != "$expected_bin" ]; then
            rm -f "$p_file" 2>/dev/null || true
            return 0
          fi
        fi
      fi
      kill "$p" 2>/dev/null || true
      local _t=0
      while kill -0 "$p" 2>/dev/null && [ $_t -lt 5 ]; do
        sleep 0.5
        _t=$((_t + 1))
      done
      if kill -0 "$p" 2>/dev/null; then
        kill -9 "$p" 2>/dev/null || true
      fi
    fi
    rm -f "$p_file" 2>/dev/null || true
  fi
}

# ── 14. 服务守护、运行与进程调度 ───────────────────────────────────────────────
do_run() {
  echo $$ > "$RUN_PID"
  load_env
  ensure_binaries
  generate_config || {
    if [ ! -s "$CONFIG_FILE" ]; then
      die "Xray 配置生成失败且无有效旧配置"
    fi
    warn "配置生成遇到问题，使用当前已存的有效配置文件启动"
  }

  log "正在预校验 Xray 配置文件语法..."
  if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then
    die "Xray 配置语法测试失败，请检查配置文件格式"
  fi
  log "Xray 语法校验通过 (Syntax OK)"

  # 若配置了 TURN 出口，优先拉起 turn2socks 转接守护
  if [ -f "$OUTBOUND_FILE" ] && [ "$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)" = "turn" ]; then
    start_turn2socks || true
  fi

  start_xray
  log "Xray 核心已启动 (PID: $(cat "$PID_FILE" 2>/dev/null || echo unknown))"
  start_cloudflared
  start_komari
  generate_sub
  log "所有服务已部署就绪，订阅链接已写入 $SUB_FILE"

  # 看门狗进程全组件守护
  while true; do
    if [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
      if ! (command -v pgrep >/dev/null 2>&1 && pgrep -f "$BIN_DIR/xray" >/dev/null 2>&1); then
        warn "检测到 Xray 核心意外退出，正在自动拉起守护..."
        start_xray
      fi
    fi

    # 守护 turn2socks
    if [ -f "$OUTBOUND_FILE" ] && [ "$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)" = "turn" ]; then
      if [ -f "$TURN2SOCKS_PID" ] && ! kill -0 "$(cat "$TURN2SOCKS_PID" 2>/dev/null)" 2>/dev/null; then
        warn "检测到 turn2socks 转接异常退出，正在自动拉起守护..."
        start_turn2socks || true
      fi
    fi

    # 守护 cloudflared
    if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ -x "$CF_BIN" ]; then
      if [ -f "$CF_PID" ] && ! kill -0 "$(cat "$CF_PID" 2>/dev/null)" 2>/dev/null; then
        warn "检测到 Cloudflared Argo 进程退出，正在自动拉起守护..."
        start_cloudflared
      fi
    fi

    # 守护 Komari 探针
    if [ -n "$(get_val KOMARI_DOMAIN)" ] && [ -n "$(get_val KOMARI_TOKEN)" ] && [ -x "$KM_BIN" ]; then
      if [ -f "$KM_PID" ] && ! kill -0 "$(cat "$KM_PID" 2>/dev/null)" 2>/dev/null; then
        warn "检测到 Komari 探针退出，正在自动拉起守护..."
        start_komari
      fi
    fi

    # 日志文件原地滚动截断守护 (单文件限制 10MB)
    rotate_log_if_needed "$LOG_FILE" 10
    rotate_log_if_needed "$CF_LOG" 10
    rotate_log_if_needed "$KM_LOG" 10
    rotate_log_if_needed "$TURN2SOCKS_LOG" 10

    sleep 10
  done
}

do_stop() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active "$SVC_NAME" >/dev/null 2>&1; then
    systemctl stop "$SVC_NAME" 2>/dev/null || true
  fi
  stop_pid_file "$RUN_PID" "xray.sh"
  stop_pid_file "$PID_FILE" "$XRAY_BIN"
  stop_pid_file "$CF_PID" "$CF_BIN"
  stop_pid_file "$KM_PID" "$KM_BIN"
  stop_turn2socks 2>/dev/null || true
  pkill -f "$BIN_DIR/xray" 2>/dev/null || true
  pkill -f "$BIN_DIR/cloudflared" 2>/dev/null || true
  pkill -f "$BIN_DIR/komari-agent" 2>/dev/null || true
  pkill -f "$APP_DIR/xray.sh run" 2>/dev/null || true
  rm -f "$RUN_PID" "$PID_FILE" "$CF_PID" "$KM_PID" 2>/dev/null || true
  log "Xray 及相关组件已全部安全停止"
}

do_restart() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
    systemctl restart "$SVC_NAME"
    log "已通过 Systemd 服务重载重启"
  else
    do_stop
    sleep 1
    nohup "$APP_DIR/xray.sh" run >/dev/null 2>&1 &
    log "已在后台重启服务"
  fi
}

# ── 15. Systemd 守护单元与全局快捷指令 ─────────────────────────────────────────
setup_systemd() {
  if [ "$(id -u)" != "0" ]; then
    warn "非 root 用户，跳过全局开机自启服务注册"
    return
  fi
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    cat > "/etc/systemd/system/${SVC_NAME}.service" << EOF
[Unit]
Description=Xray Universal Proxy Engine
# Generated-by: universal-xray-installer
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash ${APP_DIR}/xray.sh run
Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
    log "Systemd 系统级服务 (${SVC_NAME}.service) 注册完成"
  elif command -v rc-update >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
    cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run
# Generated-by: universal-xray-installer
name="xray"
description="Xray Universal Proxy Engine"
command="/bin/bash"
command_args="${APP_DIR}/xray.sh run"
command_background="yes"
pidfile="/run/xray.pid"

depend() {
  need net
  after firewall
}

stop_post() {
  /bin/bash "${APP_DIR}/xray.sh" stop
}
EOF
    chmod +x /etc/init.d/xray 2>/dev/null || true
    rc-update add xray default >/dev/null 2>&1 || true
    log "已通过 OpenRC (/etc/init.d/xray) 注册开机自启"
  elif command -v crontab >/dev/null 2>&1; then
    ensure_cron || true
    if ! crontab -l 2>/dev/null | grep -q "${APP_DIR}/xray.sh run"; then
      (crontab -l 2>/dev/null; echo "@reboot /bin/bash ${APP_DIR}/xray.sh run >/dev/null 2>&1 &") | crontab - 2>/dev/null || true
    fi
    log "检测到无 init 服务环境，已通过 crontab (@reboot) 注册开机自启"
  fi
}

setup_shortcuts() {
  [ "$(id -u)" = "0" ] || return 0
  local script_target="$APP_DIR/xray.sh"

  # 1. 确保核心脚本文件安全持久化，杜绝拷贝自身或拷贝 bash
  local _src_is_file=false
  case "$0" in
    /dev/*|/proc/*|bash|sh|-*) _src_is_file=false ;;
    *) [ -f "$0" ] && [ -s "$0" ] && _src_is_file=true ;;
  esac

  local real_src real_target
  real_src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  real_target="$(readlink -f "$script_target" 2>/dev/null || echo "$script_target")"

  if $_src_is_file && [ "$real_src" != "$real_target" ] && [ "$real_src" != "/bin/bash" ] && [ "$real_src" != "/usr/bin/bash" ]; then
    cp -f "$0" "$script_target" 2>/dev/null || true
  else
    if [ ! -s "$script_target" ] || ! grep -q "do_menu" "$script_target" 2>/dev/null; then
      log "正在保存管理脚本至 ${script_target}..."
      local SCRIPT_RAW="https://raw.githubusercontent.com/zaofengyue/xray/main/xray.sh"
      if ! download_file "$SCRIPT_RAW" "$script_target"; then
        curl -fsSL "$SCRIPT_RAW" -o "$script_target" 2>/dev/null || wget -qO "$script_target" "$SCRIPT_RAW" 2>/dev/null || true
      fi
    fi
  fi
  chmod +x "$script_target" 2>/dev/null || true

  # 2. 创建高可用 Wrapper 启动器，安全部署至系统路径
  create_shortcut_bin() {
    local bin_name="$1" subcmd="${2:-}"
    local wrapper_content
    wrapper_content="#!/usr/bin/env bash
APP_DIR=\"${APP_DIR}\"
TARGET=\"\$APP_DIR/xray.sh\"
if [ ! -s \"\$TARGET\" ]; then
  echo \"错误: 管理脚本 \$TARGET 缺失，请检查目录或重新安装\" >&2
  exit 1
fi
exec /bin/bash \"\$TARGET\" ${subcmd} \"\$@\""

    for dest_dir in /usr/local/bin /usr/bin; do
      if [ -d "$dest_dir" ] && [ -w "$dest_dir" ]; then
        # 若系统已有独立官方 xray 二进制（无论在 /usr/local/bin 还是 /usr/bin），绝不覆盖
        if [ "$bin_name" = "xray" ]; then
          if [ -f "$dest_dir/$bin_name" ] && ! grep -q "APP_DIR=" "$dest_dir/$bin_name" 2>/dev/null; then
            continue
          fi
        fi
        rm -f "$dest_dir/$bin_name" 2>/dev/null || true
        printf '%s\n' "$wrapper_content" > "$dest_dir/$bin_name"
        chmod +x "$dest_dir/$bin_name" 2>/dev/null || true
      fi
    done
  }

  create_shortcut_bin "xr" ""
  create_shortcut_bin "xray" ""
  create_shortcut_bin "xr-sub" "sub"
  create_shortcut_bin "xr-log" "log"
  create_shortcut_bin "xr-del" "del"
  create_shortcut_bin "xr-rollback" "rollback"
  create_shortcut_bin "xray-sub" "sub"
  create_shortcut_bin "xray-log" "log"
  create_shortcut_bin "xray-del" "del"
  create_shortcut_bin "xray-rollback" "rollback"

  # 3. 环境变量 PATH 安全补充（绝不新建破坏 Debian/Ubuntu 机制的 ~/.bash_profile）
  if [ -f "$HOME_DIR/.bashrc" ] && ! grep -q "/usr/local/bin" "$HOME_DIR/.bashrc" 2>/dev/null; then
    printf '\nexport PATH="/usr/local/bin:$PATH"\n' >> "$HOME_DIR/.bashrc" 2>/dev/null || true
  fi
  export PATH="/usr/local/bin:/usr/bin:$PATH"
}

# ── 16. 组件在线无感热升级与脚本自更新 ─────────────────────────────────────────
do_update_script() {
  clear
  echo -e "${GREEN}==================== 更新 xray.sh 管理脚本 ====================${RESET}"
  local SCRIPT_RAW="https://raw.githubusercontent.com/zaofengyue/xray/main/xray.sh"
  log "正在从 GitHub 检测并下载最新脚本..."
  local work tmp_sh
  work="$(mktemp -d "$APP_DIR/.dl.XXXXXX" 2>/dev/null || echo "$APP_DIR/.dl_$$")"
  mkdir -p "$work" && chmod 700 "$work"
  tmp_sh="$work/xray_update.sh"

  if download_file "$SCRIPT_RAW" "$tmp_sh"; then
    if [ -s "$tmp_sh" ] && bash -n "$tmp_sh" >/dev/null 2>&1 && grep -q 'do_menu' "$tmp_sh" 2>/dev/null; then
      cp -f "$APP_DIR/xray.sh" "$APP_DIR/xray.sh.bak" 2>/dev/null || true
      mv -f "$tmp_sh" "$APP_DIR/xray.sh"
      chmod +x "$APP_DIR/xray.sh"
      rm -rf "$work"
      log "管理脚本更新成功！正在自动重新进入管理面板..."
      sleep 2
      exec bash "$APP_DIR/xray.sh"
    else
      warn "更新包语法校验失败，已取消替换以保护系统完整性"
      rm -rf "$work"
    fi
  else
    warn "下载失败，请检查网络连接"
    rm -rf "$work"
  fi
  press_any_key
}

do_rollback() {
  clear
  echo -e "${GREEN}==================== 回退 xray.sh 管理脚本 ====================${RESET}"
  local bak_file="$APP_DIR/xray.sh.bak"
  if [ ! -f "$bak_file" ] || [ ! -s "$bak_file" ]; then
    warn "未找到有效的脚本备份文件 ($bak_file)，无法回退"
    press_any_key
    return 1
  fi

  log "正在校验备份脚本语法与完整性..."
  if ! bash -n "$bak_file" >/dev/null 2>&1 || ! grep -q 'do_menu' "$bak_file" 2>/dev/null; then
    warn "备份脚本语法校验失败或关键函数缺失，终止回退以保护系统"
    press_any_key
    return 1
  fi

  cp -f "$APP_DIR/xray.sh" "$APP_DIR/xray.sh.broken" 2>/dev/null || true
  cp -f "$bak_file" "$APP_DIR/xray.sh"
  chmod +x "$APP_DIR/xray.sh"
  log "管理脚本已成功回退至上一备份版本！正在重新进入管理面板..."
  sleep 2
  exec bash "$APP_DIR/xray.sh"
}

menu_update() {
  clear
  echo -e "${GREEN}==================== 组件在线升级 ====================${RESET}"
  local cur_xray="未安装"
  [ -x "$XRAY_BIN" ] && cur_xray="$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  echo -e "当前 Xray 核心版本: ${CYAN}${cur_xray}${RESET}"
  echo -e "${GREEN}----------------------------------------------------${RESET}"
  echo -e "${WHITE} 1. 升级 Xray 核心${RESET}"
  echo -e "${WHITE} 2. 升级 Argo 引擎${RESET}"
  echo -e "${WHITE} 3. 升级 Komari 探针${RESET}"
  echo -e "${WHITE} 4. 更新管理脚本${RESET}"
  if [ -f "$APP_DIR/xray.sh.bak" ]; then
    echo -e "${WHITE} 5. 回退管理脚本 (至上一备份版本)${RESET}"
  fi
  echo -e "${WHITE} 0. 返回面板${RESET}"
  echo -e "${GREEN}----------------------------------------------------${RESET}"
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
    5)
      if [ -f "$APP_DIR/xray.sh.bak" ]; then
        do_rollback
      else
        warn "无效选项"
        press_any_key
      fi
      ;;
    0) return ;;
  esac
}

# ── 17. 交互式智能安装向导 (do_install) ─────────────────────────────────────────
do_install() {
  clear
  echo -e "${GREEN}====================================================${RESET}"
  echo -e "${WHITE}               Xray 智能自动化部署向导               ${RESET}"
  echo -e "${GREEN}====================================================${RESET}"
  ensure_basic_deps

  echo -e "${WHITE}请选择安装模式:${RESET}"
  echo -e "  ${CYAN}1. 快速安装${RESET}"
  echo -e "  ${CYAN}2. 自定义安装${RESET}"
  echo -e "  ${CYAN}0. 取消安装${RESET}"
  echo -e "${GREEN}----------------------------------------------------${RESET}"
  local inst_mode
  read -p "请输入选项 [默认 1]: " inst_mode
  inst_mode="${inst_mode:-1}"

  case "$inst_mode" in
    0) return ;;
    1|2) ;;
    *) inst_mode=1 ;;
  esac

  local in_uuid in_name in_disable_argo in_argo_domain in_argo_auth in_pref_host
  local in_reality_port in_xhttp_port in_reality_domain in_ss_port in_ss_pass in_s5_port in_s5_user in_s5_pass in_trojan_port

  in_uuid="$(get_uuid)"
  in_name="$(get_node_name_prefix)"

  if [ "$inst_mode" = "1" ]; then
    log "正在自动生成优选参数与探测闲置高位端口 (10000+)..."
    rm -f "$USED_PORTS_FILE"
    in_reality_port="$(get_random_high_port)"
    in_xhttp_port="$(get_random_high_port)"
    in_ss_port="$(get_random_high_port)"
    in_s5_port=""
    in_trojan_port=""
    in_disable_argo="false"
    in_argo_domain=""
    in_argo_auth=""
    in_reality_domain="www.iij.ad.jp"
    in_pref_host="www.visa.com.tw"
    in_ss_pass="$(get_ss2022_key "")"
    read -r in_s5_user in_s5_pass <<< "$(get_socks5_creds)"
  else
    echo ""
    echo -e "${YELLOW}--- 基础参数设置 ---${RESET}"
    read -p "用户 UUID [默认 ${in_uuid}]: " custom_u
    if [ -n "$custom_u" ]; then
      if ! is_valid_uuid "$custom_u"; then
        warn "输入的 UUID 格式不合法，已自动采用生成的合规 UUID"
      else
        in_uuid="$custom_u"
      fi
    fi
    read -p "节点名称前缀 [默认 ${in_name}]: " custom_n
    in_name="${custom_n:-$in_name}"

    echo ""
    echo -e "${YELLOW}--- Cloudflare Argo 穿透设置 ---${RESET}"
    read -p "是否启用 Argo 穿透？[Y/n，默认 Y]: " argo_c
    case "$argo_c" in
      n|N) in_disable_argo="true" ;;
      *)
        in_disable_argo="false"
        read -p "Argo 固定域名 [留空使用临时隧道]: " in_argo_domain
        in_argo_domain="$(printf '%s' "$in_argo_domain" | tr -d '[:space:]')"
        if [ -n "$in_argo_domain" ]; then
          read -s -p "Argo Tunnel Token: " in_argo_auth
          echo ""
          in_argo_auth="$(printf '%s' "$in_argo_auth" | tr -d '[:space:]')"
        fi
        read -p "Cloudflare 优选域名/IP [默认 www.visa.com.tw]: " in_pref_host
        in_pref_host="${in_pref_host:-www.visa.com.tw}"
        ;;
    esac

    echo ""
    echo -e "${YELLOW}--- 直连协议端口分配 (默认自动探测 10000+ 闲置高位端口) ---${RESET}"
    rm -f "$USED_PORTS_FILE"
    local rec_r rec_xh rec_ss
    rec_r="$(get_random_high_port)"
    rec_xh="$(get_random_high_port)"
    rec_ss="$(get_random_high_port)"

    local chosen_ports=""
    in_reality_port="$(prompt_port "Reality TCP 端口 [默认推荐高位 ${rec_r}，填 0 关闭]: " "$rec_r" "$chosen_ports")"
    [ -n "$in_reality_port" ] && chosen_ports="$chosen_ports $in_reality_port"

    in_xhttp_port="$(prompt_port "Reality xhttp 端口 [默认推荐高位 ${rec_xh}，填 0 关闭]: " "$rec_xh" "$chosen_ports")"
    [ -n "$in_xhttp_port" ] && chosen_ports="$chosen_ports $in_xhttp_port"

    if [ -n "$in_reality_port" ] || [ -n "$in_xhttp_port" ]; then
      read -p "Reality 伪装域名 [默认 www.iij.ad.jp]: " in_reality_domain
      in_reality_domain="${in_reality_domain:-www.iij.ad.jp}"
      in_reality_domain="$(printf '%s' "$in_reality_domain" | tr -d '[:space:]')"
    fi

    in_ss_port="$(prompt_port "Shadowsocks 2022 端口 [默认推荐高位 ${rec_ss}，填 0 关闭]: " "$rec_ss" "$chosen_ports")"
    [ -n "$in_ss_port" ] && chosen_ports="$chosen_ports $in_ss_port"
    if [ -n "$in_ss_port" ]; then
      read -s -p "SS 密码 [留空随机生成]: " in_ss_pass
      echo ""
      in_ss_pass="$(get_ss2022_key "$in_ss_pass")"
    fi

    in_s5_port="$(prompt_port "SOCKS5 端口 [填 0 或留空关闭]: " "0" "$chosen_ports")"
    [ -n "$in_s5_port" ] && chosen_ports="$chosen_ports $in_s5_port"
    read -r in_s5_user in_s5_pass <<< "$(get_socks5_creds)"
    if [ -n "$in_s5_port" ]; then
      read -p "SOCKS5 用户名 [默认 ${in_s5_user}]: " custom_s5_u
      in_s5_user="$(printf '%s' "${custom_s5_u:-$in_s5_user}" | tr -d '[:space:]"' | tr -d "'")"
      read -s -p "SOCKS5 密码 [默认 ${in_s5_pass}]: " custom_s5_p
      echo ""
      in_s5_pass="$(printf '%s' "${custom_s5_p:-$in_s5_pass}" | tr -d '[:space:]"' | tr -d "'")"
    fi

    in_trojan_port="$(prompt_port "Trojan-TCP 端口 [填 0 或留空关闭]: " "0" "$chosen_ports")"
    [ -n "$in_trojan_port" ] && chosen_ports="$chosen_ports $in_trojan_port"
    if [ -n "$in_trojan_port" ]; then
      local in_trojan_pass
      read -s -p "Trojan 密码 [留空自动生成]: " in_trojan_pass
      echo ""
      if [ -n "$in_trojan_pass" ]; then
        in_trojan_pass="$(printf '%s' "$in_trojan_pass" | tr -d '[:space:]@#/?&:"' | tr -d "'")"
        set_val TROJAN_PASS "$in_trojan_pass"
      fi
    fi
  fi

  # 保存配置
  set_val UUID "$in_uuid"
  set_val NAME "$in_name"
  set_val DISABLE_ARGO "${in_disable_argo:-false}"
  set_val ARGO_DOMAIN "${in_argo_domain:-}"
  set_val ARGO_AUTH "${in_argo_auth:-}"
  set_val CF_PREFER_HOST "${in_pref_host:-www.visa.com.tw}"

  set_val REALITY_PORT "${in_reality_port:-}"
  set_val XHTTP_PORT "${in_xhttp_port:-}"
  set_val REALITY_DOMAIN "${in_reality_domain:-www.iij.ad.jp}"
  set_val SS_PORT "${in_ss_port:-}"
  set_val SS_PASS "${in_ss_pass:-}"
  set_val S5_PORT "${in_s5_port:-}"
  set_val S5_USER "${in_s5_user:-}"
  set_val S5_PASS "${in_s5_pass:-}"
  set_val TROJAN_PORT "${in_trojan_port:-}"

  open_firewall_port "$in_reality_port" tcp
  open_firewall_port "$in_xhttp_port" tcp
  open_firewall_port "$in_trojan_port" tcp
  open_firewall_port "$in_ss_port" both
  open_firewall_port "$in_s5_port" both

  log "正在准备组件与二进制核心..."
  ensure_binaries || { warn "二进制安装准备失败，请检查网络或架构支持"; press_any_key; return 1; }
  generate_config || { warn "初始配置生成失败，请检查日志排查"; press_any_key; return 1; }
  setup_systemd
  setup_shortcuts
  touch "$APP_DIR/.xray_installed" 2>/dev/null || true

  log "正在启动 Xray 服务..."
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
    systemctl restart "$SVC_NAME"
  else
    do_stop
    sleep 1
    nohup "$APP_DIR/xray.sh" run >/dev/null 2>&1 &
  fi

  if [ "${in_disable_argo:-false}" != "true" ]; then
    log "正在建立 Cloudflare Argo 隧道并获取临时域名..."
    local cf_wait=0 cur_argo=""
    while [ $cf_wait -lt 25 ]; do
      cur_argo="$(get_val ARGO_DOMAIN)"
      if [ -n "$cur_argo" ] && [ "$cur_argo" != "your-domain.com" ]; then
        break
      fi
      if [ -f "$CF_LOG" ]; then
        local found_h
        found_h="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | grep -v 'api\.trycloudflare\.com' | tail -n 1 | sed 's|https://||')"
        if [ -n "$found_h" ]; then
          set_val ARGO_DOMAIN "$found_h"
          break
        fi
      fi
      sleep 1
      cf_wait=$((cf_wait + 1))
    done
  fi

  generate_sub
  log "恭喜！Xray Universal Proxy Engine 部署成功！"
  show_sub
}

# ── 18. 日志查看器 (do_log) ──────────────────────────────────────────────────
do_log() {
  clear
  echo -e "${GREEN}================ 实时运行日志追踪 ================${RESET}"
  echo -e "${WHITE} 1. Xray 核心运行日志${RESET}"
  echo -e "${WHITE} 2. Argo 隧道穿透日志${RESET}"
  echo -e "${WHITE} 3. Komari 探针监控日志${RESET}"
  echo -e "${WHITE} 4. turn2socks 转接日志${RESET}"
  echo -e "${WHITE} 0. 返回面板${RESET}"
  echo -e "${GREEN}----------------------------------------------------${RESET}"
  read -p "请输入选项 [0-4]: " log_c
  case "$log_c" in
    1)
      clear
      echo -e "${GREEN}=== Xray 核心日志 (Ctrl+C 返回菜单) ===${RESET}"
      if [ -f "$LOG_FILE" ]; then
        trap ' ' INT
        tail -n 60 -f "$LOG_FILE"
        trap - INT
      else
        warn "暂无核心日志文件"
        press_any_key
      fi
      ;;
    2)
      clear
      echo -e "${GREEN}=== Argo 隧道日志 (Ctrl+C 返回菜单) ===${RESET}"
      if [ -f "$CF_LOG" ]; then
        trap ' ' INT
        tail -n 60 -f "$CF_LOG"
        trap - INT
      else
        warn "暂无隧道日志文件"
        press_any_key
      fi
      ;;
    3)
      clear
      echo -e "${GREEN}=== Komari 探针日志 (Ctrl+C 返回菜单) ===${RESET}"
      if [ -f "$KM_LOG" ]; then
        trap ' ' INT
        tail -n 60 -f "$KM_LOG"
        trap - INT
      else
        warn "暂无探针日志文件"
        press_any_key
      fi
      ;;
    4)
      clear
      echo -e "${GREEN}=== turn2socks 转接日志 (Ctrl+C 返回菜单) ===${RESET}"
      if [ -f "$TURN2SOCKS_LOG" ]; then
        trap ' ' INT
        tail -n 60 -f "$TURN2SOCKS_LOG"
        trap - INT
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
    echo -e "${GREEN}================ 节点订阅与配置导出 ================${RESET}"
    if [ ! -f "$SUB_FILE" ]; then
      warn "尚未生成订阅文件，请先启动 Xray 服务"
      press_any_key
      return
    fi

    echo -e "${WHITE} 1. 查看明文节点链接${RESET}"
    echo -e "${WHITE} 2. 查看 Base64 订阅文本${RESET}"
    echo -e "${WHITE} 3. 查看 Clash Meta 规则配置${RESET}"
    echo -e "${WHITE} 4. 查看 Xray 客户端 JSON 配置${RESET}"
    echo -e "${WHITE} 5. 导出配置至本地文本文件${RESET}"
    echo -e "${YELLOW} 提示: 若连接超时，请务必在云服务器控制台安全组放行上述端口 (TCP/UDP)${RESET}"
    echo -e "${WHITE} 0. 返回面板${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    read -p "请输入选项 [0-5]: " s_opt
    case "$s_opt" in
      1)
        clear
        echo -e "${GREEN}=== 明文节点链接 (直接导入客户端) ===${RESET}\n"
        [ -f "$SUB_RAW_FILE" ] && cat "$SUB_RAW_FILE"
        if [ -f "$TG_S5_FILE" ]; then
          echo -e "\n${CYAN}=== Telegram 专属一键代理链接 ===${RESET}"
          cat "$TG_S5_FILE"
        fi
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
        clear
        echo -e "${GREEN}=== Xray 客户端 JSON 配置 ===${RESET}\n"
        if [ -f "$XRAY_CLIENT_FILE" ]; then
          cat "$XRAY_CLIENT_FILE"
        else
          warn "未启用 Reality 直连协议，暂无对应客户端 JSON 配置文件"
        fi
        press_any_key
        ;;
      5)
        local out_dump="$APP_DIR/all_sub_export.txt"
        {
          echo "==================== Xray 节点订阅明细 ===================="
          [ -f "$SUB_RAW_FILE" ] && cat "$SUB_RAW_FILE"
          [ -f "$TG_S5_FILE" ] && { echo -e "\n==================== Telegram 代理链接 ===================="; cat "$TG_S5_FILE"; }
          echo -e "\n==================== Base64 订阅 ===================="
          [ -f "$SUB_FILE" ] && cat "$SUB_FILE"
          echo -e "\n==================== Clash Meta 配置 ===================="
          [ -f "$CLASH_META_FILE" ] && cat "$CLASH_META_FILE"
          if [ -f "$XRAY_CLIENT_FILE" ]; then
            echo -e "\n==================== Xray 客户端 JSON 配置 ===================="
            cat "$XRAY_CLIENT_FILE"
          fi
        } > "$out_dump"
        chmod 600 "$out_dump" 2>/dev/null || true
        log "已导出完整订阅配置文件至: ${CYAN}${out_dump}${RESET}"
        press_any_key
        ;;
      0) return ;;
    esac
  done
}

# ── 20. 参数与协议精细化管理菜单 (menu_config) ────────────────────────────────
menu_config() {
  local config_modified=0
  while true; do
    clear
    local cur_u cur_rp cur_xp cur_rd cur_sp cur_s5 cur_tp cur_argo cur_pref cur_km cur_srv
    cur_u="$(get_val UUID)"
    cur_rp="$(get_val REALITY_PORT "未启用")"
    cur_xp="$(get_val XHTTP_PORT "未启用")"
    cur_rd="$(get_val REALITY_DOMAIN "www.iij.ad.jp")"
    cur_sp="$(get_val SS_PORT "未启用")"
    cur_s5="$(get_val S5_PORT "未启用")"
    cur_tp="$(get_val TROJAN_PORT "未启用")"

    if [ "$(get_val DISABLE_ARGO)" = "true" ]; then
      cur_argo="禁用"
    elif [ -n "$(get_val ARGO_DOMAIN)" ] && [ -n "$(get_val ARGO_AUTH)" ]; then
      cur_argo="固定隧道"
    else
      cur_argo="临时隧道"
    fi

    cur_pref="$(get_val CF_PREFER_HOST "www.visa.com.tw")"
    cur_km="$(get_val KOMARI_DOMAIN "未配置")"
    cur_srv="$(get_val SERVER_DOMAIN "自动探测")"

    local reality_display
    if [ "$cur_rp" != "未启用" ] && [ "$cur_xp" != "未启用" ]; then
      reality_display="TCP:${cur_rp} | xhttp:${cur_xp} | Reality 域名: ${cur_rd}"
    elif [ "$cur_rp" != "未启用" ]; then
      reality_display="${cur_rp} | Reality 域名: ${cur_rd}"
    elif [ "$cur_xp" != "未启用" ]; then
      reality_display="xhttp:${cur_xp} | Reality 域名: ${cur_rd}"
    else
      reality_display="未启用"
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${WHITE}                    修改参数配置                    ${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 1. 用户 UUID           : ${CYAN}${cur_u}${RESET}"
    echo -e "${WHITE} 2. Reality 端口        : ${CYAN}${reality_display}${RESET}"
    echo -e "${WHITE} 3. Shadowsocks 端口    : ${CYAN}${cur_sp}${RESET}"
    echo -e "${WHITE} 4. SOCKS5 协议端口     : ${CYAN}${cur_s5}${RESET}"
    echo -e "${WHITE} 5. Trojan 协议端口     : ${CYAN}${cur_tp}${RESET}"
    echo -e "${WHITE} 6. Argo 隧道管理       : ${CYAN}${cur_argo}${RESET}"
    echo -e "${WHITE} 7. CDN 优选域名        : ${CYAN}${cur_pref}${RESET}"
    echo -e "${WHITE} 8. Komari 探针         : ${CYAN}${cur_km}${RESET}"
    echo -e "${WHITE} 9. 全局连接地址        : ${CYAN}${cur_srv}${RESET}"
    echo -e "${WHITE} 0. 返回面板${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    read -p "请输入修改项 [0-9]: " c_opt
    case "$c_opt" in
      1)
        read -p "请输入新 UUID [留空自动生成]: " new_u
        if [ -n "$new_u" ]; then
          if ! is_valid_uuid "$new_u"; then
            warn "输入的 UUID 格式不合法 (必须符合 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 规范)"
            press_any_key
            continue
          fi
        else
          if [ -x "$XRAY_BIN" ]; then
            new_u="$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]')"
          fi
          [ -z "$new_u" ] && [ -r /proc/sys/kernel/random/uuid ] && new_u="$(cat /proc/sys/kernel/random/uuid | tr -d '[:space:]')"
          [ -z "$new_u" ] && command -v uuidgen >/dev/null 2>&1 && new_u="$(uuidgen | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        fi
        set_val UUID "$new_u"
        echo "$new_u" > "$UUID_FILE"
        config_modified=1
        log "UUID 已更新为: ${CYAN}${new_u}${GREEN}"
        sleep 1
        ;;
      2)
        local cur_other_p="$cur_sp $cur_s5 $cur_tp"
        new_rp="$(prompt_port "Reality TCP 端口 [默认 ${cur_rp}，填 0 关闭]: " "$cur_rp" "$cur_other_p")"
        new_xp="$(prompt_port "Reality xhttp 端口 [默认 ${cur_xp}，填 0 关闭]: " "$cur_xp" "$new_rp $cur_other_p")"

        set_val REALITY_PORT "$new_rp"
        set_val XHTTP_PORT "$new_xp"

        if [ -n "$new_rp" ] || [ -n "$new_xp" ]; then
          read -p "Reality 伪装域名 [默认 ${cur_rd}]: " new_rd
          new_rd="${new_rd:-$cur_rd}"
          new_rd="$(printf '%s' "$new_rd" | tr -d '[:space:]')"
          if ! validate_domain_name "$new_rd"; then
            warn "域名格式非法，包含非法字符"
            press_any_key
            continue
          fi
          set_val REALITY_DOMAIN "${new_rd:-www.iij.ad.jp}"
        fi
        [ -n "$cur_rp" ] && [ "$cur_rp" != "未启用" ] && [ "$cur_rp" != "$new_rp" ] && close_firewall_port "$cur_rp" tcp
        [ -n "$cur_xp" ] && [ "$cur_xp" != "未启用" ] && [ "$cur_xp" != "$new_xp" ] && close_firewall_port "$cur_xp" tcp
        [ -n "$new_rp" ] && open_firewall_port "$new_rp" tcp
        [ -n "$new_xp" ] && open_firewall_port "$new_xp" tcp
        config_modified=1
        log "Reality 配置已更新 (公私钥保持稳定)"
        sleep 1
        ;;
      3)
        local cur_other_p="$cur_rp $cur_xp $cur_s5 $cur_tp"
        new_sp="$(prompt_port "Shadowsocks 端口 [默认 ${cur_sp}，填 0 关闭]: " "$cur_sp" "$cur_other_p")"
        [ -n "$cur_sp" ] && [ "$cur_sp" != "未启用" ] && [ "$cur_sp" != "$new_sp" ] && close_firewall_port "$cur_sp" both
        set_val SS_PORT "$new_sp"
        if [ -n "$new_sp" ]; then
          read -s -p "Shadowsocks 密码 [留空保持原值/随机生成]: " new_pass
          echo ""
          if [ -n "$new_pass" ]; then
            new_pass="$(get_ss2022_key "$new_pass")"
            set_val SS_PASS "$new_pass"
          else
            # 若之前未设置过密码（如自定义安装时关闭，后在菜单开启且留空），确保生成并持久化有效密码
            get_ss_pass >/dev/null
          fi
          open_firewall_port "$new_sp" both
        fi
        config_modified=1
        log "Shadowsocks 配置已更新"
        sleep 1
        ;;
      4)
        local cur_other_p="$cur_rp $cur_xp $cur_sp $cur_tp"
        new_s5="$(prompt_port "SOCKS5 协议端口 [默认 ${cur_s5}，填 0 关闭]: " "$cur_s5" "$cur_other_p")"
        [ -n "$cur_s5" ] && [ "$cur_s5" != "未启用" ] && [ "$cur_s5" != "$new_s5" ] && close_firewall_port "$cur_s5" both
        set_val S5_PORT "$new_s5"
        if [ -n "$new_s5" ]; then
          local cur_s5_u cur_s5_p
          read -r cur_s5_u cur_s5_p <<< "$(get_socks5_creds)"
          read -p "SOCKS5 用户名 [默认 ${cur_s5_u}]: " new_s5_u
          new_s5_u="$(printf '%s' "${new_s5_u:-$cur_s5_u}" | tr -d '[:space:]"' | tr -d "'")"
          set_val S5_USER "$new_s5_u"
          read -s -p "SOCKS5 密码 [默认 ${cur_s5_p}]: " new_s5_p
          echo ""
          new_s5_p="$(printf '%s' "${new_s5_p:-$cur_s5_p}" | tr -d '[:space:]"' | tr -d "'")"
          set_val S5_PASS "$new_s5_p"
          open_firewall_port "$new_s5" both
        fi
        config_modified=1
        log "SOCKS5 配置已更新"
        sleep 1
        ;;
      5)
        local cur_other_p="$cur_rp $cur_xp $cur_sp $cur_s5"
        new_tp="$(prompt_port "Trojan 协议端口 [默认 ${cur_tp}，填 0 关闭]: " "$cur_tp" "$cur_other_p")"
        [ -n "$cur_tp" ] && [ "$cur_tp" != "未启用" ] && [ "$cur_tp" != "$new_tp" ] && close_firewall_port "$cur_tp" tcp
        set_val TROJAN_PORT "$new_tp"
        if [ -n "$new_tp" ]; then
          open_firewall_port "$new_tp" tcp
          local cur_tr_p
          cur_tr_p="$(get_trojan_pass)"
          read -s -p "Trojan 密码 [留空保持原值/自动生成]: " new_tr_p
          echo ""
          if [ -n "$new_tr_p" ]; then
            new_tr_p="$(printf '%s' "$new_tr_p" | tr -d '[:space:]@#/?&:"' | tr -d "'")"
            set_val TROJAN_PASS "$new_tr_p"
          fi
        fi
        config_modified=1
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
            new_ad="$(printf '%s' "$new_ad" | tr -d '[:space:]')"
            set_val ARGO_DOMAIN "$new_ad"
            if [ -n "$new_ad" ]; then
              read -s -p "Argo Tunnel Token: " new_at
              echo ""
              new_at="$(printf '%s' "$new_at" | tr -d '[:space:]')"
              set_val ARGO_AUTH "$new_at"
            fi
            ;;
        esac
        config_modified=1
        log "Argo 隧道设置已更新"
        sleep 1
        ;;
      7)
        read -p "Cloudflare CDN 优选域名/IP [默认 www.visa.com.tw]: " new_pref
        new_pref="$(printf '%s' "${new_pref:-www.visa.com.tw}" | tr -d '[:space:]')"
        set_val CF_PREFER_HOST "$new_pref"
        config_modified=1
        log "CDN 优选域名已更新"
        sleep 1
        ;;
      8)
        read -p "Komari 服务端域名 [留空关闭]: " new_kd
        new_kd="$(printf '%s' "$new_kd" | tr -d '[:space:]')"
        set_val KOMARI_DOMAIN "$new_kd"
        if [ -n "$new_kd" ]; then
          read -s -p "Komari 探针 Token: " new_kt
          echo ""
          new_kt="$(printf '%s' "$new_kt" | tr -d '[:space:]')"
          set_val KOMARI_TOKEN "$new_kt"
        fi
        config_modified=1
        log "Komari 探针配置已更新"
        sleep 1
        ;;
      9)
        read -p "自定义连接域名/IP [留空恢复自动探测]: " new_dom
        new_dom="$(printf '%s' "$new_dom" | tr -d '[:space:]')"
        if [[ "$new_dom" =~ [\"\\\'\<\>\;\&] ]]; then
          warn "连接地址格式非法"
          press_any_key
          continue
        fi
        set_val SERVER_DOMAIN "$new_dom"
        config_modified=1
        log "连接地址已更新"
        sleep 1
        ;;
      0)
        if [ "$config_modified" = "1" ]; then
          log "配置已变更，正在平滑重启服务生效..."
          do_restart
        else
          log "未作任何更改，直接返回面板"
        fi
        return
        ;;
    esac
  done
}

# ── 21. 服务生命周期管理 (menu_service) ──────────────────────────────────────────
menu_service() {
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
    echo -e "${GREEN}==================== Xray 服务管理 ====================${RESET}"
    echo -e "当前运行状态: ${st_desc}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 1. 启动服务${RESET}"
    echo -e "${WHITE} 2. 停止服务${RESET}"
    echo -e "${WHITE} 3. 重启服务${RESET}"
    echo -e "${WHITE} 0. 返回面板${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    read -p "请输入选项 [0-3]: " s_opt
    case "$s_opt" in
      1)
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
          systemctl start "$SVC_NAME"
        else
          nohup "$0" run >/dev/null 2>&1 &
        fi
        log "服务已发起启动"
        sleep 2
        ;;
      2)
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
          systemctl stop "$SVC_NAME"
        else
          do_stop
        fi
        log "服务已停止"
        sleep 1
        ;;
      3)
        do_restart
        sleep 2
        ;;
      0) return ;;
    esac
  done
}

# ── 22. 主交互式运维控制面板 (do_menu) ─────────────────────────────────────────
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
    local pub_ip node_prefix
    pub_ip="$(get_public_ip)"
    node_prefix="$(get_node_name_prefix)"

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${WHITE}               Xray 综合管理控制面板               ${RESET}"
    echo -e "${GRAY}系统状态: ${st_desc} | 核心版本: ${CYAN}${x_ver}${RESET}"
    echo -e "${GRAY}公网地址: ${CYAN}${pub_ip}${RESET} | 节点归属: ${CYAN}${node_prefix}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${WHITE} 1. 查看节点${RESET}"
    echo -e "${WHITE} 2. 查看日志${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 3. 服务管理${RESET}"
    echo -e "${WHITE} 4. 升级更新${RESET}"
    echo -e "${WHITE} 5. 卸载清除${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 6. 修改配置${RESET}"
    echo -e "${WHITE} 7. 出口设置${RESET}"
    echo -e "${WHITE} 8. 域名证书${RESET}"
    echo -e "${WHITE} 9. 重新安装${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${WHITE} 0. 退出面板${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    read -p "请输入选项 [0-9]: " opt
    case "$opt" in
      1) show_sub ;;
      2) do_log ;;
      3) menu_service ;;
      4) menu_update ;;
      5) do_uninstall ;;
      6) menu_config ;;
      7) menu_outbound ;;
      8) menu_domain_cert ;;
      9) do_install ;;
      0) exit 0 ;;
    esac
  done
}

# 判断某个服务文件是否由本脚本生成：新版带标记行；旧版无标记，则以 ExecStart/command 指向本安装目录为准
_is_our_unit() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q "Generated-by: universal-xray-installer" "$f" 2>/dev/null && return 0
  grep -qF "${APP_DIR}/xray.sh" "$f" 2>/dev/null
}

do_uninstall() {
  read -p "确定要彻底卸载 Xray 与全部配置文件和快捷方式吗? [y/N]: " confirm
  case "$confirm" in
    y|Y)
      do_stop
      if _is_our_unit "/etc/systemd/system/${SVC_NAME}.service"; then
        if command -v systemctl >/dev/null 2>&1; then
          systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
          systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${SVC_NAME}.service"
      fi
      if _is_our_unit "/etc/init.d/xray"; then
        if command -v rc-update >/dev/null 2>&1; then
          rc-update del xray default >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/xray"
      fi
      if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "${APP_DIR}/xray.sh run" | crontab - 2>/dev/null || true
      fi

      # 清理之前放行的防火墙端口规则
      if [ -f "$ENV_FILE" ]; then
        local p_real p_xhttp p_tro p_ss p_s5
        p_real="$(get_val REALITY_PORT)"
        p_xhttp="$(get_val XHTTP_PORT)"
        p_tro="$(get_val TROJAN_PORT)"
        p_ss="$(get_val SS_PORT)"
        p_s5="$(get_val S5_PORT)"
        [ -n "$p_real" ]  && close_firewall_port "$p_real" tcp
        [ -n "$p_xhttp" ] && close_firewall_port "$p_xhttp" tcp
        [ -n "$p_tro" ]   && close_firewall_port "$p_tro" tcp
        [ -n "$p_ss" ]    && close_firewall_port "$p_ss" both
        [ -n "$p_s5" ]    && close_firewall_port "$p_s5" both
      fi

      local shortcuts=("xr" "xray" "xr-sub" "xr-log" "xr-del" "xr-rollback" "xray-sub" "xray-log" "xray-del" "xray-rollback")
      for d in /usr/local/bin /usr/bin; do
        for n in "${shortcuts[@]}"; do
          local target_path="$d/$n"
          if [ -f "$target_path" ]; then
            if grep -q "APP_DIR=" "$target_path" 2>/dev/null; then
              rm -f "$target_path"
            elif [ "$n" != "xray" ]; then
              rm -f "$target_path"
            fi
          fi
        done
      done
      # 仅精准清理本安装目录下的 acme.sh 证书续签与 xray 守护任务，绝不影响系统其他任务
      if [ -n "$ACME_HOME" ] && [ -n "$APP_DIR" ] && command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -vF "${ACME_HOME}/" | grep -vF "${APP_DIR}/" | crontab - 2>/dev/null) || true
      fi
      # 防误删校验：必须检测到本脚本的安装标识或状态配置文件方可执行递归清理
      if [ -n "$APP_DIR" ] && [ "$APP_DIR" != "/" ] && [ "$APP_DIR" != "/root" ]; then
        if [ -f "$APP_DIR/.xray_installed" ] || [ -f "$STATE_DIR/config.json" ] || [ -f "$ENV_FILE" ]; then
          rm -rf "$APP_DIR"
        fi
      fi
      log "已彻底清理并完成卸载"
      exit 0
      ;;
    *)
      log "已取消卸载"
      ;;
  esac
}

# ── 22. 命令行与快捷指令入口分发 ───────────────────────────────────────────────
setup_shortcuts

case "${1:-}" in
  run)      do_run ;;
  stop)
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
      systemctl stop "$SVC_NAME"
      log "Xray 系统服务已通过 systemctl 停止"
    else
      do_stop
    fi
    ;;
  restart)  do_restart ;;
  sub)      show_sub ;;
  log)      do_log ;;
  install)  do_install ;;
  update)   menu_update ;;
  rollback) do_rollback ;;
  del)      do_uninstall ;;
  *)
    if [ ! -x "$XRAY_BIN" ]; then
      do_install
    else
      do_menu
    fi
    ;;
esac
