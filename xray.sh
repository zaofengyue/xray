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

# 当脚本通过 curl | bash 等管道执行时，若有可用终端则重定向 stdin 以保障交互正常
if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
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
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _missing="$_missing curl"
  command -v tar >/dev/null 2>&1 || _missing="$_missing tar"
  command -v unzip >/dev/null 2>&1 || _missing="$_missing unzip"
  command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
  command -v socat >/dev/null 2>&1 || _missing="$_missing socat"
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || _missing="$_missing iproute2"
  command -v pgrep >/dev/null 2>&1 || _missing="$_missing procps"
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

  # 严格校验 SHA256 安全哈希，防范中间人攻击 (复用 download_file 确保纯 IPv6/NAT64 兼容)
  local exp_sha=""
  if download_file "${url}.dgst" "$dgst_file"; then
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
  extract_zip "$tmpzip" "$extract_tmp"
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
  download_file "$url" "$CF_BIN" || { warn "下载 cloudflared 失败"; return 1; }
  chmod +x "$CF_BIN"
  local ver_out
  ver_out="$("$CF_BIN" --version 2>/dev/null | head -1)"
  if [[ "$ver_out" != *"cloudflared version"* ]]; then
    rm -f "$CF_BIN"
    warn "cloudflared 二进制自检失败 (输出异常或无法在当前架构运行)"
    return 1
  fi
  log "Cloudflared 部署就绪: ${ver_out}"
  return 0
}

download_komari() {
  log "正在下载 komari-agent (探针)..."
  local kmarch url
  kmarch="$(detect_km_arch)"
  url="https://github.com/komari-monitoring/komari-agent/releases/latest/download/komari-agent_${kmarch}"
  download_file "$url" "$KM_BIN" || { warn "下载 komari-agent 失败"; return 1; }
  chmod +x "$KM_BIN"
  if ! "$KM_BIN" --help >/dev/null 2>&1 && ! "$KM_BIN" -h >/dev/null 2>&1 && ! "$KM_BIN" -v >/dev/null 2>&1; then
    if command -v file >/dev/null 2>&1 && ! file "$KM_BIN" | grep -qi "ELF"; then
      rm -f "$KM_BIN"
      warn "komari-agent 下载文件格式非法，非有效 ELF 架构二进制"
      return 1
    fi
  fi
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
  for d in "$script_dir/turn2socks" "$PWD/turn2socks" "$APP_DIR/turn2socks"; do
    if [ -f "$d/main.go" ]; then
      local_src="$d"
      break
    fi
  done

  # 1.1 若本地有预置的同架构二进制，直接拷贝复用
  for b in "$script_dir/turn2socks-linux-${t2s_arch}" "$script_dir/bin/turn2socks" "$script_dir/turn2socks"; do
    if [ -x "$b" ] && [ ! -d "$b" ]; then
      cp -f "$b" "$TURN2SOCKS_BIN"
      chmod +x "$TURN2SOCKS_BIN"
      log "turn2socks 组件已就绪 (复用本地预置: $b)"
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
  local primary_url="https://github.com/zaofengyue/xray/releases/download/latest/turn2socks-linux-${t2s_arch}"
  local fallback_url="https://github.com/zaofengyue/singbox/releases/download/latest/turn2socks-linux-${t2s_arch}"

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
    # 动态尝试获取 Release 发布的实时 sha256 校验和文件
    local tmp_sha="$work/turn2socks.sha256"
    if download_file "${used_url}.sha256" "$tmp_sha"; then
      local dynamic_sha
      dynamic_sha="$(awk '{print $1}' "$tmp_sha" 2>/dev/null | tr -d '[:space:]')"
      if [ -n "$dynamic_sha" ] && [ "${#dynamic_sha}" -eq 64 ]; then
        exp_t2s_sha="$dynamic_sha"
      fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      local act_t2s_sha
      act_t2s_sha="$(sha256sum "$tmp_t2s" 2>/dev/null | awk '{print $1}')"
      if [ -n "$exp_t2s_sha" ] && [ "$act_t2s_sha" != "$exp_t2s_sha" ]; then
        warn "turn2socks 检测到远端版本与内置已知指纹不一致"
        warn "已知指纹: ${exp_t2s_sha:0:16}..., 实际计算: ${act_t2s_sha:0:16}..."
        if [ -t 0 ] && { : </dev/tty; } 2>/dev/null; then
          read -p "是否信任并继续使用此新版本？[y/N]: " t2s_bypass </dev/tty
          case "$t2s_bypass" in
            y|Y) warn "已确认使用新版本" ;;
            *)
              rm -rf "$work"
              warn "已终止未验证组件安装"
              return 1
              ;;
          esac
        else
          rm -rf "$work"
          warn "非交互环境下哈希指纹不匹配，为保障安全已终止安装"
          return 1
        fi
      else
        log "turn2socks SHA256 安全校验通过 (${act_t2s_sha:0:16}...)"
      fi
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
  if [ -f "$TURN2SOCKS_PID" ]; then
    local p
    p="$(cat "$TURN2SOCKS_PID" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    rm -f "$TURN2SOCKS_PID" 2>/dev/null || true
  fi
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
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${p} " && return 0
    ss -lun 2>/dev/null | grep -q ":${p} " && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${p} " && return 0
    netstat -lun 2>/dev/null | grep -q ":${p} " && return 0
  fi
  return 1
}

is_valid_port_or_empty() {
  local p="$1"
  [ -z "$p" ] && return 0
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

prompt_port() {
  local prompt_text="$1" default_val="$2"
  local res
  while true; do
    read -p "$prompt_text" res
    res="${res:-$default_val}"
    [ "$res" = "0" ] || [ "$res" = "未启用" ] && { echo ""; return 0; }
    if is_valid_port_or_empty "$res"; then
      echo "$res"
      return 0
    fi
    warn "端口格式错误，必须为 1-65535 的数字 (填 0 关闭)"
  done
}

port_ok() {
  local p="$1"
  [ -z "$p" ] && return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -lt 1 ] || [ "$p" -gt 65535 ] && return 1
  # 内部保留端口（Argo 分流 8001、内部入站 10000-10003、本地客户端代理 10808-10809）严禁占用
  case "$p" in
    8001|10000|10001|10002|10003|10808|10809) return 1 ;;
  esac
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

open_firewall_ports() {
  for item in "$@"; do
    open_firewall_port "$item"
  done
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
  [ -n "$custom_ip" ] && { echo "$custom_ip"; return; }

  local ip=""
  local has_v4=0
  if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null | grep -q default && has_v4=1
  elif command -v route >/dev/null 2>&1; then
    route -n 2>/dev/null | grep -q '^0.0.0.0' && has_v4=1
  fi

  if [ "$has_v4" = "1" ]; then
    ip="$(curl -4 -sL --max-time 2 https://api.ipify.org 2>/dev/null || curl -4 -sL --max-time 2 https://ipinfo.io/ip 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -6 -sL --max-time 2 https://api64.ipify.org 2>/dev/null || curl -sL --max-time 2 https://ipinfo.io/ip 2>/dev/null || true)"
  fi
  ip="${ip:-127.0.0.1}"
  [ "$ip" != "127.0.0.1" ] && set_val PUBLIC_IP "$ip"
  echo "$ip"
}

get_node_name_prefix() {
  local custom_name
  custom_name="$(get_val NAME)"
  if [ -n "$custom_name" ] && [ "$custom_name" != "xray" ] && [ "$custom_name" != "xr" ] && [ "$custom_name" != "xr-Node" ]; then
    echo "$custom_name"
    return
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
  elif [ -n "$country" ]; then
    name_tag="${country}-Node"
  else
    name_tag="xr-Node"
  fi
  set_val NAME "$name_tag"
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

get_socks5_creds() {
  local u p
  u="$(get_val S5_USER)"
  p="$(get_val S5_PASS)"
  if [ -z "$u" ]; then
    u="user$(od -An -tx1 -N3 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $RANDOM)"
    set_val S5_USER "$u"
  fi
  if [ -z "$p" ]; then
    p="pass$(od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $RANDOM$RANDOM)"
    set_val S5_PASS "$p"
  fi
  echo "$u $p"
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
  local tmp_acme="$STATE_DIR/acme-dl-$$"
  rm -rf "$tmp_acme" && mkdir -p "$tmp_acme"
  if ! download_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/3.1.0/acme.sh" "$tmp_acme/acme.sh"; then
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
        mkdir -p "$DOMAIN_CERT_DIR/$domain"
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --register-account -m "admin@${domain}" --server letsencrypt >/dev/null 2>&1 || true
        log "正在向 Let's Encrypt 申请证书..."
        if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt --force; then
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
          warn "证书签发失败，请确认域名已正确解析到本机公网 IP 且 80 端口未被占用"
          rm -rf "${DOMAIN_CERT_DIR:?}/${domain}"
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
      local proto="socks"
      [ "$o_opt" = "2" ] && proto="http"
      read -p "代理服务器 IP/域名: " p_host
      p_host="$(printf '%s' "$p_host" | tr -d '[:space:]')"
      if [ -z "$p_host" ] || [[ "$p_host" =~ [\"\\\'\<\>\;\&] ]]; then
        warn "代理服务器地址格式非法，请勿包含引号或特殊符号"
        press_any_key
        return
      fi
      p_port="$(prompt_port "代理端口: " "")"
      if [ -z "$p_port" ]; then
        warn "代理端口不能为空"
        press_any_key
        return
      fi
      read -p "用户名 (留空无认证): " p_user
      local p_pass=""
      [ -n "$p_user" ] && read -p "密码: " p_pass
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
      read -p "TURN 服务器地址: " t_host
      t_host="$(printf '%s' "$t_host" | tr -d '[:space:]')"
      if [ -z "$t_host" ] || [[ "$t_host" =~ [\"\\\'\<\>\;\&] ]]; then
        warn "TURN 服务器地址格式非法，请勿包含引号或特殊符号"
        press_any_key
        return
      fi
      t_port="$(prompt_port "TURN 服务器端口 [默认 3478]: " "3478")"
      if [ -z "$t_port" ]; then
        warn "TURN 端口不能为空"
        press_any_key
        return
      fi
      read -p "用户名 (留空无认证): " t_user
      local t_pass=""
      [ -n "$t_user" ] && read -p "密码: " t_pass
      t_lport="$(prompt_port "本地 SOCKS5 转接端口 [默认 10808]: " "10808")"
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
  local uuid reality_port xhttp_port reality_domain reality_priv reality_pub ss_port ss_pass s5_port s5_user s5_pass trojan_port
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

  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_ss2022_key "$(get_val SS_PASS)")"

  s5_port="$(get_val S5_PORT)"
  read -r s5_user s5_pass <<< "$(get_socks5_creds)"

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
      }
    }'
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
    if $is_fixed_argo; then
      append_inbound '    {
        "tag": "vless-xhttp-in",
        "port": 10003,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": { "clients": [{ "id": "'"$uuid"'" }], "decryption": "none" },
        "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/vless-xhttp", "mode": "auto" } }
      }'
    fi
  fi

  # 2. 直连 Reality 入站 (TCP Vision)
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

  # 3. 直连 Reality xhttp 入站
  if [ -n "$xhttp_port" ] && [ -n "$reality_priv" ]; then
    append_inbound '    {
      "tag": "reality-xhttp-in",
      "port": '"$xhttp_port"',
      "listen": "::",
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
          "shortIds": [""]
        },
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto"
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
        "udp": true'"$s5_ip_field"'
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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

  cat >> "$CONFIG_FILE" << EOF
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      },
EOF

  if [ -n "$active_outbound_tag" ] && [ "$out_route_mode" = "split" ]; then
    cat >> "$CONFIG_FILE" << EOF
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
  name="$(get_node_name_prefix)"

  node_host="$(get_val SERVER_DOMAIN)"
  [ -z "$node_host" ] && node_host="$(format_addr "$pub_ip")"

  local links=()
  local clash_proxies=()
  local clash_names=()
  local c_idx=1
  next_clash_name() {
    printf "%s %02d" "$name" "$c_idx"
    c_idx=$((c_idx + 1))
  }

  # 1. Argo 穿透链路
  if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
    local argo_dom_val argo_auth_val is_fixed_argo=false
    argo_dom_val="$(get_val ARGO_DOMAIN)"
    argo_auth_val="$(get_val ARGO_AUTH)"
    [ -n "$argo_dom_val" ] && [ "$argo_dom_val" != "your-domain.com" ] && [ -n "$argo_auth_val" ] && is_fixed_argo=true

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
    links+=("trojan://${uuid}@${prefer_host}:443?security=tls&type=ws&host=${argo_domain}&path=%2Ftrojan-ws&sni=${argo_domain}#${n_argo_tr}")
    clash_names+=("\"${n_argo_tr}\"")
    clash_proxies+=("  - name: \"${n_argo_tr}\"
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

  # 2. 直连 VLESS-Reality (TCP Vision)
  local reality_port reality_domain
  reality_port="$(get_val REALITY_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r _ reality_pub <<< "$(get_reality_keys)"

  if [ -n "$reality_port" ] && [ -n "$reality_pub" ] && [ -n "$pub_ip" ]; then
    local r_host="${node_host#[}"
    r_host="${r_host%]}"
    local n_r_tcp="${name}-Reality-TCP"
    links+=("vless://${uuid}@${node_host}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&type=tcp#${n_r_tcp}")
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
      short-id: \"\"
    client-fingerprint: chrome")
  fi

  # 3. 直连 VLESS-Reality (xhttp)
  local xhttp_port
  xhttp_port="$(get_val XHTTP_PORT)"
  if [ -n "$xhttp_port" ] && [ -n "$reality_pub" ] && [ -n "$pub_ip" ]; then
    local rx_host="${node_host#[}"
    rx_host="${rx_host%]}"
    local n_r_xh="${name}-Reality-xhttp"
    links+=("vless://${uuid}@${node_host}:${xhttp_port}?encryption=none&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&type=xhttp&path=%2Fxhttp&mode=auto#${n_r_xh}")
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
      short-id: \"\"
    client-fingerprint: chrome")
  fi

  # 4. 直连 Shadowsocks 2022
  local ss_port ss_pass
  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_val SS_PASS)"
  if [ -n "$ss_port" ] && [ -n "$pub_ip" ]; then
    local ss_uinfo
    ss_uinfo="$(b64 "2022-blake3-aes-128-gcm:${ss_pass}")"
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
  if [ -n "$s5_port" ] && [ -n "$pub_ip" ]; then
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
  if [ -n "$trojan_port" ] && [ -n "$pub_ip" ]; then
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
    links+=("trojan://${uuid}@${node_host}:${trojan_port}?security=tls&sni=${tr_sni}&allowInsecure=${tr_insec}#${n_tr}")
    local tr_host="${node_host#[}"
    tr_host="${tr_host%]}"
    clash_names+=("\"${n_tr}\"")
    clash_proxies+=("  - name: \"${n_tr}\"
    type: trojan
    server: ${tr_host}
    port: ${trojan_port}
    password: ${uuid}
    udp: true
    sni: ${tr_sni}
    skip-cert-verify: ${skip_cert}")
  fi

  # 写入原始链接与 Base64
  printf "%s\n" "${links[@]}" > "$SUB_RAW_FILE"
  b64 "$(printf "%s\n" "${links[@]}")" > "$SUB_FILE"
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

  # 写入 Xray 客户端专用配置 JSON (仅当 Reality 启用时)
  if [ -n "$reality_port" ] && [ -n "$reality_pub" ]; then
    local r_target_host="${node_host#[}"
    r_target_host="${r_target_host%]}"
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
          "shortId": ""
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
}

# ── 14. 服务守护、运行与进程调度 ───────────────────────────────────────────────
do_run() {
  echo $$ > "$RUN_PID"
  load_env
  ensure_basic_deps
  ensure_binaries
  generate_config

  log "正在预校验 Xray 配置文件语法..."
  if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then
    die "Xray 配置语法测试失败，请检查配置文件格式"
  fi
  log "Xray 语法校验通过 (Syntax OK)"

  # 若配置了 TURN 出口，优先拉起 turn2socks 转接守护
  if [ -f "$OUTBOUND_FILE" ] && [ "$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)" = "turn" ]; then
    start_turn2socks || true
  fi

  stop_pid_file "$PID_FILE"
  "$XRAY_BIN" run -config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  log "Xray 核心已启动 (PID: $(cat "$PID_FILE"))"

  # 启动 Cloudflared (Argo)
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ -x "$CF_BIN" ]; then
    stop_pid_file "$CF_PID"
    local argo_domain argo_auth argo_proto
    argo_domain="$(get_val ARGO_DOMAIN)"
    argo_auth="$(get_val ARGO_AUTH)"
    argo_proto="$(get_val ARGO_PROTOCOL "http2")"
    local cf_args=("tunnel" "--edge-ip-version" "auto" "--no-autoupdate" "--protocol" "$argo_proto")

    if [ -n "$argo_domain" ] && [ -n "$argo_auth" ]; then
      cf_args+=("run" "--token" "$argo_auth")
      "$CF_BIN" "${cf_args[@]}" > "$CF_LOG" 2>&1 &
      echo $! > "$CF_PID"
      log "Cloudflare 固定隧道已启动 (${argo_domain})"
      generate_sub
    else
      set_val ARGO_DOMAIN ""
      > "$CF_LOG" 2>/dev/null || true
      cf_args+=("--url" "http://127.0.0.1:8001")
      "$CF_BIN" "${cf_args[@]}" > "$CF_LOG" 2>&1 &
      echo $! > "$CF_PID"
      log "Cloudflare 临时隧道正在建立连接..."
      # 捕获分配的 trycloudflare 临时域名
      local count=0 new_host=""
      while [ $count -lt 30 ]; do
        new_host="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -n 1 | sed 's|https://||')"
        [ -n "$new_host" ] && break
        sleep 1
        count=$((count + 1))
      done
      if [ -n "$new_host" ]; then
        set_val ARGO_DOMAIN "$new_host"
        log "临时域名已成功分配: ${GREEN}https://${new_host}${RESET}"
        generate_sub
      fi
    fi
  fi

  # 启动 Komari 探针
  local km_dom km_tok
  km_dom="$(get_val KOMARI_DOMAIN)"
  km_tok="$(get_val KOMARI_TOKEN)"
  if [ -n "$km_dom" ] && [ -n "$km_tok" ] && [ -x "$KM_BIN" ]; then
    stop_pid_file "$KM_PID"
    km_dom="${km_dom#http://}"
    km_dom="${km_dom#https://}"
    "$KM_BIN" -e "$km_dom" -t "$km_tok" > "$KM_LOG" 2>&1 &
    echo $! > "$KM_PID"
    log "Komari 监控探针已启动"
  fi

  generate_sub
  log "所有服务已部署就绪，订阅链接已写入 $SUB_FILE"

  # 看门狗进程
  while true; do
    local is_alive=0
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
      is_alive=1
    elif command -v pgrep >/dev/null 2>&1 && pgrep -f "$BIN_DIR/xray" >/dev/null 2>&1; then
      is_alive=1
    fi
    if [ "$is_alive" = "0" ]; then
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

stop_pid_file() {
  local p_file="$1"
  if [ -f "$p_file" ]; then
    local p
    p="$(cat "$p_file" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null || true
      local _t=0
      while kill -0 "$p" 2>/dev/null && [ $_t -lt 5 ]; do
        sleep 0.5
        _t=$((_t + 1))
      done
      kill -9 "$p" 2>/dev/null || true
    fi
    rm -f "$p_file" 2>/dev/null || true
  fi
}

do_stop() {
  stop_pid_file "$RUN_PID"
  stop_pid_file "$PID_FILE"
  stop_pid_file "$CF_PID"
  stop_pid_file "$KM_PID"
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
  [ "$(id -u)" = "0" ] || return 0
  local script_target="$APP_DIR/xray.sh"

  # 1. 确保核心脚本文件安全持久化，杜绝拷贝自身或拷贝 bash
  local _src_is_file=false
  case "$0" in
    /dev/*|/proc/*|/dev/fd/*|bash|sh|-*) _src_is_file=false ;;
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
  create_shortcut_bin "xray-sub" "sub"
  create_shortcut_bin "xray-log" "log"
  create_shortcut_bin "xray-del" "del"

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
    in_s5_port="$(get_random_high_port)"
    in_trojan_port="$(get_random_high_port)"
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
    in_uuid="${custom_u:-$in_uuid}"
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
        if [ -n "$in_argo_domain" ]; then
          read -p "Argo Tunnel Token: " in_argo_auth
        fi
        read -p "Cloudflare 优选域名/IP [默认 www.visa.com.tw]: " in_pref_host
        in_pref_host="${in_pref_host:-www.visa.com.tw}"
        ;;
    esac

    echo ""
    echo -e "${YELLOW}--- 直连协议端口分配 (默认自动探测 10000+ 闲置高位端口) ---${RESET}"
    rm -f "$USED_PORTS_FILE"
    local rec_r rec_xh rec_ss rec_s5 rec_tr
    rec_r="$(get_random_high_port)"
    rec_xh="$(get_random_high_port)"
    rec_ss="$(get_random_high_port)"
    rec_s5="$(get_random_high_port)"
    rec_tr="$(get_random_high_port)"

    in_reality_port="$(prompt_port "Reality TCP 端口 [默认推荐高位 ${rec_r}，填 0 关闭]: " "$rec_r")"
    in_xhttp_port="$(prompt_port "Reality xhttp 端口 [默认推荐高位 ${rec_xh}，填 0 关闭]: " "$rec_xh")"

    if [ -n "$in_reality_port" ] || [ -n "$in_xhttp_port" ]; then
      read -p "Reality 伪装域名 [默认 www.iij.ad.jp]: " in_reality_domain
      in_reality_domain="${in_reality_domain:-www.iij.ad.jp}"
    fi

    in_ss_port="$(prompt_port "Shadowsocks 2022 端口 [默认推荐高位 ${rec_ss}，填 0 关闭]: " "$rec_ss")"
    if [ -n "$in_ss_port" ]; then
      read -p "SS 密码 [留空随机生成]: " in_ss_pass
      in_ss_pass="$(get_ss2022_key "$in_ss_pass")"
    fi

    in_s5_port="$(prompt_port "SOCKS5 端口 [默认推荐高位 ${rec_s5}，填 0 关闭]: " "$rec_s5")"
    read -r in_s5_user in_s5_pass <<< "$(get_socks5_creds)"
    if [ -n "$in_s5_port" ]; then
      read -p "SOCKS5 用户名 [默认 ${in_s5_user}]: " custom_s5_u
      in_s5_user="${custom_s5_u:-$in_s5_user}"
      read -p "SOCKS5 密码 [默认 ${in_s5_pass}]: " custom_s5_p
      in_s5_pass="${custom_s5_p:-$in_s5_pass}"
    fi

    in_trojan_port="$(prompt_port "Trojan-TCP 端口 [默认推荐高位 ${rec_tr}，填 0 关闭]: " "$rec_tr")"
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
  ensure_binaries
  generate_config
  setup_systemd
  setup_shortcuts

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
        found_h="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -n 1 | sed 's|https://||')"
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
        if [ -z "$new_u" ]; then
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
        read -p "Reality TCP 端口 [默认 ${cur_rp}，填 0 关闭]: " new_rp
        new_rp="${new_rp:-$cur_rp}"
        [ "$new_rp" = "0" ] || [ "$new_rp" = "未启用" ] && new_rp=""
        if ! is_valid_port_or_empty "$new_rp"; then
          warn "端口非法，必须为 1-65535 的数字"
          press_any_key
          continue
        fi
        set_val REALITY_PORT "$new_rp"

        read -p "Reality xhttp 端口 [默认 ${cur_xp}，填 0 关闭]: " new_xp
        new_xp="${new_xp:-$cur_xp}"
        [ "$new_xp" = "0" ] || [ "$new_xp" = "未启用" ] && new_xp=""
        if ! is_valid_port_or_empty "$new_xp"; then
          warn "端口非法，必须为 1-65535 的数字"
          press_any_key
          continue
        fi
        set_val XHTTP_PORT "$new_xp"

        if [ -n "$new_rp" ] || [ -n "$new_xp" ]; then
          read -p "Reality 伪装域名 [默认 ${cur_rd}]: " new_rd
          new_rd="${new_rd:-$cur_rd}"
          set_val REALITY_DOMAIN "${new_rd:-www.iij.ad.jp}"
          rm -f "$REALITY_KEY_FILE"
        fi
        [ -n "$new_rp" ] && open_firewall_port "$new_rp" tcp
        [ -n "$new_xp" ] && open_firewall_port "$new_xp" tcp
        config_modified=1
        log "Reality 配置已更新"
        sleep 1
        ;;
      3)
        read -p "Shadowsocks 端口 [默认 ${cur_sp}，填 0 关闭]: " new_sp
        new_sp="${new_sp:-$cur_sp}"
        [ "$new_sp" = "0" ] || [ "$new_sp" = "未启用" ] && new_sp=""
        if ! is_valid_port_or_empty "$new_sp"; then
          warn "端口非法，必须为 1-65535 的数字"
          press_any_key
          continue
        fi
        set_val SS_PORT "$new_sp"
        if [ -n "$new_sp" ]; then
          read -p "Shadowsocks 密码 [留空随机生成]: " new_pass
          new_pass="$(get_ss2022_key "$new_pass")"
          set_val SS_PASS "$new_pass"
          open_firewall_port "$new_sp" both
        fi
        config_modified=1
        log "Shadowsocks 配置已更新"
        sleep 1
        ;;
      4)
        read -p "SOCKS5 协议端口 [默认 ${cur_s5}，填 0 关闭]: " new_s5
        new_s5="${new_s5:-$cur_s5}"
        [ "$new_s5" = "0" ] || [ "$new_s5" = "未启用" ] && new_s5=""
        if ! is_valid_port_or_empty "$new_s5"; then
          warn "端口非法，必须为 1-65535 的数字"
          press_any_key
          continue
        fi
        set_val S5_PORT "$new_s5"
        if [ -n "$new_s5" ]; then
          local cur_s5_u cur_s5_p
          read -r cur_s5_u cur_s5_p <<< "$(get_socks5_creds)"
          read -p "SOCKS5 用户名 [默认 ${cur_s5_u}]: " new_s5_u
          set_val S5_USER "${new_s5_u:-$cur_s5_u}"
          read -p "SOCKS5 密码 [默认 ${cur_s5_p}]: " new_s5_p
          set_val S5_PASS "${new_s5_p:-$cur_s5_p}"
          open_firewall_port "$new_s5" both
        fi
        config_modified=1
        log "SOCKS5 配置已更新"
        sleep 1
        ;;
      5)
        read -p "Trojan 协议端口 [默认 ${cur_tp}，填 0 关闭]: " new_tp
        new_tp="${new_tp:-$cur_tp}"
        [ "$new_tp" = "0" ] || [ "$new_tp" = "未启用" ] && new_tp=""
        if ! is_valid_port_or_empty "$new_tp"; then
          warn "端口非法，必须为 1-65535 的数字"
          press_any_key
          continue
        fi
        set_val TROJAN_PORT "$new_tp"
        [ -n "$new_tp" ] && open_firewall_port "$new_tp" tcp
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
            set_val ARGO_DOMAIN "$new_ad"
            if [ -n "$new_ad" ]; then
              read -p "Argo Tunnel Token: " new_at
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
        set_val CF_PREFER_HOST "${new_pref:-www.visa.com.tw}"
        config_modified=1
        log "CDN 优选域名已更新"
        sleep 1
        ;;
      8)
        read -p "Komari 服务端域名 [留空关闭]: " new_kd
        set_val KOMARI_DOMAIN "$new_kd"
        if [ -n "$new_kd" ]; then
          read -p "Komari 探针 Token: " new_kt
          set_val KOMARI_TOKEN "$new_kt"
        fi
        config_modified=1
        log "Komari 探针配置已更新"
        sleep 1
        ;;
      9)
        read -p "自定义连接域名/IP [留空恢复自动探测]: " new_dom
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

do_uninstall() {
  read -p "确定要彻底卸载 Xray 与全部配置文件和快捷方式吗? [y/N]: " confirm
  case "$confirm" in
    y|Y)
      do_stop
      if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      rm -f "/etc/systemd/system/${SVC_NAME}.service"
      local shortcuts=("xr" "xray" "xr-sub" "xr-log" "xr-del" "xray-sub" "xray-log" "xray-del")
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
      rm -rf "$APP_DIR"
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
  run)     do_run ;;
  stop)
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
      systemctl stop "$SVC_NAME"
      log "Xray 系统服务已通过 systemctl 停止"
    else
      do_stop
    fi
    ;;
  restart) do_restart ;;
  sub)     show_sub ;;
  log)     do_log ;;
  install) do_install ;;
  update)  menu_update ;;
  del)     do_uninstall ;;
  *)
    case "$(basename "$0")" in
      xr-sub|xray-sub) show_sub ;;
      xr-log|xray-log) do_log ;;
      xr-del|xray-del) do_uninstall ;;
      *)
        if [ ! -x "$XRAY_BIN" ]; then
          do_install
        else
          do_menu
        fi
        ;;
    esac
    ;;
esac
