#!/bin/bash
# ==============================================================================
# xray.sh - 一体化 Xray 跨平台 VPS 管理面板与守护脚本
# 功能支持: Xray-core / Argo 穿透 / Reality / SS2022 / Socks5 / Komari 探针 / 订阅分发
# ==============================================================================

# Bash 兼容性保障
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  elif [ "$(id -u)" = "0" ] && command -v apk >/dev/null 2>&1; then
    echo "检测到 Alpine 系统，自动安装 bash..."
    apk add --no-cache bash >/dev/null 2>&1 || true
    exec bash "$0" "$@"
  else
    echo "本脚本需要 bash 才能运行，请先安装 bash。"
    exit 1
  fi
fi

export TERM="${TERM:-xterm}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ── 颜色与输出定义 ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[0;97m'
NC='\033[0m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 路径与常量定义 ────────────────────────────────────────────────────────────
HOME_DIR="${HOME:-/root}"
APP_DIR="$HOME_DIR/xray"
STATE_DIR="$APP_DIR/state"
ENV_FILE="$APP_DIR/config.env"
SUB_FILE="$APP_DIR/sub.txt"
LOG_FILE="$APP_DIR/run.log"
CF_LOG="$APP_DIR/cf.log"
KM_LOG="$APP_DIR/komari.log"
PID_FILE="$APP_DIR/xray.pid"
SVC_NAME="xray"

# 优先存放在受保护的二进制缓存目录
BIN_DIR="/tmp/xray-bin-$(id -u 2>/dev/null || echo 0)"
XRAY_BIN="$BIN_DIR/xray"
CF_BIN="$BIN_DIR/cloudflared"
KM_BIN="$BIN_DIR/komari-agent"

CONFIG_FILE="$STATE_DIR/config.json"
REALITY_KEY_FILE="$STATE_DIR/reality-keys.txt"
UUID_FILE="$STATE_DIR/uuid.txt"

mkdir -p "$APP_DIR" "$STATE_DIR" "$BIN_DIR" 2>/dev/null || true
[ "$(id -u)" != "0" ] && chmod 700 "$BIN_DIR" "$STATE_DIR" 2>/dev/null || true

export XRAY_LOCATION_ASSET="$BIN_DIR"

# ── 配置环境变量读写工具 ──────────────────────────────────────────────────────
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
  # 安全读取 key=val
  while IFS='=' read -r k v; do
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

# ── 架构检测 ──────────────────────────────────────────────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l|armhf)  echo "arm32-v7a" ;;
    s390x)         echo "s390x" ;;
    *)             echo "64" ;;
  esac
}

detect_cf_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l|armhf)  echo "linux-arm" ;;
    *)             echo "linux-amd64" ;;
  esac
}

detect_km_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux_amd64" ;;
    aarch64|arm64) echo "linux_arm64" ;;
    armv7l|armhf)  echo "linux_armv7" ;;
    *)             echo "linux_amd64" ;;
  esac
}

# ── 下载与解压工具 ────────────────────────────────────────────────────────────
download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=10 "$url" -O "$dest"
  else
    die "缺少 curl 或 wget，无法下载组件"
  fi
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
    die "系统缺少解压工具，请执行: apt install -y unzip 或 apk add unzip"
  fi
}

ensure_binaries() {
  # 1. Xray-core
  if [ ! -x "$XRAY_BIN" ]; then
    log "正在下载最新 Xray-core..."
    local xarch url tmpzip
    xarch="$(detect_arch)"
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xarch}.zip"
    tmpzip="/tmp/xray_dl_$$.zip"
    download_file "$url" "$tmpzip" || die "下载 Xray 失败"
    mkdir -p "/tmp/xray_extract_$$"
    extract_zip "$tmpzip" "/tmp/xray_extract_$$"
    mv "/tmp/xray_extract_$$/xray" "$XRAY_BIN"
    [ -f "/tmp/xray_extract_$$/geoip.dat" ] && mv "/tmp/xray_extract_$$/geoip.dat" "$BIN_DIR/"
    [ -f "/tmp/xray_extract_$$/geosite.dat" ] && mv "/tmp/xray_extract_$$/geosite.dat" "$BIN_DIR/"
    rm -rf "$tmpzip" "/tmp/xray_extract_$$"
    chmod +x "$XRAY_BIN"
    log "Xray-core 安装完毕: $("$XRAY_BIN" version 2>/dev/null | head -1)"
  fi

  # 2. Cloudflared (Argo)
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ ! -x "$CF_BIN" ]; then
    log "正在下载 cloudflared..."
    local cfarch url
    cfarch="$(detect_cf_arch)"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${cfarch}"
    download_file "$url" "$CF_BIN" || warn "下载 cloudflared 失败"
    chmod +x "$CF_BIN" 2>/dev/null || true
  fi

  # 3. Komari-agent (探针)
  if [ -n "$(get_val KOMARI_DOMAIN)" ] && [ -n "$(get_val KOMARI_TOKEN)" ] && [ ! -x "$KM_BIN" ]; then
    log "正在下载 komari-agent..."
    local kmarch url
    kmarch="$(detect_km_arch)"
    url="https://github.com/komari-monitoring/komari-agent/releases/latest/download/komari-agent_${kmarch}"
    download_file "$url" "$KM_BIN" || warn "下载 komari-agent 失败"
    chmod +x "$KM_BIN" 2>/dev/null || true
  fi
}

# ── 生成 UUID 与 Reality 密钥 ─────────────────────────────────────────────────
get_uuid() {
  local u
  u="$(get_val UUID)"
  if [ -z "$u" ] && [ -f "$UUID_FILE" ]; then
    u="$(cat "$UUID_FILE" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -z "$u" ]; then
    if [ -x "$XRAY_BIN" ]; then
      u="$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]')"
    elif command -v uuidgen >/dev/null 2>&1; then
      u="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    else
      u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11223344-5566-7788-99aa-bbccddeeff00")"
    fi
    set_val UUID "$u"
    echo "$u" > "$UUID_FILE"
  fi
  echo "$u"
}

get_reality_keys() {
  local priv pub
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

# ── 生成 Xray 配置 JSON ───────────────────────────────────────────────────────
generate_config() {
  local uuid reality_port reality_domain reality_priv ss_port ss_pass s5_port s5_user s5_pass
  uuid="$(get_uuid)"
  reality_port="$(get_val REALITY_PORT)"
  reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"

  read -r reality_priv reality_pub <<< "$(get_reality_keys)"

  ss_port="$(get_val SS_PORT)"
  ss_pass="$(get_val SS_PASS)"
  [ -z "$ss_pass" ] && ss_pass="$(head -c 16 /dev/urandom | base64 2>/dev/null || echo "WnJ5UGFzc3dvcmQxMjM0")"

  s5_port="$(get_val S5_PORT)"
  s5_user="$(get_val S5_USER)"
  [ -z "$s5_user" ] && s5_user="${uuid:0:8}"
  s5_pass="$(get_val S5_PASS)"
  [ -z "$s5_pass" ] && s5_pass="${uuid:24}"

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

  # 1. Argo 入站组
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

  cat >> "$CONFIG_FILE" << EOF
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  chmod 600 "$CONFIG_FILE"
}

# ── 节点链接与订阅生成 ────────────────────────────────────────────────────────
generate_sub() {
  local uuid prefer_host argo_domain pub_ip name links
  uuid="$(get_uuid)"
  prefer_host="$(get_val CF_PREFER_HOST)"
  [ -z "$prefer_host" ] && prefer_host="www.visa.com.tw"
  argo_domain="$(get_val ARGO_DOMAIN)"
  [ -z "$argo_domain" ] && argo_domain="your-domain.com"
  pub_ip="$(get_val PUBLIC_IP)"
  name="$(get_val NAME)"
  [ -z "$name" ] && name="xray"

  links=()
  if [ "$(get_val DISABLE_ARGO)" != "true" ]; then
    links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=xhttp&host=${argo_domain}&path=%2Fvless-xhttp&mode=packet-up&sni=${argo_domain}#${name}-VLESS-xhttp")
    links+=("vless://${uuid}@${prefer_host}:443?encryption=none&security=tls&type=ws&host=${argo_domain}&path=%2Fvless-ws&sni=${argo_domain}#${name}-VLESS-WS")
    local vm_json
    vm_json="$(printf '{"v":"2","ps":"%s-VMess-WS","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess-ws","tls":"tls","sni":"%s"}' "$name" "$prefer_host" "$uuid" "$argo_domain" "$argo_domain")"
    links+=("vmess://$(printf '%s' "$vm_json" | base64 | tr -d '\n')")
    links+=("trojan://${uuid}@${prefer_host}:443?security=tls&type=ws&host=${argo_domain}&path=%2Ftrojan-ws&sni=${argo_domain}#${name}-Trojan-WS")
  fi

  local reality_port="$(get_val REALITY_PORT)"
  local reality_domain="$(get_val REALITY_DOMAIN)"
  [ -z "$reality_domain" ] && reality_domain="www.iij.ad.jp"
  read -r _ reality_pub <<< "$(get_reality_keys)"

  if [ -n "$reality_port" ] && [ -n "$reality_pub" ] && [ -n "$pub_ip" ]; then
    links+=("vless://${uuid}@${pub_ip}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_pub}&type=tcp#${name}-Reality")
  fi

  local ss_port="$(get_val SS_PORT)"
  local ss_pass="$(get_val SS_PASS)"
  if [ -n "$ss_port" ] && [ -n "$pub_ip" ]; then
    local ss_uinfo
    ss_uinfo="$(printf '2022-blake3-aes-128-gcm:%s' "$ss_pass" | base64 | tr -d '\n')"
    links+=("ss://${ss_uinfo}@${pub_ip}:${ss_port}#${name}-SS2022")
  fi

  local s5_port="$(get_val S5_PORT)"
  local s5_user="$(get_val S5_USER)"
  local s5_pass="$(get_val S5_PASS)"
  [ -z "$s5_user" ] && s5_user="${uuid:0:8}"
  [ -z "$s5_pass" ] && s5_pass="${uuid:24}"
  if [ -n "$s5_port" ] && [ -n "$pub_ip" ]; then
    local s5_uinfo
    s5_uinfo="$(printf '%s:%s' "$s5_user" "$s5_pass" | base64 | tr -d '\n')"
    links+=("socks://${s5_uinfo}@${pub_ip}:${s5_port}#${name}-Socks5")
  fi

  printf "%s\n" "${links[@]}" > "$APP_DIR/sub_raw.txt"
  printf "%s\n" "${links[@]}" | base64 | tr -d '\r\n' > "$SUB_FILE"
}

# ── 运行守护核心 ──────────────────────────────────────────────────────────────
do_run() {
  load_env
  ensure_binaries
  generate_config

  # 预校验
  "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1 || die "Xray 配置校验失败"

  # 后台启动 Xray
  "$XRAY_BIN" run -config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  log "Xray 核心已启动 (PID: $(cat "$PID_FILE"))"

  # 若启用了 Node.js 调度器则运行 Node 分流，否则使用轻量守护
  if [ -f "$APP_DIR/nodejs/index.js" ] && command -v node >/dev/null 2>&1; then
    node "$APP_DIR/nodejs/index.js"
    return
  fi

  # 启动 Cloudflared (Argo)
  if [ "$(get_val DISABLE_ARGO)" != "true" ] && [ -x "$CF_BIN" ]; then
    local argo_domain argo_auth
    argo_domain="$(get_val ARGO_DOMAIN)"
    argo_auth="$(get_val ARGO_AUTH)"
    if [ -n "$argo_domain" ] && [ -n "$argo_auth" ]; then
      TUNNEL_TOKEN="$argo_auth" "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate run > "$CF_LOG" 2>&1 &
      log "Cloudflare 固定隧道启动"
    else
      "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate --url http://127.0.0.1:10003 > "$CF_LOG" 2>&1 &
      log "Cloudflare 临时隧道启动"
    fi
  fi

  # 启动 Komari
  local km_dom km_tok
  km_dom="$(get_val KOMARI_DOMAIN)"
  km_tok="$(get_val KOMARI_TOKEN)"
  if [ -n "$km_dom" ] && [ -n "$km_tok" ] && [ -x "$KM_BIN" ]; then
    km_dom="${km_dom#http://}"
    km_dom="${km_dom#https://}"
    "$KM_BIN" -e "$km_dom" -t "$km_tok" > "$KM_LOG" 2>&1 &
    log "Komari 探针已启动"
  fi

  generate_sub
  log "所有服务已部署就绪，订阅链接已写入 $SUB_FILE"
  wait
}

do_stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "$XRAY_BIN" 2>/dev/null || true
  pkill -f "$CF_BIN" 2>/dev/null || true
  pkill -f "$KM_BIN" 2>/dev/null || true
  log "服务已停止"
}

# ── Systemd 服务单元配置 ──────────────────────────────────────────────────────
setup_systemd() {
  if [ "$(id -u)" != "0" ]; then
    warn "非 root 用户，跳过系统级 systemd 配置"
    return
  fi
  cat > "/etc/systemd/system/${SVC_NAME}.service" << EOF
[Unit]
Description=Xray Universal Proxy Engine
After=network.target

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
  log "Systemd 守护服务 (${SVC_NAME}.service) 安装就绪"
}

# ── 快捷命令软链接 ────────────────────────────────────────────────────────────
setup_shortcuts() {
  if [ "$(id -u)" = "0" ]; then
    ln -sf "$APP_DIR/xray.sh" /usr/local/bin/xray
    ln -sf "$APP_DIR/xray.sh" /usr/local/bin/xray-sub
    ln -sf "$APP_DIR/xray.sh" /usr/local/bin/xray-log
    ln -sf "$APP_DIR/xray.sh" /usr/local/bin/xray-del
  fi
}

# ── 交互式菜单面板 ────────────────────────────────────────────────────────────
show_sub() {
  clear
  echo -e "${GREEN}==================== Xray 节点订阅 ====================${RESET}"
  if [ -f "$SUB_FILE" ]; then
    echo -e "${WHITE}Base64 订阅内容:${RESET}"
    cat "$SUB_FILE"
    echo -e "\n\n${WHITE}明文节点链接:${RESET}"
    if [ -f "$APP_DIR/sub_raw.txt" ]; then
      cat "$APP_DIR/sub_raw.txt"
    fi
  else
    echo -e "${YELLOW}尚未生成订阅文件，请先启动服务。${RESET}"
  fi
  echo -e "${GREEN}=======================================================${RESET}"
  read -n 1 -s -r -p "按任意键返回主菜单..."
}

show_log() {
  clear
  echo -e "${GREEN}======= 查看日志 (Ctrl+C 退出) =======${RESET}"
  echo -e "${WHITE}1. Xray 核心日志${RESET}"
  echo -e "${WHITE}2. Cloudflare Argo 隧道日志${RESET}"
  echo -e "${WHITE}3. Komari 探针监控日志${RESET}"
  echo -e "${WHITE}0. 返回${RESET}"
  echo -ne "${GRAY}请选择: ${RESET}"
  read -r lopt
  case "$lopt" in
    1) [ -f "$LOG_FILE" ] && tail -f -n 50 "$LOG_FILE" || warn "暂无核心日志" ;;
    2) [ -f "$CF_LOG" ]   && tail -f -n 50 "$CF_LOG"   || warn "暂无隧道日志" ;;
    3) [ -f "$KM_LOG" ]   && tail -f -n 50 "$KM_LOG"   || warn "暂无探针日志" ;;
    *) return ;;
  esac
}

menu_config() {
  while true; do
    clear
    echo -e "${GREEN}======= 修改配置参数 =======${RESET}"
    echo -e "${WHITE}1. 用户 UUID:        ${CYAN}$(get_val UUID)${RESET}"
    echo -e "${WHITE}2. VLESS-Reality:   ${CYAN}端口: $(get_val REALITY_PORT:-未开启) | 伪装: $(get_val REALITY_DOMAIN:-www.iij.ad.jp)${RESET}"
    echo -e "${WHITE}3. Shadowsocks 2022: ${CYAN}端口: $(get_val SS_PORT:-未开启)${RESET}"
    echo -e "${WHITE}4. Socks5 代理:      ${CYAN}端口: $(get_val S5_PORT:-未开启)${RESET}"
    echo -e "${WHITE}5. Cloudflare Argo:  ${CYAN}域名: $(get_val ARGO_DOMAIN:-临时隧道) | 优选: $(get_val CF_PREFER_HOST:-www.visa.com.tw)${RESET}"
    echo -e "${WHITE}6. Komari 探针监控:  ${CYAN}$(get_val KOMARI_DOMAIN:-未配置)${RESET}"
    echo -e "${WHITE}7. 自定义公网 IP:    ${CYAN}$(get_val PUBLIC_IP:-自动探测)${RESET}"
    echo -e "${WHITE}0. 保存并返回${RESET}"
    echo -ne "${GRAY}请选择修改项: ${RESET}"
    read -r mopt
    case "$mopt" in
      1)
        read -p "请输入新 UUID (留空自动生成): " in_u
        set_val UUID "$in_u"
        ;;
      2)
        read -p "请输入 Reality 端口 (留空关闭，如 443): " in_rp
        set_val REALITY_PORT "$in_rp"
        if [ -n "$in_rp" ]; then
          read -p "请输入 Reality 伪装域名 (默认 www.iij.ad.jp): " in_rd
          set_val REALITY_DOMAIN "${in_rd:-www.iij.ad.jp}"
        fi
        ;;
      3)
        read -p "请输入 Shadowsocks 2022 端口 (留空关闭): " in_sp
        set_val SS_PORT "$in_sp"
        ;;
      4)
        read -p "请输入 Socks5 端口 (留空关闭): " in_s5
        set_val S5_PORT "$in_s5"
        ;;
      5)
        read -p "请输入 Argo 固定域名 (留空使用临时隧道): " in_ad
        set_val ARGO_DOMAIN "$in_ad"
        if [ -n "$in_ad" ]; then
          read -p "请输入 Argo Token: " in_at
          set_val ARGO_AUTH "$in_at"
        fi
        read -p "请输入 Cloudflare 优选域名/IP (默认 www.visa.com.tw): " in_pref
        set_val CF_PREFER_HOST "${in_pref:-www.visa.com.tw}"
        ;;
      6)
        read -p "请输入 Komari 服务端域名 (留空关闭): " in_kd
        set_val KOMARI_DOMAIN "$in_kd"
        if [ -n "$in_kd" ]; then
          read -p "请输入 Komari Token: " in_kt
          set_val KOMARI_TOKEN "$in_kt"
        fi
        ;;
      7)
        read -p "请输入自定义公网 IP (留空自动探测): " in_ip
        set_val PUBLIC_IP "$in_ip"
        ;;
      0)
        return
        ;;
    esac
  done
}

do_menu() {
  while true; do
    clear
    local st_desc="${RED}未运行${RESET}"
    if pgrep -f "$XRAY_BIN" >/dev/null 2>&1; then
      st_desc="${GREEN}运行中${RESET}"
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${WHITE}          Xray 跨平台 VPS 一体化管理面板          ${RESET}"
    echo -e "${GRAY}系统状态: ${st_desc} | 安装目录: ${APP_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${WHITE} 1. 查看节点链接与全协议订阅 (Base64 / 节点明细)${RESET}"
    echo -e "${WHITE} 2. 启动 Xray 代理服务${RESET}"
    echo -e "${WHITE} 3. 停止 Xray 代理服务${RESET}"
    echo -e "${WHITE} 4. 重启 Xray 代理服务${RESET}"
    echo -e "${WHITE} 5. 修改配置 (UUID / 端口 / Reality / Argo / 探针)${RESET}"
    echo -e "${WHITE} 6. 查看服务日志 (Xray / Argo / Komari)${RESET}"
    echo -e "${WHITE} 7. 安装/重载 Systemd 守护单元${RESET}"
    echo -e "${WHITE} 8. 彻底卸载清理 Xray 与环境${RESET}"
    echo -e "${WHITE} 0. 退出管理面板${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -ne "${GRAY}请输入操作编号 [0-8]: ${RESET}"
    read -r opt
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
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1; then
          systemctl restart "$SVC_NAME"
        else
          do_stop
          nohup "$0" run >/dev/null 2>&1 &
        fi
        log "服务已重启"
        sleep 2
        ;;
      5)
        menu_config
        log "配置已变更，请重启服务生效"
        sleep 1
        ;;
      6) show_log ;;
      7) setup_systemd; sleep 1 ;;
      8)
        read -p "确定要彻底删除该项目与所有数据吗? [y/N]: " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          do_stop
          systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
          rm -f "/etc/systemd/system/${SVC_NAME}.service" /usr/local/bin/xray*
          rm -rf "$APP_DIR" "$BIN_DIR"
          log "已彻底清理完毕"
          exit 0
        fi
        ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

# ── 命令行指令分发 ────────────────────────────────────────────────────────────
case "${1:-}" in
  run)     do_run ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 1; do_run ;;
  sub)     show_sub ;;
  log)     show_log ;;
  del)
    do_stop
    rm -rf "$APP_DIR" "$BIN_DIR" /usr/local/bin/xray*
    log "已卸载"
    ;;
  *)
    # 快捷命令分支判断
    case "$(basename "$0")" in
      xray-sub) show_sub ;;
      xray-log) show_log ;;
      xray-del)
        do_stop
        rm -rf "$APP_DIR" "$BIN_DIR" /usr/local/bin/xray*
        log "已卸载"
        ;;
      *)
        setup_shortcuts
        do_menu
        ;;
    esac
    ;;
esac
