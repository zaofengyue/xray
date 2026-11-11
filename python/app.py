"""app.py — py-xray 单文件跨平台服务端调度程序。
功能集成: Xray-core / Cloudflare Argo / Komari 探针 / 单端口多协议复用 / 动态订阅
零第三方 pip 依赖 (纯 Python 3.8+ 标准库实现)。
"""

# ==================== 预留配置（留空则读取环境变量或自动识别） ====================
# ── 1. 基础配置 ──
CONF_UUID           = ""  # 服务 UUID（留空自动生成标准 UUID）
CONF_PORT           = ""  # HTTP 外部服务端口（默认自动搜寻可用端口，如 3000）
CONF_NAME           = ""  # 节点名称前缀（留空自动识别 IP 所在国家与组织，最长等待 3s 保障 Reality 伪装匹配）
CONF_IP             = ""  # 自定义公网 IP（留空自动探测）
CONF_SUB            = ""  # 订阅路径后缀（默认 "sub"，即 /sub）
CONF_SUB_TOKEN      = ""  # 订阅安全访问令牌 Token（留空自动生成随机 Token 并持久化，访问需带 ?token=xxx）

# ── 2. Argo 隧道配置 ──
CONF_DISABLE_ARGO      = ""  # 填 "true" 禁用 Argo，留空则启用
CONF_ARGO_DOMAIN       = ""  # 固定隧道域名（留空使用临时 Quick Tunnel）
CONF_ARGO_AUTH         = ""  # 固定隧道 Token
CONF_ARGO_PORT         = ""  # Argo 内部聚合分流端口（默认 8001）
CONF_ARGO_PROTOCOL     = ""  # Argo 隧道协议（默认留空走高速 QUIC 链路，可选 "http2"、"quic"）
CONF_CF_PREFER_HOST    = ""  # Cloudflare 优选域名/IP（留空默认使用内置优选池首选节点）

# ── 3. xhttp 进阶配置（上下行分离）──
CONF_XHTTP_DOWN_MODE   = ""  # 下行策略: 留空默认同源走 Cloudflare，'reality' 下行复用 Reality，'cdn' 下行第三方 CDN (如 AWS CloudFront)
CONF_XHTTP_DOWN_DOMAIN = ""  # 下行 CDN 域名 (如 d123.cloudfront.net)
CONF_XHTTP_DOWN_HOST   = ""  # 下行 CDN 优选 IP/主机名 (留空默认与域名相同)

# ── 4. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
CONF_REALITY_PORT   = ""  # VLESS-Reality 端口 (TCP, 推荐 443 或自定义高位端口)
CONF_REALITY_DOMAIN = ""  # Reality 伪装域名（留空自动按国家地域自适应匹配合规站点）
CONF_SS_PORT        = ""  # Shadowsocks 2022 端口 (TCP/UDP)
CONF_SS_PASS        = ""  # Shadowsocks 2022 密钥 (留空自动生成 16 字节 Base64)
CONF_S5_PORT        = ""  # SOCKS5 代理端口 (TCP/UDP)
CONF_S5_USER        = ""  # SOCKS5 用户名 (留空自动生成独立随机凭据并持久化)
CONF_S5_PASS        = ""  # SOCKS5 密码 (留空自动生成独立随机凭据并持久化)

# ── 5. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
CONF_KOMARI_DOMAIN  = ""  # Komari 服务端域名（如 komari.example.com）
CONF_KOMARI_TOKEN   = ""  # Komari 探针密钥 Token

# ── 6. 日志与推送功能配置 ──
CONF_SHOW_LOG          = ""  # 是否在控制台显示订阅配置信息（默认 "true"，填 "false" 关闭显示）
CONF_LOG_CLEAR_MINUTES = ""  # 控制台显示配置后自动清理的等待时间（默认 "2" 分钟，填 "0" 则不清除）
CONF_TG_BOT_TOKEN      = ""  # Telegram Bot Token（用于推送服务配置）
CONF_TG_CHAT_ID        = ""  # Telegram Chat ID
# ==============================================================================

import base64
import hmac
import http.client
import http.server
import ipaddress
import json
import logging
import os
import platform
import re
import selectors
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
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

def untrack_subprocess(proc):
    try:
        if proc in tracked_subprocesses:
            tracked_subprocesses.remove(proc)
    except (ValueError, AttributeError):
        pass

def graceful_exit(signum=None, frame=None):
    global is_shutting_down
    if is_shutting_down:
        return
    is_shutting_down = True
    logger.info("收到退出信号，正在安全终止工作进程与网络通道...")
    for p in list(tracked_subprocesses):
        try:
            if p.poll() is None:
                p.terminate()
        except Exception:
            pass
    kill_stale_pids()
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
    uid = os.getuid() if hasattr(os, "getuid") else 0
    candidates = [
        Path("/opt/xray-core"),
        home / ".xray-core",
        Path.cwd() / ".xray-core",
        Path(f"/tmp/xray-core-{uid}")
    ]
    for c in candidates:
        try:
            c.mkdir(parents=True, exist_ok=True)
            if platform.system().lower() != "windows":
                st = c.stat()
                if hasattr(os, "getuid") and st.st_uid != uid:
                    continue
                if (st.st_mode & 0o022) != 0:
                    try:
                        os.chmod(c, 0o700)
                    except Exception:
                        pass
                    re_st = c.stat()
                    if (re_st.st_mode & 0o022) != 0:
                        continue
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
SUB_TOKEN_FILE = CORE_DIR / ".sub-token"
SS_PASS_FILE = CORE_DIR / ".ss-pass"
S5_CREDS_FILE = CORE_DIR / ".s5-creds.json"
CONFIG_FILE = CORE_DIR / ".config.json"
REALITY_KEY_FILE = CORE_DIR / ".reality-keys.json"
SUB_FILE = CORE_DIR / "sub.txt"
PID_FILE = CORE_DIR / ".pids"
pid_lock = threading.Lock()

def record_pid(pid: int):
    with pid_lock:
        try:
            pids = []
            if PID_FILE.exists():
                pids = [p.strip() for p in PID_FILE.read_text(encoding="utf-8").splitlines() if p.strip()]
            if str(pid) not in pids:
                pids.append(str(pid))
                PID_FILE.write_text("\n".join(pids), encoding="utf-8")
                secure_permissions(PID_FILE)
        except Exception:
            pass

def remove_pid(pid: int):
    with pid_lock:
        try:
            if PID_FILE.exists():
                pids = [p.strip() for p in PID_FILE.read_text(encoding="utf-8").splitlines() if p.strip() and p.strip() != str(pid)]
                PID_FILE.write_text("\n".join(pids), encoding="utf-8")
                secure_permissions(PID_FILE)
        except Exception:
            pass

def check_ipv6_supported() -> bool:
    if not socket.has_ipv6:
        return False
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
            s.bind(('::1', 0))
            return True
    except Exception:
        return False

LISTEN_ADDR = "::" if check_ipv6_supported() else "0.0.0.0"

def validate_ip(raw: str) -> str:
    if not raw or not isinstance(raw, str):
        return ""
    cand = raw.strip().strip("[]")
    try:
        ipaddress.ip_address(cand)
        return cand
    except Exception:
        return ""

def kill_stale_pids():
    try:
        if PID_FILE.exists():
            pids = [p.strip() for p in PID_FILE.read_text(encoding="utf-8").splitlines() if p.strip()]
            for p in pids:
                try:
                    pid = int(p)
                    should_kill = True
                    if platform.system().lower() == "linux":
                        try:
                            cmdline = Path(f"/proc/{pid}/cmdline").read_text(encoding="utf-8", errors="ignore")
                            is_our_argv0 = bool(re.search(r"/app/(worker|bridge|metrics)\.js", cmdline, re.I))
                            is_in_core = f"{CORE_DIR}/" in cmdline
                            should_kill = is_our_argv0 or is_in_core
                        except Exception:
                            should_kill = False
                    if should_kill:
                        os.kill(pid, signal.SIGTERM)
                except Exception:
                    pass
            PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass

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
  'DE': ['www.ovh.com', 'debian.mirror.liteserver.nl'],
  'NL': ['debian.mirror.liteserver.nl', 'www.ovh.com'],
  'FR': ['www.ovh.com', 'debian.mirror.liteserver.nl'],
  'GB': ['www.ovh.com', 'gateway.icloud.com'],
  'DEFAULT': ['www.iij.ad.jp', 'gateway.icloud.com']
}

def get_safe_env(extra: dict = None) -> dict:
    allowed_keys = {
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "TMPDIR", "TEMP", "TMP",
        "SYSTEMROOT", "WINDIR", "APPDATA", "LOCALAPPDATA", "COMSPEC", "PATHEXT",
        "LANG", "LC_ALL", "LC_CTYPE", "TZ",
        "LD_LIBRARY_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy"
    }
    safe = {k: v for k, v in os.environ.items() if k in allowed_keys}
    if extra:
        safe.update(extra)
    return safe

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

def get_or_generate_sub_token(preset_token: str) -> str:
    val = (preset_token or os.environ.get("SUB_TOKEN", "")).strip()
    if val:
        return val
    if SUB_TOKEN_FILE.exists():
        try:
            saved = SUB_TOKEN_FILE.read_text(encoding="utf-8").strip()
            if saved:
                return saved
        except Exception:
            pass
    gen = os.urandom(16).hex()
    try:
        SUB_TOKEN_FILE.write_text(gen, encoding="utf-8")
        secure_permissions(SUB_TOKEN_FILE)
    except Exception:
        pass
    return gen

def get_or_generate_ss_pass(preset_pass: str) -> str:
    val = (preset_pass or os.environ.get("SS_PASS", "")).strip()
    if val:
        try:
            dec = base64.b64decode(val)
            if len(dec) == 16:
                return val
            logger.warning(f"[SS] 自定义 SS_PASS base64 解码后为 {len(dec)} 字节（必须为 16 字节），将自动生成标准密钥")
        except Exception:
            pass
    if SS_PASS_FILE.exists():
        try:
            saved = SS_PASS_FILE.read_text(encoding="utf-8").strip()
            if saved and len(base64.b64decode(saved)) == 16:
                return saved
        except Exception:
            pass
    gen = base64.b64encode(os.urandom(16)).decode("utf-8")
    try:
        SS_PASS_FILE.write_text(gen, encoding="utf-8")
        secure_permissions(SS_PASS_FILE)
    except Exception:
        pass
    return gen

def get_or_generate_s5_creds(preset_user: str, preset_pass: str) -> tuple:
    u = (preset_user or os.environ.get("S5_USER", "")).strip()
    p = (preset_pass or os.environ.get("S5_PASS", "")).strip()
    if u and p:
        return u, p
    if S5_CREDS_FILE.exists():
        try:
            saved = json.loads(S5_CREDS_FILE.read_text(encoding="utf-8"))
            if saved.get("user") and saved.get("pass"):
                return saved["user"], saved["pass"]
        except Exception:
            pass
    u = u or ("u" + os.urandom(4).hex())
    p = p or base64.urlsafe_b64encode(os.urandom(12)).decode("utf-8").rstrip("=")
    try:
        S5_CREDS_FILE.write_text(json.dumps({"user": u, "pass": p}, indent=2), encoding="utf-8")
        secure_permissions(S5_CREDS_FILE)
    except Exception:
        pass
    return u, p

def http_get(url: str, timeout: float = 3.0) -> str:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return resp.read().decode("utf-8", errors="ignore").strip()
    except Exception:
        pass
    return ""

def safe_int(val, default: int = 0) -> int:
    try:
        if val is None:
            return default
        return int(str(val).strip())
    except (ValueError, TypeError):
        return default

def find_available_port(start: int = 3000) -> int:
    for p in range(start, start + 1000):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if platform.system().lower() != "windows":
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
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        with socket.create_connection((domain, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as ssock:
                alpn = ssock.selected_alpn_protocol()
                return ssock.version() == "TLSv1.3" and alpn == "h2"
    except Exception:
        return False

def resolve_reality_domain(country: str, custom_domain: str) -> str:
    if custom_domain and custom_domain.strip():
        cd = custom_domain.strip()
        if test_tls13(cd):
            return cd
        logger.warning(f"[Reality] 自定义伪装域名 {cd} 未能通过 TLS 1.3 / HTTP/2 探测，自动切换备用...")
    pool = GEO_REALITY_DOMAINS.get(country, GEO_REALITY_DOMAINS['DEFAULT'])
    for d in pool:
        if test_tls13(d):
            return d
    fallback = pool[0]
    logger.warning(f"[Reality] 警告: 所有候选伪装站点 TLS/h2 探测均未通过（若运行于精简容器请确认是否安装 ca-certificates），已回退默认伪装站点: {fallback}")
    return fallback

# ──────────────────────────────────────────────
# 二进制下载与解压
# ──────────────────────────────────────────────
class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if req.get_full_url().startswith("https:") and newurl.startswith("http:"):
            raise urllib.error.HTTPError(req.full_url, code, "禁止从 HTTPS 降级到 HTTP 重定向 (Insecure redirect)", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def download_file(url: str, dest: Path, timeout: float = 30.0):
    tmp_dest = dest.with_name(f"{dest.name}.tmp_{int(time.time()*1000)}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
        opener = urllib.request.build_opener(SafeRedirectHandler)
        with opener.open(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise RuntimeError(f"下载失败: HTTP {resp.status}")
            with open(tmp_dest, "wb") as f:
                shutil.copyfileobj(resp, f)
        tmp_dest.replace(dest)
    finally:
        tmp_dest.unlink(missing_ok=True)

def fetch_text(url: str, timeout: float = 15.0) -> str:
    tmp = CORE_DIR / f".tmp_txt_{int(time.time()*1000)}"
    try:
        download_file(url, tmp, timeout)
        return tmp.read_text(encoding="utf-8", errors="ignore")
    finally:
        tmp.unlink(missing_ok=True)

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
    dgst_url = f"{url}.dgst"
    tmp_zip = CORE_DIR / f".xray_dl_{int(time.time()*1000)}.zip"
    try:
        expected_sha256 = ""
        try:
            dgst = fetch_text(dgst_url, 15.0)
            m = re.search(r"(?:SHA2-256|SHA256)=\s*([a-f0-9]{64})", dgst, re.I)
            if m:
                expected_sha256 = m.group(1).lower()
        except Exception as e:
            logger.warning(f"[Xray] 获取 dgst 校验和文件失败: {e}")

        download_file(url, tmp_zip, 45.0)

        if expected_sha256:
            import hashlib
            with open(tmp_zip, "rb") as f:
                actual_hash = hashlib.sha256(f.read()).hexdigest().lower()
            if actual_hash != expected_sha256:
                raise RuntimeError(f"Xray 核心包 SHA256 校验不匹配! 预期: {expected_sha256}, 实际: {actual_hash}")
            logger.info(f"[Xray] 核心包 SHA256 校验通过 ({expected_sha256[:16]}...)")
        else:
            logger.warning("[Xray] 未能获取有效 SHA256 校验和，已跳过哈希核验")

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
            extracted_bin = CORE_DIR / "cloudflared"
            if extracted_bin.exists():
                extracted_bin.replace(CF_BIN_PATH)
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
        "linux": {"x86_64": "linux-amd64", "amd64": "linux-amd64", "aarch64": "linux-arm64", "arm64": "linux-arm64"},
        "darwin": {"x86_64": "darwin-amd64", "arm64": "darwin-arm64"},
        "windows": {"x86_64": "windows-amd64.exe", "amd64": "windows-amd64.exe"}
    }
    plat = platform.system().lower()
    arch = platform.machine().lower()
    suffix = table.get(plat, {}).get(arch)
    if not suffix:
        return None
    url = f"https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-{suffix}"
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
            proc = None
            start_t = time.time()
            try:
                proc = subprocess.Popen(
                    cmd,
                    env=env or get_safe_env(),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                if proc.pid:
                    record_pid(proc.pid)
                tracked_subprocesses.append(proc)
                proc.wait()
                if time.time() - start_t > 30.0:
                    restart_count = 0
            except Exception as e:
                logger.warning(f"[{tag}] 启动异常: {e}")
            finally:
                if proc:
                    if proc.pid:
                        remove_pid(proc.pid)
                    untrack_subprocess(proc)
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
    priv, pub, short_id = "", "", ""
    if REALITY_KEY_FILE.exists():
        try:
            saved = json.loads(REALITY_KEY_FILE.read_text(encoding="utf-8"))
            priv, pub = saved.get("privKey", ""), saved.get("pubKey", "")
            short_id = saved.get("shortId", "")
        except Exception:
            pass
    if not short_id:
        short_id = os.urandom(4).hex()
    if not priv or not pub:
        try:
            out = subprocess.check_output([str(xray_bin), "x25519"], text=True, stderr=subprocess.STDOUT, timeout=5)
            m_priv = re.search(r"(?:Private\s*key|PrivateKey)\s*:\s*(\S+)", out, re.I)
            m_pub  = re.search(r"(?:Password\s*\(PublicKey\)|Public\s*key|PublicKey|Password)\s*:\s*(\S+)", out, re.I)
            if m_priv and m_pub:
                priv, pub = m_priv.group(1), m_pub.group(1)
                REALITY_KEY_FILE.write_text(json.dumps({"privKey": priv, "pubKey": pub, "shortId": short_id}, indent=2), encoding="utf-8")
                secure_permissions(REALITY_KEY_FILE)
            else:
                clean_out = re.sub(r"\s+", " ", out).strip()
                logger.warning(f"[Reality] x25519 密钥解析未完全匹配 (输出: {clean_out})")
        except Exception as e:
            logger.error(f"[Reality] x25519 密钥生成失败: {e}")
    else:
        try:
            REALITY_KEY_FILE.write_text(json.dumps({"privKey": priv, "pubKey": pub, "shortId": short_id}, indent=2), encoding="utf-8")
            secure_permissions(REALITY_KEY_FILE)
        except Exception:
            pass
    return priv, pub, short_id

# ──────────────────────────────────────────────
# 主入口逻辑
# ──────────────────────────────────────────────
def main():
    kill_stale_pids()

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
    SUB_TOKEN = get_or_generate_sub_token(CONF_SUB_TOKEN)
    port_val = safe_int(CONF_PORT or os.environ.get("PORT"))
    INBOUND_PORT = port_val if port_val > 0 else find_available_port(3000)
    argo_p = safe_int(CONF_ARGO_PORT or os.environ.get("ARGO_PORT"), 8001)
    ARGO_PORT = argo_p if argo_p > 0 else 8001
    DISABLE_ARGO = (CONF_DISABLE_ARGO or os.environ.get("DISABLE_ARGO", "")).lower() == "true"
    ARGO_DOMAIN = (CONF_ARGO_DOMAIN or os.environ.get("ARGO_DOMAIN", "")).strip()
    ARGO_AUTH = (CONF_ARGO_AUTH or os.environ.get("ARGO_AUTH", "")).strip()
    ARGO_PROTOCOL = (CONF_ARGO_PROTOCOL or os.environ.get("ARGO_PROTOCOL", "")).strip()

    XHTTP_DOWN_MODE = (CONF_XHTTP_DOWN_MODE or os.environ.get("XHTTP_DOWN_MODE", "")).strip().lower()
    XHTTP_DOWN_DOMAIN = (CONF_XHTTP_DOWN_DOMAIN or os.environ.get("XHTTP_DOWN_DOMAIN", "")).strip()
    XHTTP_DOWN_HOST = (CONF_XHTTP_DOWN_HOST or os.environ.get("XHTTP_DOWN_HOST", "")).strip()

    REALITY_PORT = (CONF_REALITY_PORT or os.environ.get("REALITY_PORT", "")).strip()
    SS_PORT = (CONF_SS_PORT or os.environ.get("SS_PORT", "")).strip()
    SS_PASS = get_or_generate_ss_pass(CONF_SS_PASS)
    S5_PORT = (CONF_S5_PORT or os.environ.get("S5_PORT", "")).strip()
    S5_USER, S5_PASS = get_or_generate_s5_creds(CONF_S5_USER, CONF_S5_PASS)

    # 端口防冲突检查
    configured_ports = [
        ("PORT", INBOUND_PORT),
        ("ARGO_PORT", ARGO_PORT),
        ("REALITY_PORT", int(REALITY_PORT) if REALITY_PORT and REALITY_PORT.isdigit() else 0),
        ("SS_PORT", int(SS_PORT) if SS_PORT and SS_PORT.isdigit() else 0),
        ("S5_PORT", int(S5_PORT) if S5_PORT and S5_PORT.isdigit() else 0),
    ]
    seen_ports = {}
    for name, p in configured_ports:
        if p > 0:
            if p in seen_ports:
                logger.error(f"[配置致命错误] 端口配置冲突: {name} 与 {seen_ports[p]} 同时使用了端口 {p}")
                sys.exit(1)
            seen_ports[p] = name

    KOMARI_DOMAIN = (CONF_KOMARI_DOMAIN or os.environ.get("KOMARI_DOMAIN", "")).strip()
    KOMARI_TOKEN  = (CONF_KOMARI_TOKEN  or os.environ.get("KOMARI_TOKEN", "")).strip()

    # 2. 准备二进制核心
    xray_bin = prepare_xray_core()

    # 3. 异步探测公网 IP 与地理位置
    geo_country = "DEFAULT"
    PUBLIC_IP = validate_ip(CONF_IP or os.environ.get("PUBLIC_IP") or os.environ.get("IP", ""))
    NODE_NAME = (CONF_NAME or os.environ.get("NODE_NAME") or (os.environ.get("NAME") if not os.environ.get("WSL_DISTRO_NAME") else "") or "").strip()

    def probe_geo():
        nonlocal PUBLIC_IP, geo_country, NODE_NAME
        try:
            data_str = http_get("https://ipinfo.io/json", timeout=3.0)
            if data_str:
                data = json.loads(data_str)
                if not PUBLIC_IP:
                    PUBLIC_IP = validate_ip(data.get("ip") or "")
                c = (data.get("country") or "").strip().upper()
                if c:
                    geo_country = c
                org = (data.get("org") or "").strip()
                if not NODE_NAME:
                    clean_org = re.sub(r"[^a-zA-Z0-9]", "", org) if org else ""
                    NODE_NAME = f"{geo_country}-{clean_org}" if geo_country and clean_org else (geo_country or "xray")
            else:
                def get_ip():
                    nonlocal PUBLIC_IP
                    if not PUBLIC_IP:
                        cand = http_get("https://ifconfig.co/ip", timeout=3.0) or http_get("https://api.ipify.org", timeout=3.0)
                        PUBLIC_IP = validate_ip(cand)
                def get_c():
                    nonlocal geo_country
                    c = http_get("https://ipinfo.io/country", timeout=3.0)
                    if c:
                        geo_country = c.strip().upper()
                t1 = threading.Thread(target=get_ip, daemon=True)
                t2 = threading.Thread(target=get_c, daemon=True)
                t1.start(); t2.start()
                t1.join(timeout=3.5); t2.join(timeout=3.5)
        except Exception:
            pass
        if not NODE_NAME:
            valid_c = geo_country if geo_country != "DEFAULT" else ""
            NODE_NAME = valid_c or "xray"

    geo_thread = threading.Thread(target=probe_geo, daemon=True)
    geo_thread.start()
    geo_thread.join(timeout=5.0)  # 等待地理探测与 IP 解析完成，确保 Reality 伪装域名匹配实际地理区域

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
    reality_short_id = ""
    if REALITY_PORT and REALITY_PORT.isdigit():
        priv_k, pub_k, reality_short_id = get_reality_keys(xray_bin)
        if priv_k and pub_k:
            reality_pub_key = pub_k
            reality_domain = resolve_reality_domain(geo_country, CONF_REALITY_DOMAIN or os.environ.get("REALITY_DOMAIN", ""))
            logger.info(f"[Reality] 启用 VLESS-Reality (Vision)，端口 {REALITY_PORT}，伪装站点: {reality_domain}，shortId: {reality_short_id}")
            has_xhttp = any(ib.get("tag") == "vless-xhttp-in" for ib in inbounds)
            inbounds.append({
                "tag": "reality-in",
                "port": int(REALITY_PORT),
                "listen": LISTEN_ADDR,
                "protocol": "vless",
                "settings": {
                    "clients": [{"id": UUID, "flow": "xtls-rprx-vision"}],
                    "decryption": "none",
                    **({"fallbacks": [{"dest": V_XHTTP_PORT, "xver": 0}]} if has_xhttp else {})
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
                        "shortIds": [reality_short_id]
                    }
                },
                "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
            })

    if SS_PORT and SS_PORT.isdigit():
        logger.info(f"[SS] 启用 Shadowsocks 2022，端口 {SS_PORT}")
        inbounds.append({
            "tag": "ss-in",
            "port": int(SS_PORT),
            "listen": LISTEN_ADDR,
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
            "listen": LISTEN_ADDR,
            "protocol": "socks",
            "settings": {
                "auth": "password",
                "accounts": [{"user": S5_USER, "pass": S5_PASS}],
                "udp": True,
                **({"ip": PUBLIC_IP} if PUBLIC_IP else {})
            }
        })

    xray_conf = {
        "log": {"loglevel": "warning"},
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "block",
                    "ip": ["geoip:private"]
                }
            ]
        },
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
    supervise_process("Xray-core", [str(xray_bin), "run", "-config", str(CONFIG_FILE)], env=get_safe_env({"XRAY_LOCATION_ASSET": str(CORE_DIR)}))

    if not DISABLE_ARGO:
        ports = [
            (V_VMESS_PORT, "VMess"),
            (V_VLESS_PORT, "VLESS"),
            (V_TROJAN_PORT, "Trojan"),
            (V_XHTTP_PORT, "XHTTP"),
        ]
        failed = [f"{name}({p})" for p, name in ports if not wait_port_ready(p)]
        if failed:
            logger.warning(f"[核心监控] 警告: 内部入站端口就绪超时: {', '.join(failed)}，请检查 Xray 核心是否正常运行")

    # 5. Argo 多协议复用反向代理服务
    sub_content_holder = [""]
    current_argo_host = [ARGO_DOMAIN or ""]

    def build_subscription(prefer_h: str, cur_h: str):
        name = NODE_NAME or "xray"
        fmt_ip = f"[{PUBLIC_IP}]" if ":" in PUBLIC_IP else PUBLIC_IP
        links = []

        xh_extra_param = ""
        if XHTTP_DOWN_MODE == "reality" and REALITY_PORT and reality_pub_key and fmt_ip:
            rx_addr = fmt_ip.strip("[]")
            extra_obj = {
                "xmux": {
                    "maxConcurrency": "16-32",
                    "maxConnections": 0,
                    "cMaxReuseTimes": 0,
                    "hMaxRequestTimes": "600-900",
                    "hMaxReusableSecs": "1800-3000"
                },
                "downloadSettings": {
                    "address": rx_addr,
                    "port": int(REALITY_PORT),
                    "network": "xhttp",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": reality_domain,
                        "fingerprint": "chrome",
                        "show": False,
                        "publicKey": reality_pub_key,
                        "shortId": reality_short_id or "",
                        "spiderX": ""
                    },
                    "xhttpSettings": {
                        "path": XHTTP_PATH_VLESS,
                        "mode": "auto"
                    }
                }
            }
            xh_extra_param = f"&extra={urllib.parse.quote(json.dumps(extra_obj))}"
        elif XHTTP_DOWN_MODE == "cdn" and XHTTP_DOWN_DOMAIN:
            down_host = XHTTP_DOWN_HOST or XHTTP_DOWN_DOMAIN
            extra_obj = {
                "xmux": {
                    "maxConcurrency": "16-32",
                    "maxConnections": 0,
                    "cMaxReuseTimes": 0,
                    "hMaxRequestTimes": "600-900",
                    "hMaxReusableSecs": "1800-3000"
                },
                "downloadSettings": {
                    "address": down_host,
                    "port": 443,
                    "network": "xhttp",
                    "security": "tls",
                    "tlsSettings": {
                        "serverName": XHTTP_DOWN_DOMAIN,
                        "alpn": ["h2", "http/1.1"],
                        "fingerprint": "chrome"
                    },
                    "xhttpSettings": {
                        "path": XHTTP_PATH_VLESS,
                        "host": XHTTP_DOWN_DOMAIN,
                        "mode": "auto"
                    }
                }
            }
            xh_extra_param = f"&extra={urllib.parse.quote(json.dumps(extra_obj))}"

        if not DISABLE_ARGO and cur_h:
            links.append(f"vless://{UUID}@{prefer_h}:443?encryption=none&security=tls&type=xhttp&host={cur_h}&path={urllib.parse.quote(XHTTP_PATH_VLESS)}&mode=packet-up&sni={cur_h}{xh_extra_param}#{urllib.parse.quote(name + '-VLESS-xhttp')}")
            links.append(f"vless://{UUID}@{prefer_h}:443?encryption=none&security=tls&type=ws&host={cur_h}&path={urllib.parse.quote(WS_PATH_VLESS)}&sni={cur_h}#{urllib.parse.quote(name + '-VLESS-WS')}")
            vmess_d = {
                "v": "2", "ps": f"{name}-VMess-WS", "add": prefer_h, "port": "443",
                "id": UUID, "aid": "0", "scy": "auto", "net": "ws", "type": "none",
                "host": cur_h, "path": WS_PATH_VMESS, "tls": "tls", "sni": cur_h
            }
            links.append(f"vmess://{base64.b64encode(json.dumps(vmess_d).encode('utf-8')).decode('utf-8')}")
            links.append(f"trojan://{TROJAN_PASS}@{prefer_h}:443?security=tls&type=ws&host={cur_h}&path={urllib.parse.quote(WS_PATH_TROJAN)}&sni={cur_h}#{urllib.parse.quote(name + '-Trojan-WS')}")

        if REALITY_PORT and reality_pub_key and fmt_ip:
            sid_param = f"&sid={reality_short_id}" if reality_short_id else ""
            links.append(f"vless://{UUID}@{fmt_ip}:{REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={reality_domain}&fp=chrome&pbk={reality_pub_key}{sid_param}&type=tcp#{urllib.parse.quote(name + '-Reality')}")

        if SS_PORT and fmt_ip:
            u_info = base64.urlsafe_b64encode(f"2022-blake3-aes-128-gcm:{SS_PASS}".encode("utf-8")).decode("utf-8").rstrip("=")
            links.append(f"ss://{u_info}@{fmt_ip}:{SS_PORT}#{urllib.parse.quote(name + '-SS2022')}")

        if S5_PORT and fmt_ip:
            s5_info = base64.urlsafe_b64encode(f"{S5_USER}:{S5_PASS}".encode("utf-8")).decode("utf-8").rstrip("=")
            links.append(f"socks://{s5_info}@{fmt_ip}:{S5_PORT}#{urllib.parse.quote(name + '-Socks5')}")

        if links:
            b64 = base64.b64encode("\n".join(links).encode("utf-8")).decode("utf-8")
            sub_content_holder[0] = b64
            try:
                SUB_FILE.write_text(b64, encoding="utf-8")
                secure_permissions(SUB_FILE)
            except Exception:
                pass
            return links, b64
        return [], ""

    # 内部分流 HTTP / WS Server (多路复用网关)
    class MultiProxyHandler(http.server.BaseHTTPRequestHandler):
        timeout = 30

        def log_message(self, format, *args):
            pass

        def do_GET(self):
            self.route_request(send_body=True)

        def do_POST(self):
            self.route_request(send_body=True)

        def do_HEAD(self):
            self.route_request(send_body=False)

        def do_OPTIONS(self):
            self.route_request(send_body=True)

        def route_request(self, send_body: bool = True):
            parsed = urllib.parse.urlparse(self.path)

            # A. xhttp (SplitHTTP) 流反代（仅在 argo_server 上分流，或者在无 Argo / 显式开启直连时在主端口分流）
            if parsed.path == XHTTP_PATH_VLESS or parsed.path.startswith(XHTTP_PATH_VLESS + "/"):
                is_main_server = (self.server.server_address[1] == INBOUND_PORT)
                allow_xhttp = (not is_main_server) or DISABLE_ARGO or (os.environ.get("ENABLE_DIRECT_WS", "").lower() == "true")
                if allow_xhttp:
                    self.proxy_stream(V_XHTTP_PORT)
                    return

            # B. 订阅接口
            if parsed.path.strip("/") == SUB_PATH:
                if SUB_TOKEN:
                    query_params = urllib.parse.parse_qs(parsed.query)
                    token_val = query_params.get("token", [""])[0]
                    if not hmac.compare_digest(token_val.encode("utf-8", errors="ignore"), SUB_TOKEN.encode("utf-8", errors="ignore")):
                        self.send_response(404)
                        self.send_header("Content-Type", "text/plain; charset=utf-8")
                        self.end_headers()
                        if send_body:
                            self.wfile.write(b"Not Found")
                        return
                if not sub_content_holder[0]:
                    self.send_response(503)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.end_headers()
                    if send_body:
                        self.wfile.write(b"Tunnel initializing, please retry in 5 seconds...")
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Cache-Control", "no-cache, no-store")
                self.end_headers()
                if send_body:
                    self.wfile.write(sub_content_holder[0].encode("utf-8"))
                return

            # C. 伪装网页
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            if send_body:
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
                    is_main_server = (self.server.server_address[1] == INBOUND_PORT)
                    allow_ws = (not is_main_server) or DISABLE_ARGO or (os.environ.get("ENABLE_DIRECT_WS", "").lower() == "true")
                    if allow_ws:
                        p = urllib.parse.urlparse(self.path).path
                        target_port = None
                        if p == WS_PATH_VLESS:
                            target_port = V_VLESS_PORT
                        elif p == WS_PATH_VMESS:
                            target_port = V_VMESS_PORT
                        elif p == WS_PATH_TROJAN:
                            target_port = V_TROJAN_PORT
                        if target_port:
                            self.proxy_stream(target_port)
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

        def proxy_stream(self, port: int):
            target_sock = None
            try:
                target_sock = socket.create_connection(("127.0.0.1", port), timeout=10)
                client_sock = self.connection
                client_sock.settimeout(None)

                # 发送重组的 HTTP 请求行与请求头至内部端口
                target_sock.sendall(self.raw_requestline)
                req_headers = [f"{k}: {v}\r\n".encode("utf-8") for k, v in self.headers.items()]
                req_headers.append(b"\r\n")
                target_sock.sendall(b"".join(req_headers))

                # 提取 self.rfile 中已被缓冲读取的 Early-Data 数据，避免连接截断与数据丢失
                client_sock.setblocking(False)
                buf_list = []
                try:
                    while True:
                        chunk = self.rfile.read1(65536)
                        if not chunk:
                            break
                        buf_list.append(chunk)
                except (BlockingIOError, socket.error):
                    pass
                finally:
                    client_sock.setblocking(True)

                if buf_list:
                    target_sock.sendall(b"".join(buf_list))

                # 双向全双工透明事件分流转发 (DefaultSelector 支持高并发并解除 FD 1024 上限)
                sel = selectors.DefaultSelector()
                sel.register(client_sock, selectors.EVENT_READ, target_sock)
                sel.register(target_sock, selectors.EVENT_READ, client_sock)
                try:
                    while not is_shutting_down:
                        events = sel.select(timeout=30.0)
                        if not events:
                            continue
                        for key, mask in events:
                            s = key.fileobj
                            other = key.data
                            try:
                                data = s.recv(65536)
                            except Exception:
                                return
                            if not data:
                                return
                            try:
                                other.sendall(data)
                            except Exception:
                                return
                finally:
                    sel.close()
            except Exception:
                pass
            finally:
                if target_sock:
                    try:
                        target_sock.close()
                    except Exception:
                        pass
                self.close_connection = True

    class ThreadedTCPServer(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True
        request_queue_size = 128

    if not DISABLE_ARGO:
        argo_listen_host = "0.0.0.0" if XHTTP_DOWN_MODE == "cdn" else "127.0.0.1"
        argo_server = ThreadedTCPServer((argo_listen_host, ARGO_PORT), MultiProxyHandler)
        threading.Thread(target=argo_server.serve_forever, daemon=True).start()
        logger.info(f"[Argo] 多协议单端口分流引擎运行于 {argo_listen_host}:{ARGO_PORT}")
        if argo_listen_host == "0.0.0.0":
            logger.warning(f"[安全提醒] XHTTP_DOWN_MODE=cdn 模式下 Argo 端口监听 0.0.0.0:{ARGO_PORT} (明文 HTTP)，请确保仅供前置反代/CDN 访问或配置防火墙")

    main_server = ThreadedTCPServer(("0.0.0.0", INBOUND_PORT), MultiProxyHandler)
    threading.Thread(target=main_server.serve_forever, daemon=True).start()
    logger.info(f"[HTTP] Web 伪装站与订阅服务运行于 http://0.0.0.0:{INBOUND_PORT}")
    if DISABLE_ARGO:
        logger.warning("[安全提醒] DISABLE_ARGO 模式下主端口为明文 HTTP，若向公网暴露，建议配置反代或 TLS 证书")

    prefer_host = CONF_CF_PREFER_HOST or os.environ.get("CF_PREFER_HOST", CF_PREFER_HOST_CANDIDATES[0])
    build_subscription(prefer_host, current_argo_host[0])

    def send_telegram_notice(h: str, cur_links: list):
        token = (CONF_TG_BOT_TOKEN or os.environ.get("TG_BOT_TOKEN", "")).strip()
        chat_id = (CONF_TG_CHAT_ID or os.environ.get("TG_CHAT_ID", "")).strip()
        if not token or not chat_id:
            return
        sub_token_query = f"?token={urllib.parse.quote(SUB_TOKEN)}" if SUB_TOKEN else ""
        primary_sub_url = (
            f"https://{h}/{SUB_PATH}{sub_token_query}"
            if not DISABLE_ARGO and h
            else f"http://{PUBLIC_IP or '127.0.0.1'}:{INBOUND_PORT}/{SUB_PATH}{sub_token_query}"
        )
        safe_node = re.sub(r"[`]", "", NODE_NAME or "xray")
        text = (
            f"🎉 *Xray 节点部署成功通知 (Python)*\n"
            f"*节点*: `{safe_node}`\n"
        )
        if not DISABLE_ARGO and h:
            text += f"*域名*: `{h}`\n"
        text += f"*订阅*: `{primary_sub_url}`"

        payload = json.dumps({"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}).encode("utf-8")
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{token}/sendMessage",
                data=payload,
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=5.0)
        except Exception:
            pass

    def on_ready(h: str):
        current_argo_host[0] = h
        cur_links, _ = build_subscription(prefer_host, h)
        if (CONF_SHOW_LOG or os.environ.get("SHOW_LOG", "true")).lower() != "false":
            sub_token_query = f"?token={urllib.parse.quote(SUB_TOKEN)}" if SUB_TOKEN else ""
            primary_sub_url = (
                f"https://{h}/{SUB_PATH}{sub_token_query}"
                if not DISABLE_ARGO and h
                else f"http://{PUBLIC_IP or '127.0.0.1'}:{INBOUND_PORT}/{SUB_PATH}{sub_token_query}"
            )
            print("\n============================================================")
            print("🚀 Xray 多功能综合穿透代理服务已就绪 (Python)")
            print(f"📌 节点标识: {NODE_NAME} (地区: {geo_country})")
            print(f"🔗 外部订阅: {primary_sub_url}")
            if not DISABLE_ARGO and h:
                print(f"🛡️ Argo 域名: {h}")
            print("---------------- 节点订阅明细 ----------------")
            for lk in cur_links:
                print(lk)
            print("============================================================\n")

            clear_min = safe_int(CONF_LOG_CLEAR_MINUTES or os.environ.get("LOG_CLEAR_MINUTES"), 2)
            if clear_min > 0:
                def delayed_clear():
                    time.sleep(clear_min * 60)
                    try:
                        if sys.stdout.isatty():
                            os.system("cls" if os.name == "nt" else "clear")
                            print("[安全自洁] 控制台敏感节点信息已自动清空。")
                    except Exception:
                        pass
                threading.Thread(target=delayed_clear, daemon=True).start()

        send_telegram_notice(h, cur_links)

    # 6. 启动 Cloudflared
    if not DISABLE_ARGO:
        try:
            cf_bin = prepare_cloudflared()
            if ARGO_DOMAIN and ARGO_AUTH:
                logger.info(f"[Argo] 启动固定隧道: {ARGO_DOMAIN}...")
                cmd = [str(cf_bin), "tunnel", "--edge-ip-version", "auto", "--no-autoupdate"]
                if ARGO_PROTOCOL:
                    cmd.extend(["--protocol", ARGO_PROTOCOL])
                cmd.append("run")
                env = get_safe_env({"TUNNEL_TOKEN": ARGO_AUTH})
                def cf_runner():
                    fixed_notified = False
                    while not is_shutting_down:
                        proc = None
                        try:
                            proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                            if proc.pid:
                                record_pid(proc.pid)
                            tracked_subprocesses.append(proc)
                            for line in proc.stderr:
                                if "Registered tunnel connection" in line:
                                    if not fixed_notified:
                                        fixed_notified = True
                                        logger.info("[Argo] 固定隧道已建立连接 (Registered tunnel connection)")
                                        on_ready(ARGO_DOMAIN)
                            proc.wait()
                        except Exception as e:
                            logger.warning(f"[Argo] 固定隧道运行异常: {e}")
                        finally:
                            if proc:
                                if proc.pid:
                                    remove_pid(proc.pid)
                                untrack_subprocess(proc)
                        fixed_notified = False
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
                        proc = None
                        try:
                            proc = subprocess.Popen(cmd, env=get_safe_env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                            if proc.pid:
                                record_pid(proc.pid)
                            tracked_subprocesses.append(proc)
                            for line in proc.stderr:
                                m = re.search(r"https://(?!api\.)([a-zA-Z0-9-]+\.trycloudflare\.com)", line, re.I)
                                if m:
                                    nh = m.group(1)
                                    if nh != current_argo_host[0]:
                                        current_argo_host[0] = nh
                                        logger.info(f"[Argo] 临时域名已分配: https://{nh}")
                                        on_ready(nh)
                            proc.wait()
                        except Exception as e:
                            logger.warning(f"[Argo] 临时隧道运行异常: {e}")
                        finally:
                            if proc:
                                if proc.pid:
                                    remove_pid(proc.pid)
                                untrack_subprocess(proc)
                        time.sleep(3.0)
                threading.Thread(target=quick_runner, daemon=True).start()
        except Exception as err:
            logger.error(f"[Argo] 隧道启动异常: {err}")
            logger.warning("[Argo] Cloudflare 隧道未能启动，将仅提供直连协议订阅")
            on_ready("")
    else:
        logger.info("[Argo] 隧道已被禁用 (DISABLE_ARGO=true)，仅运行直连与本地分流服务")
        on_ready("")

    # 7. 启动 Komari
    if KOMARI_DOMAIN and KOMARI_TOKEN:
        try:
            km_bin = prepare_komari_agent()
            if km_bin:
                setup_container_uptime()
                km_endpoint = KOMARI_DOMAIN.strip()
                if not re.match(r"^https?://", km_endpoint, re.I):
                    km_endpoint = f"https://{km_endpoint}"
                km_cmd = [str(km_bin), "--disable-web-ssh", "--disable-auto-update", "-e", km_endpoint]
                km_env = get_safe_env({"AGENT_ENDPOINT": km_endpoint, "AGENT_TOKEN": KOMARI_TOKEN})
                supervise_process("Komari-Agent", km_cmd, env=km_env)
                logger.info("[Komari] 监控探针已启动 (已禁用远程 Web SSH 与自动更新)")
        except Exception as err:
            logger.warning(f"[Komari] 启动异常: {err}")

    while not is_shutting_down:
        time.sleep(1.0)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as e:
        logger.error(f"[致命错误] 服务中断: {e}", exc_info=True)
    finally:
        graceful_exit()
