"""app.py — py-xray 单文件跨平台服务端调度程序。
功能集成: Xray-core / Cloudflare Argo / Komari 探针 / 单端口多协议复用 / 动态订阅
零第三方 pip 依赖 (纯 Python 3.8+ 标准库实现)。
"""

# ==================== 预留配置（留空则读取环境变量或自动识别） ====================
# ── 1. 基础配置 ──
CONF_UUID           = ""  # 服务 UUID（留空自动生成标准 UUID）
CONF_PORT           = ""  # HTTP 外部服务端口（默认自动搜寻可用端口，如 3000）
CONF_NAME           = ""  # 节点名称前缀（留空自动识别 IP 所在国家与组织，非阻塞）
CONF_IP             = ""  # 自定义公网 IP（留空自动探测）
CONF_SUB            = ""  # 订阅路径后缀（默认 "sub"，即 /sub）

# ── 2. Argo 隧道配置 ──
CONF_DISABLE_ARGO      = ""  # 填 "true" 禁用 Argo，留空则启用
CONF_ARGO_DOMAIN       = ""  # 固定隧道域名（留空使用临时 Quick Tunnel）
CONF_ARGO_AUTH         = ""  # 固定隧道 Token / 凭证
CONF_ARGO_PORT         = ""  # Argo 内部聚合分流端口（默认 8001）
CONF_ARGO_PROTOCOL     = ""  # Argo 隧道协议（默认留空走高速 QUIC 链路，可选 "http2"、"quic"）
CONF_CF_PREFER_HOST    = ""  # Cloudflare 优选域名/IP（留空自动从优选池中选择）

# ── 3. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
CONF_REALITY_PORT   = ""  # VLESS-Reality 端口 (TCP, 推荐 443 或自定义高位端口)
CONF_REALITY_DOMAIN = ""  # Reality 伪装域名（留空自动按国家地域自适应匹配合规站点）
CONF_SS_PORT        = ""  # Shadowsocks 2022 端口 (TCP/UDP)
CONF_SS_PASS        = ""  # Shadowsocks 2022 密钥 (留空自动生成 16 字节 Base64)
CONF_S5_PORT        = ""  # SOCKS5 代理端口 (TCP/UDP)
CONF_S5_USER        = ""  # SOCKS5 用户名 (留空默认 UUID 前 8 位)
CONF_S5_PASS        = ""  # SOCKS5 密码 (留空默认 UUID 后 12 位)

# ── 4. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
CONF_KOMARI_DOMAIN  = ""  # Komari 服务端域名（如 komari.example.com）
CONF_KOMARI_TOKEN   = ""  # Komari 探针密钥 Token

# ── 5. 日志与推送功能配置 ──
CONF_SHOW_LOG          = ""  # 是否在控制台显示订阅配置信息（默认 "true"，填 "false" 关闭显示）
CONF_LOG_CLEAR_MINUTES = ""  # 控制台显示配置后自动清理的等待时间（默认 "2" 分钟，填 "0" 则不清除）
CONF_TG_BOT_TOKEN      = ""  # Telegram Bot Token（用于推送服务配置）
CONF_TG_CHAT_ID        = ""  # Telegram Chat ID
# ==============================================================================

import base64
import http.client
import http.server
import json
import logging
import os
import platform
import re
import select
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
import zipfile
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("py-xray")

# ──────────────────────────────────────────────
# 全局进程守护与安全退出
# ──────────────────────────────────────────────
tracked_subprocesses = []
is_shutting_down = False
uptime_thread = None

PROC_TAGS = ['node /app/worker.js', 'node /app/bridge.js', 'node /app/metrics.js']

def kill_stale_by_tags():
    if platform.system().lower() == "windows":
        return
    uid_args = []
    try:
        uid = os.getuid()
        uid_args = ["-u", str(uid)]
    except Exception:
        pass
    for tag in PROC_TAGS:
        try:
            subprocess.run(["pkill", *uid_args, "-f", tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

def graceful_exit(signum=None, frame=None):
    global is_shutting_down
    if is_shutting_down:
        return
    is_shutting_down = True
    logger.info("收到退出信号，正在安全终止工作进程与网络通道...")
    for p in tracked_subprocesses:
        try:
            if p.poll() is None:
                p.terminate()
        except Exception:
            pass
    kill_stale_by_tags()
    try:
        if Path("/tmp/.fake_uptime").exists():
            subprocess.run(["umount", "/proc/uptime"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            Path("/tmp/.fake_uptime").unlink(missing_ok=True)
    except Exception:
        pass
    time.sleep(0.3)
    sys.exit(0)

signal.signal(signal.SIGINT, graceful_exit)
signal.signal(signal.SIGTERM, graceful_exit)

# ──────────────────────────────────────────────
# 运行环境与目录解析
# ──────────────────────────────────────────────
def is_container_environment() -> bool:
    if platform.system().lower() != "linux":
        return False
    if Path("/.dockerenv").exists() or Path("/run/.containerenv").exists():
        return True
    try:
        cgroup = Path("/proc/1/cgroup").read_text(encoding="utf-8", errors="ignore")
        return bool(re.search(r"docker|kubepods|containerd|lxc", cgroup, re.I))
    except Exception:
        return False

def resolve_core_dir() -> Path:
    home = Path(os.environ.get("HOME") or (os.environ.get("USERPROFILE") if platform.system().lower() == "windows" else "/root") or ".")
    candidates = [
        Path("/opt/xray-core"),
        home / ".xray-core",
        Path.cwd() / ".xray-core",
        Path(f"/tmp/xray-core-{os.getuid() if hasattr(os, 'getuid') else 0}")
    ]
    for c in candidates:
        try:
            c.mkdir(parents=True, exist_ok=True)
            test_file = c / f".test_{int(time.time()*1000)}"
            test_file.write_text("ok", encoding="utf-8")
            test_file.unlink(missing_ok=True)
            return c
        except Exception:
            continue
    fallback = Path("/tmp/xray-core")
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback

CORE_DIR = resolve_core_dir()
os.environ["XRAY_LOCATION_ASSET"] = str(CORE_DIR)

UUID_FILE = CORE_DIR / ".session.key"
CONFIG_FILE = CORE_DIR / ".config.json"
REALITY_KEY_FILE = CORE_DIR / ".reality-keys.json"
SUB_FILE = Path.cwd() / "sub.txt"

XRAY_BIN_NAME = "worker.exe" if platform.system().lower() == "windows" else "worker"
XRAY_BIN_PATH = CORE_DIR / XRAY_BIN_NAME
CF_BIN_NAME = "bridge.exe" if platform.system().lower() == "windows" else "bridge"
CF_BIN_PATH = CORE_DIR / CF_BIN_NAME
KM_BIN_NAME = "metrics.exe" if platform.system().lower() == "windows" else "metrics"
KM_BIN_PATH = CORE_DIR / KM_BIN_NAME

# 协议常量
WS_PATH_VMESS     = '/vmess-ws'
WS_PATH_VLESS     = '/vless-ws'
WS_PATH_TROJAN    = '/trojan-ws'
XHTTP_PATH_VLESS  = '/vless-xhttp'

V_VMESS_PORT      = 10000
V_VLESS_PORT      = 10001
V_TROJAN_PORT     = 10002
V_XHTTP_PORT      = 10003

CF_PREFER_HOST_CANDIDATES = [
  'www.visa.com.tw', 'www.visa.com.sg', 'www.visa.com.hk',
  'ip.sb', 'cf.877774.xyz', 'cf.090227.xyz', 'skk.moe', 'time.is'
]

GEO_REALITY_DOMAINS = {
  'JP': ['www.iij.ad.jp', 'www.rakuten.co.jp'],
  'HK': ['www.hkt.com', 'www.hkix.net'],
  'SG': ['www.starhub.com', 'www.myrepublic.net'],
  'US': ['gateway.icloud.com', 'dl.fedoraproject.org'],
  'EU': ['www.ovh.com', 'debian.mirror.liteserver.nl'],
  'DEFAULT': ['www.iij.ad.jp', 'gateway.icloud.com']
}

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
def secure_permissions(p: Path):
    if platform.system().lower() != "windows":
        try:
            os.chmod(p, 0o600)
        except Exception:
            pass

def make_executable(p: Path):
    if platform.system().lower() != "windows":
        try:
            os.chmod(p, 0o755)
        except Exception:
            pass

def normalize_uuid(u: str) -> str:
    if not u or not isinstance(u, str):
        return ""
    clean = u.strip().lower()
    return clean if re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", clean) else ""

def get_or_generate_uuid() -> str:
    env_val = normalize_uuid(CONF_UUID or os.environ.get("UUID", ""))
    if env_val:
        return env_val
    if UUID_FILE.exists():
        try:
            saved = normalize_uuid(UUID_FILE.read_text(encoding="utf-8"))
            if saved:
                return saved
        except Exception:
            pass
    gen = str(uuid.uuid4())
    try:
        UUID_FILE.write_text(gen, encoding="utf-8")
        secure_permissions(UUID_FILE)
    except Exception:
        pass
    return gen

def http_get(url: str, timeout: float = 3.0) -> str:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return resp.read().decode("utf-8", errors="ignore").strip()
    except Exception:
        pass
    return ""

def find_available_port(start: int = 3000) -> int:
    for p in range(start, start + 1000):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("0.0.0.0", p))
                return p
            except OSError:
                continue
    return start

def wait_port_ready(port: int, host: str = "127.0.0.1", max_wait: float = 10.0) -> bool:
    start = time.time()
    while time.time() - start < max_wait:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            try:
                s.connect((host, port))
                return True
            except (OSError, socket.timeout):
                time.sleep(0.2)
    return False

# ──────────────────────────────────────────────
# TLS 1.3 Reality 探测与域名匹配
# ──────────────────────────────────────────────
def test_tls13(domain: str, port: int = 443, timeout: float = 2.5) -> bool:
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        with socket.create_connection((domain, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as ssock:
                return ssock.version() == "TLSv1.3"
    except Exception:
        return False

def resolve_reality_domain(country: str, custom_domain: str) -> str:
    if custom_domain and custom_domain.strip():
        cd = custom_domain.strip()
        if test_tls13(cd):
            return cd
        logger.warning(f"[Reality] 自定义伪装域名 {cd} 未能通过 TLS 1.3 探测，自动切换备用...")
    pool = GEO_REALITY_DOMAINS.get(country, GEO_REALITY_DOMAINS['DEFAULT'])
    for d in pool:
        if test_tls13(d):
            return d
    return pool[0]

# ──────────────────────────────────────────────
# 二进制下载与解压
# ──────────────────────────────────────────────
def download_file(url: str, dest: Path, timeout: float = 30.0):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status != 200:
            raise RuntimeError(f"下载失败: HTTP {resp.status}")
        with open(dest, "wb") as f:
            shutil.copyfileobj(resp, f)

def check_binary(p: Path, args: list) -> bool:
    if not p.exists():
        return False
    try:
        res = subprocess.run([str(p), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        return res.returncode == 0 or len(res.stdout) > 0
    except Exception:
        return False

def prepare_xray_core() -> Path:
    if check_binary(XRAY_BIN_PATH, ["version"]):
        return XRAY_BIN_PATH
    for sys_b in ["/usr/local/bin/xray", "/usr/bin/xray", "xray"]:
        p = shutil.which(sys_b)
        if p and check_binary(Path(p), ["version"]):
            logger.info(f"[Xray] 使用已有系统核心: {p}")
            return Path(p)

    logger.info("[Xray] 正在下载 XTLS/Xray-core 官方发行版...")
    arch_map = {"x86_64": "64", "amd64": "64", "aarch64": "arm64-v8a", "arm64": "arm64-v8a", "armv7l": "arm32-v7a"}
    plat_map = {"linux": "linux", "darwin": "macos", "windows": "windows"}
    plat = plat_map.get(platform.system().lower(), "linux")
    arch = arch_map.get(platform.machine().lower(), "64")

    asset = f"Xray-{plat}-{arch}.zip"
    url = f"https://github.com/XTLS/Xray-core/releases/latest/download/{asset}"
    tmp_zip = CORE_DIR / f".xray_dl_{int(time.time()*1000)}.zip"
    try:
        download_file(url, tmp_zip, 45.0)
        with zipfile.ZipFile(tmp_zip) as z:
            z.extractall(CORE_DIR / ".xray_tmp")
        extracted = CORE_DIR / ".xray_tmp"
        bin_file = extracted / ("xray.exe" if plat == "windows" else "xray")
        if not bin_file.exists():
            raise RuntimeError("Xray 解压包中未找到二进制文件")
        shutil.copy2(bin_file, XRAY_BIN_PATH)
        make_executable(XRAY_BIN_PATH)
        for dat in ["geoip.dat", "geosite.dat"]:
            if (extracted / dat).exists():
                shutil.copy2(extracted / dat, CORE_DIR / dat)
        logger.info("[Xray] 核心引擎及数据包部署完毕")
        return XRAY_BIN_PATH
    finally:
        tmp_zip.unlink(missing_ok=True)
        shutil.rmtree(CORE_DIR / ".xray_tmp", ignore_errors=True)

def prepare_cloudflared() -> Path:
    if check_binary(CF_BIN_PATH, ["version"]):
        return CF_BIN_PATH
    for sys_b in ["/usr/local/bin/cloudflared", "/usr/bin/cloudflared", "cloudflared"]:
        p = shutil.which(sys_b)
        if p and check_binary(Path(p), ["version"]):
            return Path(p)

    logger.info("[Argo] 下载 Cloudflare Tunnel 桥接组件...")
    table = {
        "linux": {"x86_64": "linux-amd64", "amd64": "linux-amd64", "aarch64": "linux-arm64", "arm64": "linux-arm64"},
        "darwin": {"x86_64": "darwin-amd64", "arm64": "darwin-arm64"},
        "windows": {"x86_64": "windows-amd64.exe", "amd64": "windows-amd64.exe"}
    }
    plat = platform.system().lower()
    arch = platform.machine().lower()
    suffix = table.get(plat, {}).get(arch)
    if not suffix:
        raise RuntimeError(f"不支持的 Cloudflared 架构: {plat}-{arch}")

    is_mac = plat == "darwin"
    asset = f"cloudflared-{suffix}{'.tgz' if is_mac else ''}"
    url = f"https://github.com/cloudflare/cloudflared/releases/latest/download/{asset}"
    if is_mac:
        tgz = CORE_DIR / f".cf_{int(time.time()*1000)}.tgz"
        try:
            download_file(url, tgz, 30.0)
            subprocess.run(["tar", "-xzf", str(tgz), "-C", str(CORE_DIR)], check=True)
        finally:
            tgz.unlink(missing_ok=True)
    else:
        download_file(url, CF_BIN_PATH, 30.0)
    make_executable(CF_BIN_PATH)
    logger.info("[Argo] 桥接组件就绪")
    return CF_BIN_PATH

def prepare_komari_agent():
    if check_binary(KM_BIN_PATH, ["--version"]):
        return KM_BIN_PATH
    p = shutil.which("komari-agent")
    if p and check_binary(Path(p), ["--version"]):
        return Path(p)

    table = {
        "linux": {"x86_64": "linux_amd64", "amd64": "linux_amd64", "aarch64": "linux_arm64", "arm64": "linux_arm64"},
        "darwin": {"x86_64": "darwin_amd64", "arm64": "darwin_arm64"},
        "windows": {"x86_64": "windows_amd64.exe", "amd64": "windows_amd64.exe"}
    }
    plat = platform.system().lower()
    arch = platform.machine().lower()
    suffix = table.get(plat, {}).get(arch)
    if not suffix:
        return None
    url = f"https://github.com/komari-monitoring/komari-agent/releases/latest/download/komari-agent_{suffix}"
    try:
        download_file(url, KM_BIN_PATH, 20.0)
        make_executable(KM_BIN_PATH)
        return KM_BIN_PATH
    except Exception as e:
        logger.warning(f"[Komari] 下载失败: {e}")
        return None

# ──────────────────────────────────────────────
# 进程守护管理
# ──────────────────────────────────────────────
def supervise_process(tag: str, cmd: list, env: dict = None):
    def runner():
        restart_count = 0
        while not is_shutting_down:
            try:
                proc = subprocess.Popen(
                    cmd,
                    env=env or os.environ.copy(),
                    stdout=subprocess.DEVNULL if "Fixed" not in tag and "Quick" not in tag else subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                tracked_subprocesses.append(proc)
                proc.wait()
            except Exception as e:
                logger.warning(f"[{tag}] 启动异常: {e}")
            if is_shutting_down:
                break
            restart_count += 1
            delay = min(1.0 * (1.5 ** restart_count), 15.0)
            logger.warning(f"[{tag}] 异常退出，{delay:.1f}s 后自动重启...")
            time.sleep(delay)
    t = threading.Thread(target=runner, daemon=True)
    t.start()
    return t

def setup_container_uptime():
    global uptime_thread
    if not is_container_environment() or uptime_thread:
        return
    fake = Path("/tmp/.fake_uptime")
    try:
        fake.write_text("0.00 0.00\n", encoding="utf-8")
        subprocess.run(["mount", "--bind", str(fake), "/proc/uptime"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        start_t = time.time()
        def worker():
            while not is_shutting_down:
                up = f"{time.time() - start_t:.2f}"
                try:
                    fake.write_text(f"{up} {up}\n", encoding="utf-8")
                except Exception:
                    pass
                time.sleep(2.0)
        uptime_thread = threading.Thread(target=worker, daemon=True)
        uptime_thread.start()
    except Exception:
        pass

def get_reality_keys(xray_bin: Path):
    priv, pub = "", ""
    if REALITY_KEY_FILE.exists():
        try:
            saved = json.loads(REALITY_KEY_FILE.read_text(encoding="utf-8"))
            priv, pub = saved.get("privKey", ""), saved.get("pubKey", "")
        except Exception:
            pass
    if not priv or not pub:
        try:
            out = subprocess.check_output([str(xray_bin), "x25519"], text=True, stderr=subprocess.STDOUT)
            m_priv = re.search(r"Private\s*key:\s*(\S+)", out, re.I)
            m_pub  = re.search(r"Public\s*key:\s*(\S+)", out, re.I)
            if m_priv and m_pub:
                priv, pub = m_priv.group(1), m_pub.group(1)
                REALITY_KEY_FILE.write_text(json.dumps({"privKey": priv, "pubKey": pub}, indent=2), encoding="utf-8")
                secure_permissions(REALITY_KEY_FILE)
        except Exception as e:
            logger.error(f"[Reality] x25519 密钥生成失败: {e}")
    return priv, pub

# ──────────────────────────────────────────────
# 主入口逻辑
# ──────────────────────────────────────────────
def main():
    kill_stale_by_tags()

    # 1. 载入伪装网页
    camouflage_html = "<h1>Welcome</h1>"
    for p in [Path(__file__).parent / "index.html", Path.cwd() / "index.html", CORE_DIR / "index.html"]:
        if p.exists():
            try:
                camouflage_html = p.read_text(encoding="utf-8")
                break
            except Exception:
                pass

    UUID = get_or_generate_uuid()
    TROJAN_PASS = UUID
    SUB_PATH = (CONF_SUB or os.environ.get("SUB", "sub")).strip().lstrip("/")
    INBOUND_PORT = int(CONF_PORT or os.environ.get("PORT") or find_available_port(3000))
    ARGO_PORT = int(CONF_ARGO_PORT or os.environ.get("ARGO_PORT", "8001"))
    DISABLE_ARGO = (CONF_DISABLE_ARGO or os.environ.get("DISABLE_ARGO", "")).lower() == "true"
    ARGO_DOMAIN = (CONF_ARGO_DOMAIN or os.environ.get("ARGO_DOMAIN", "")).strip()
    ARGO_AUTH = (CONF_ARGO_AUTH or os.environ.get("ARGO_AUTH", "")).strip()
    ARGO_PROTOCOL = (CONF_ARGO_PROTOCOL or os.environ.get("ARGO_PROTOCOL", "")).strip()

    REALITY_PORT = (CONF_REALITY_PORT or os.environ.get("REALITY_PORT", "")).strip()
    SS_PORT = (CONF_SS_PORT or os.environ.get("SS_PORT", "")).strip()
    SS_PASS = (CONF_SS_PASS or os.environ.get("SS_PASS", "") or base64.b64encode(os.urandom(16)).decode("utf-8")).strip()
    S5_PORT = (CONF_S5_PORT or os.environ.get("S5_PORT", "")).strip()
    S5_USER = (CONF_S5_USER or os.environ.get("S5_USER", "") or UUID[:8]).strip()
    S5_PASS = (CONF_S5_PASS or os.environ.get("S5_PASS", "") or UUID[-12:]).strip()

    KOMARI_DOMAIN = (CONF_KOMARI_DOMAIN or os.environ.get("KOMARI_DOMAIN", "")).strip()
    KOMARI_TOKEN  = (CONF_KOMARI_TOKEN  or os.environ.get("KOMARI_TOKEN", "")).strip()

    # 2. 准备二进制核心
    xray_bin = prepare_xray_core()

    # 3. 异步探测公网 IP 与地理位置 (0 阻塞)
    geo_country = "DEFAULT"
    PUBLIC_IP = (CONF_IP or os.environ.get("PUBLIC_IP") or os.environ.get("IP", "")).strip()
    NODE_NAME = (CONF_NAME or os.environ.get("NAME", "")).strip()

    def probe_geo():
        nonlocal PUBLIC_IP, geo_country, NODE_NAME
        try:
            if not PUBLIC_IP:
                PUBLIC_IP = http_get("https://ipinfo.io/ip") or http_get("https://ifconfig.co/ip")
            c = http_get("https://ipinfo.io/country")
            if c:
                geo_country = c.strip().upper()
            org = http_get("https://ipinfo.io/org")
            if not NODE_NAME:
                clean_org = re.sub(r"[^a-zA-Z0-9]", "", org) if org else ""
                NODE_NAME = f"{geo_country}-{clean_org}" if geo_country and clean_org else (geo_country or "xray")
        except Exception:
            pass
        if not NODE_NAME:
            NODE_NAME = "xray"

    geo_thread = threading.Thread(target=probe_geo, daemon=True)
    geo_thread.start()

    # 4. 构建 Xray 配置
    inbounds = []
    if not DISABLE_ARGO:
        inbounds.extend([
            {
                "tag": "vmess-ws-in",
                "port": V_VMESS_PORT,
                "listen": "127.0.0.1",
                "protocol": "vmess",
                "settings": {"clients": [{"id": UUID, "alterId": 0}]},
                "streamSettings": {"network": "ws", "wsSettings": {"path": WS_PATH_VMESS}}
            },
            {
                "tag": "vless-ws-in",
                "port": V_VLESS_PORT,
                "listen": "127.0.0.1",
                "protocol": "vless",
                "settings": {"clients": [{"id": UUID}], "decryption": "none"},
                "streamSettings": {"network": "ws", "wsSettings": {"path": WS_PATH_VLESS}}
            },
            {
                "tag": "trojan-ws-in",
                "port": V_TROJAN_PORT,
                "listen": "127.0.0.1",
                "protocol": "trojan",
                "settings": {"clients": [{"password": TROJAN_PASS}]},
                "streamSettings": {"network": "ws", "wsSettings": {"path": WS_PATH_TROJAN}}
            },
            {
                "tag": "vless-xhttp-in",
                "port": V_XHTTP_PORT,
                "listen": "127.0.0.1",
                "protocol": "vless",
                "settings": {"clients": [{"id": UUID}], "decryption": "none"},
                "streamSettings": {
                    "network": "xhttp",
                    "xhttpSettings": {"path": XHTTP_PATH_VLESS, "mode": "packet-up"}
                }
            }
        ])

    reality_domain = ""
    reality_pub_key = ""
    if REALITY_PORT and REALITY_PORT.isdigit():
        priv_k, pub_k = get_reality_keys(xray_bin)
        if priv_k and pub_k:
            reality_pub_key = pub_k
            geo_thread.join(timeout=2.0)
            reality_domain = resolve_reality_domain(geo_country, CONF_REALITY_DOMAIN or os.environ.get("REALITY_DOMAIN", ""))
            logger.info(f"[Reality] 启用 VLESS-Reality (Vision)，端口 {REALITY_PORT}，伪装站点: {reality_domain}")
            inbounds.append({
                "tag": "reality-in",
                "port": int(REALITY_PORT),
                "listen": "::",
                "protocol": "vless",
                "settings": {
                    "clients": [{"id": UUID, "flow": "xtls-rprx-vision"}],
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": f"{reality_domain}:443",
                        "xver": 0,
                        "serverNames": [reality_domain],
                        "privateKey": priv_k,
                        "shortIds": [""]
                    }
                },
                "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
            })

    if SS_PORT and SS_PORT.isdigit():
        logger.info(f"[SS] 启用 Shadowsocks 2022，端口 {SS_PORT}")
        inbounds.append({
            "tag": "ss-in",
            "port": int(SS_PORT),
            "listen": "::",
            "protocol": "shadowsocks",
            "settings": {
                "method": "2022-blake3-aes-128-gcm",
                "password": SS_PASS,
                "network": "tcp,udp"
            }
        })

    if S5_PORT and S5_PORT.isdigit():
        logger.info(f"[S5] 启用 Socks5，端口 {S5_PORT}")
        inbounds.append({
            "tag": "s5-in",
            "port": int(S5_PORT),
            "listen": "::",
            "protocol": "socks",
            "settings": {
                "auth": "password",
                "accounts": [{"user": S5_USER, "pass": S5_PASS}],
                "udp": True
            }
        })

    xray_conf = {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
    }

    CONFIG_FILE.write_text(json.dumps(xray_conf, indent=2), encoding="utf-8")
    secure_permissions(CONFIG_FILE)

    # 预校验配置
    try:
        subprocess.run([str(xray_bin), "-test", "-config", str(CONFIG_FILE)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        logger.info("[Xray] 配置预校验成功 (Syntax OK)")
    except subprocess.CalledProcessError as e:
        logger.error(f"[Xray] 配置校验失败: {e.stderr.decode('utf-8', errors='ignore')}")
        sys.exit(1)

    # 启动 Xray
    supervise_process("Xray-core", [str(xray_bin), "run", "-config", str(CONFIG_FILE)])

    if not DISABLE_ARGO:
        for p in [V_VMESS_PORT, V_VLESS_PORT, V_TROJAN_PORT, V_XHTTP_PORT]:
            wait_port_ready(p)

    # 5. Argo 多协议复用反向代理服务
    sub_content_holder = [""]
    current_argo_host = [ARGO_DOMAIN or "your-domain.com"]

    def build_subscription(prefer_h: str, cur_h: str):
        geo_thread.join(timeout=1.0)
        name = NODE_NAME or "xray"
        fmt_ip = f"[{PUBLIC_IP}]" if ":" in PUBLIC_IP else PUBLIC_IP
        links = []
        if not DISABLE_ARGO:
            links.append(f"vless://{UUID}@{prefer_h}:443?encryption=none&security=tls&type=xhttp&host={cur_h}&path={urllib.parse.quote(XHTTP_PATH_VLESS)}&mode=packet-up&sni={cur_h}#{urllib.parse.quote(name + '-VLESS-xhttp')}")
            links.append(f"vless://{UUID}@{prefer_h}:443?encryption=none&security=tls&type=ws&host={cur_h}&path={urllib.parse.quote(WS_PATH_VLESS)}&sni={cur_h}#{urllib.parse.quote(name + '-VLESS-WS')}")
            vmess_d = {
                "v": "2", "ps": f"{name}-VMess-WS", "add": prefer_h, "port": "443",
                "id": UUID, "aid": "0", "scy": "auto", "net": "ws", "type": "none",
                "host": cur_h, "path": WS_PATH_VMESS, "tls": "tls", "sni": cur_h
            }
            links.append(f"vmess://{base64.b64encode(json.dumps(vmess_d).encode('utf-8')).decode('utf-8')}")
            links.append(f"trojan://{TROJAN_PASS}@{prefer_h}:443?security=tls&type=ws&host={cur_h}&path={urllib.parse.quote(WS_PATH_TROJAN)}&sni={cur_h}#{urllib.parse.quote(name + '-Trojan-WS')}")

        if REALITY_PORT and reality_pub_key and fmt_ip:
            links.append(f"vless://{UUID}@{fmt_ip}:{REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={reality_domain}&fp=chrome&pbk={reality_pub_key}&type=tcp#{urllib.parse.quote(name + '-Reality')}")

        if SS_PORT and fmt_ip:
            u_info = base64.b64encode(f"2022-blake3-aes-128-gcm:{SS_PASS}".encode("utf-8")).decode("utf-8")
            links.append(f"ss://{u_info}@{fmt_ip}:{SS_PORT}#{urllib.parse.quote(name + '-SS2022')}")

        if S5_PORT and fmt_ip:
            s5_info = base64.b64encode(f"{S5_USER}:{S5_PASS}".encode("utf-8")).decode("utf-8")
            links.append(f"socks://{s5_info}@{fmt_ip}:{S5_PORT}#{urllib.parse.quote(name + '-Socks5')}")

        b64 = base64.b64encode("\n".join(links).encode("utf-8")).decode("utf-8")
        sub_content_holder[0] = b64
        try:
            SUB_FILE.write_text(b64, encoding="utf-8")
            secure_permissions(SUB_FILE)
        except Exception:
            pass
        return links, b64

    # 内部分流 HTTP / WS Server
    class MultiProxyHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.route_request()

        def do_POST(self):
            self.route_request()

        def route_request(self):
            parsed = urllib.parse.urlparse(self.path)
            # A. xhttp (SplitHTTP) 流反代
            if parsed.path == XHTTP_PATH_VLESS or parsed.path.startswith(XHTTP_PATH_VLESS + "/"):
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", V_XHTTP_PORT, timeout=60)
                    body = None
                    cl = self.headers.get("Content-Length")
                    if cl and cl.isdigit():
                        body = self.rfile.read(int(cl))
                    h_dict = {k: v for k, v in self.headers.items()}
                    conn.request(self.command, self.path, body=body, headers=h_dict)
                    res = conn.getresponse()
                    self.send_response(res.status)
                    for hk, hv in res.getheaders():
                        self.send_header(hk, hv)
                    self.end_headers()
                    shutil.copyfileobj(res, self.wfile)
                except Exception as e:
                    self.send_error(502, f"Bad Gateway: {e}")
                return

            # B. 订阅接口
            if parsed.path.strip("/") == SUB_PATH:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Cache-Control", "no-cache, no-store")
                self.end_headers()
                self.wfile.write(sub_content_holder[0].encode("utf-8"))
                return

            # C. 伪装网页
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(camouflage_html.encode("utf-8"))

        def handle_one_request(self):
            # 捕获 WebSocket Upgrade 升级
            try:
                self.raw_requestline = self.rfile.readline(65537)
                if not self.raw_requestline:
                    self.close_connection = True
                    return
                if not self.parse_request():
                    return

                upgrade = self.headers.get("Upgrade", "").lower()
                if upgrade == "websocket":
                    p = urllib.parse.urlparse(self.path).path
                    target_port = None
                    if p == WS_PATH_VLESS:
                        target_port = V_VLESS_PORT
                    elif p == WS_PATH_VMESS:
                        target_port = V_VMESS_PORT
                    elif p == WS_PATH_TROJAN:
                        target_port = V_TROJAN_PORT
                    if target_port:
                        self.proxy_websocket(target_port)
                        return

                mname = 'do_' + self.command
                if not hasattr(self, mname):
                    self.send_error(501, f"Unsupported method ({self.command})")
                    return
                method = getattr(self, mname)
                method()
                self.wfile.flush()
            except (socket.timeout, ConnectionResetError, BrokenPipeError):
                self.close_connection = True

        def proxy_websocket(self, port: int):
            try:
                target_sock = socket.create_connection(("127.0.0.1", port), timeout=10)
                client_sock = self.connection

                # 发送重组的 HTTP 请求头至内部端口
                req_lines = [self.raw_requestline.decode("utf-8", errors="ignore")]
                for k, v in self.headers.items():
                    req_lines.append(f"{k}: {v}\r\n")
                req_lines.append("\r\n")
                target_sock.sendall("".join(req_lines).encode("utf-8"))

                # 双向全双工转发
                sockets = [client_sock, target_sock]
                while not is_shutting_down:
                    r, _, _ = select.select(sockets, [], sockets, 30.0)
                    if not r:
                        break
                    for s in r:
                        other = target_sock if s is client_sock else client_sock
                        data = s.recv(65536)
                        if not data:
                            return
                        other.sendall(data)
            except Exception:
                pass
            finally:
                self.close_connection = True

    if not DISABLE_ARGO:
        class ThreadedTCPServer(http.server.ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        argo_server = ThreadedTCPServer(("127.0.0.1", ARGO_PORT), MultiProxyHandler)
        threading.Thread(target=argo_server.serve_forever, daemon=True).start()
        logger.info(f"[Argo] 多协议单端口分流引擎运行于 127.0.0.1:{ARGO_PORT}")

    main_server = http.server.ThreadingHTTPServer(("0.0.0.0", INBOUND_PORT), MultiProxyHandler)
    threading.Thread(target=main_server.serve_forever, daemon=True).start()
    logger.info(f"[HTTP] Web 伪装站与订阅服务运行于 http://0.0.0.0:{INBOUND_PORT}")

    prefer_host = CONF_CF_PREFER_HOST or os.environ.get("CF_PREFER_HOST", CF_PREFER_HOST_CANDIDATES[0])
    links, _ = build_subscription(prefer_host, current_argo_host[0])

    def on_ready(h: str):
        current_argo_host[0] = h
        cur_links, _ = build_subscription(prefer_host, h)
        if (CONF_SHOW_LOG or os.environ.get("SHOW_LOG", "true")).lower() != "false":
            print("\n============================================================")
            print("🚀 Xray 多功能综合穿透代理服务已就绪 (Python)")
            print(f"📌 节点标识: {NODE_NAME} (地区: {geo_country})")
            print(f"🔗 外部订阅: http://{PUBLIC_IP or '127.0.0.1'}:{INBOUND_PORT}/{SUB_PATH}")
            if not DISABLE_ARGO:
                print(f"🛡️ Argo 域名: {h}")
            print("---------------- 节点订阅明细 ----------------")
            for lk in cur_links:
                print(lk)
            print("============================================================\n")

    # 6. 启动 Cloudflared
    if not DISABLE_ARGO:
        cf_bin = prepare_cloudflared()
        if ARGO_DOMAIN and ARGO_AUTH:
            logger.info(f"[Argo] 启动固定隧道: {ARGO_DOMAIN}...")
            cmd = [str(cf_bin), "tunnel", "--edge-ip-version", "auto", "--no-autoupdate"]
            if ARGO_PROTOCOL:
                cmd.extend(["--protocol", ARGO_PROTOCOL])
            cmd.append("run")
            env = os.environ.copy()
            env["TUNNEL_TOKEN"] = ARGO_AUTH
            def cf_runner():
                while not is_shutting_down:
                    proc = subprocess.Popen(cmd, env=env, stderr=subprocess.PIPE, text=True)
                    tracked_subprocesses.append(proc)
                    for line in proc.stderr:
                        if "Registered tunnel connection" in line:
                            logger.info("[Argo] 固定隧道已建立连接 (Registered tunnel connection)")
                            on_ready(ARGO_DOMAIN)
                    proc.wait()
                    time.sleep(3.0)
            threading.Thread(target=cf_runner, daemon=True).start()
        else:
            logger.info("[Argo] 启动临时隧道 (Quick Tunnel)...")
            cmd = [str(cf_bin), "tunnel", "--edge-ip-version", "auto", "--no-autoupdate"]
            if ARGO_PROTOCOL:
                cmd.extend(["--protocol", ARGO_PROTOCOL])
            cmd.extend(["--url", f"http://127.0.0.1:{ARGO_PORT}"])
            def quick_runner():
                while not is_shutting_down:
                    proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)
                    tracked_subprocesses.append(proc)
                    for line in proc.stderr:
                        m = re.search(r"https://([a-zA-Z0-9-]+\.trycloudflare\.com)", line)
                        if m:
                            nh = m.group(1)
                            if nh != current_argo_host[0]:
                                current_argo_host[0] = nh
                                logger.info(f"[Argo] 临时域名已分配: https::{nh}")
                                on_ready(nh)
                    proc.wait()
                    time.sleep(3.0)
            threading.Thread(target=quick_runner, daemon=True).start()

    # 7. 启动 Komari
    if KOMARI_DOMAIN and KOMARI_TOKEN:
        km_bin = prepare_komari_agent()
        if km_bin:
            setup_container_uptime()
            km_cmd = [str(km_bin), "-e", re.sub(r"^https?://", "", KOMARI_DOMAIN), "-t", KOMARI_TOKEN]
            supervise_process("Komari-Agent", km_cmd)

    while not is_shutting_down:
        time.sleep(1.0)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logger.error(f"[致命错误] 服务中断: {e}", exc_info=True)
        sys.exit(1)
