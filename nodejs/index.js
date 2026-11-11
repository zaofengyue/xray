// ==============================================================================
// Xray 一体化综合服务调度引擎 (Node.js 跨平台版)
// 功能集成: Xray-core / Cloudflare Argo / Komari 探针 / 单端口多协议复用 / 动态订阅
// ==============================================================================

// ==================== 预留配置（留空则读取环境变量或自动识别） ====================
// ── 1. 基础配置 ──
const PRESET_UUID           = ''; // 服务 UUID（留空自动生成标准 UUID）
const PRESET_PORT           = ''; // HTTP 外部服务端口（默认自动搜寻可用端口，如 3000）
const PRESET_NAME           = ''; // 节点名称前缀（留空自动识别 IP 所在国家与组织，最长等待 3s 保障 Reality 伪装匹配）
const PRESET_IP             = ''; // 自定义公网 IP（留空自动探测）
const PRESET_SUB            = ''; // 订阅路径后缀（默认 'sub'，即 /sub）
const PRESET_SUB_TOKEN      = ''; // 订阅安全访问令牌 Token（留空自动生成随机 Token 并持久化，访问需带 ?token=xxx）

// ── 2. Argo 隧道配置 ──
const PRESET_DISABLE_ARGO      = ''; // 填 'true' 禁用 Argo，留空则启用
const PRESET_ARGO_DOMAIN       = ''; // 固定隧道域名（留空使用临时 Quick Tunnel）
const PRESET_ARGO_AUTH         = ''; // 固定隧道 Token
const PRESET_ARGO_PORT         = ''; // Argo 内部聚合分流端口（默认 8001）
const PRESET_ARGO_PROTOCOL     = ''; // Argo 隧道协议（默认留空走高速 QUIC 链路，可选 'http2'、'quic'）
const PRESET_CF_PREFER_HOST    = ''; // Cloudflare 优选域名/IP（留空默认使用内置优选池首选节点）

// ── 3. xhttp 进阶配置（上下行分离）──
const PRESET_XHTTP_DOWN_MODE   = ''; // 下行策略: 留空默认同源走 Cloudflare，'reality' 下行复用 Reality，'cdn' 下行第三方 CDN (如 AWS CloudFront)
const PRESET_XHTTP_DOWN_DOMAIN = ''; // 下行 CDN 域名 (如 d123.cloudfront.net)
const PRESET_XHTTP_DOWN_HOST   = ''; // 下行 CDN 优选 IP/主机名 (留空默认与域名相同)

// ── 4. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
const PRESET_REALITY_PORT   = ''; // VLESS-Reality 端口 (TCP, 推荐 443 或自定义高位端口)
const PRESET_REALITY_DOMAIN = ''; // Reality 伪装域名（留空自动按国家地域自适应匹配合规站点）
const PRESET_SS_PORT        = ''; // Shadowsocks 2022 端口 (TCP/UDP)
const PRESET_SS_PASS        = ''; // Shadowsocks 2022 密钥 (留空自动生成 16 字节 Base64)
const PRESET_S5_PORT        = ''; // SOCKS5 代理端口 (TCP/UDP)
const PRESET_S5_USER        = ''; // SOCKS5 用户名 (留空自动生成独立随机凭据并持久化)
const PRESET_S5_PASS        = ''; // SOCKS5 密码 (留空自动生成独立随机凭据并持久化)

// ── 5. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
const PRESET_KOMARI_DOMAIN  = ''; // Komari 服务端域名（如 komari.example.com）
const PRESET_KOMARI_TOKEN   = ''; // Komari 探针密钥 Token

// ── 6. 日志与推送功能配置 ──
const PRESET_SHOW_LOG          = ''; // 是否在控制台显示订阅配置信息（默认 'true'，填 'false' 关闭显示）
const PRESET_LOG_CLEAR_MINUTES = ''; // 控制台显示配置后自动清理的等待时间（默认 '2' 分钟，填 '0' 则不清除）
const PRESET_TG_BOT_TOKEN      = ''; // Telegram Bot Token（用于推送服务配置）
const PRESET_TG_CHAT_ID        = ''; // Telegram Chat ID
// ==============================================================================

const { execSync, spawn, spawnSync, execFile, execFileSync } = require('child_process');
const fs     = require('fs');
const os     = require('os');
const https  = require('https');
const http   = require('http');
const crypto = require('crypto');
const net    = require('net');
const path   = require('path');
const tls    = require('tls');

// ──────────────────────────────────────────────
// 全局异常防御与安全退出守护
// ──────────────────────────────────────────────
const trackedProcesses = [];
let isShuttingDown = false;
let uptimeTimer = null;

process.on('uncaughtException', (err) => {
  console.error(`[系统守护] 拦截未捕获异常: ${err && err.stack ? err.stack : (err && err.message ? err.message : err)}`);
});

process.on('unhandledRejection', (reason) => {
  console.warn(`[系统守护] 拦截未处理异步拒绝: ${reason && reason.stack ? reason.stack : (reason && reason.message ? reason.message : reason)}`);
});

function gracefulExit(sig) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`\n[安全退出] 收到 ${sig} 信号，正在清理工作进程与网络通道...`);
  for (const proc of trackedProcesses) {
    try {
      if (proc && !proc.killed) proc.kill('SIGTERM');
    } catch {}
  }
  killStalePids();
  if (uptimeTimer) {
    clearInterval(uptimeTimer);
    try { execSync('umount /proc/uptime', { stdio: 'ignore' }); } catch {}
    try { fs.unlinkSync('/tmp/.fake_uptime'); } catch {}
  }
  setTimeout(() => process.exit(process.exitCode || 0), 300);
}

process.on('SIGTERM', () => gracefulExit('SIGTERM'));
process.on('SIGINT', () => gracefulExit('SIGINT'));

// ──────────────────────────────────────────────
// 运行环境与目录解析
// ──────────────────────────────────────────────
function isContainerEnvironment() {
  if (os.platform() !== 'linux') return false;
  try {
    if (fs.existsSync('/.dockerenv') || fs.existsSync('/run/.containerenv')) return true;
    if (fs.existsSync('/proc/1/cgroup')) {
      const cgroup = fs.readFileSync('/proc/1/cgroup', 'utf8');
      return /docker|kubepods|containerd|lxc/i.test(cgroup);
    }
  } catch {}
  return false;
}

function resolveCoreDir() {
  const home = process.env.HOME || (os.platform() === 'win32' ? process.env.USERPROFILE : '/root') || '.';
  let uid = 0;
  try {
    if (typeof process.getuid === 'function') uid = process.getuid();
    else if (os.userInfo) uid = os.userInfo().uid || 0;
  } catch {}
  const candidates = [
    '/opt/xray-core',
    path.join(home, '.xray-core'),
    path.join(process.cwd(), '.xray-core'),
    path.join(os.tmpdir(), `xray-core-${uid}`)
  ];

  for (const dir of candidates) {
    try {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      if (os.platform() !== 'win32') {
        const stat = fs.statSync(dir);
        const isPrebaked = (dir === '/opt/xray-core' && stat.uid === 0 && uid !== 0 && isContainerEnvironment());
        if (!isPrebaked && typeof process.getuid === 'function' && stat.uid !== uid) continue;
        if (!isPrebaked && (stat.mode & 0o022) !== 0) {
          try { fs.chmodSync(dir, 0o700); } catch {}
          const reStat = fs.statSync(dir);
          if ((reStat.mode & 0o022) !== 0) continue;
        }
      }
      const testFile = path.join(dir, `.w_test_${Date.now()}`);
      fs.writeFileSync(testFile, 'ok');
      fs.unlinkSync(testFile);
      return dir;
    } catch {}
  }
  return path.join(os.tmpdir(), 'xray-core');
}

function resolveAssetDir(coreDir) {
  if (fs.existsSync(path.join(coreDir, 'geoip.dat'))) return coreDir;
  for (const ad of ['/opt/xray-core', '/usr/local/share/xray', '/usr/share/xray']) {
    if (fs.existsSync(path.join(ad, 'geoip.dat'))) return ad;
  }
  return coreDir;
}

const HOME = process.env.HOME || (os.platform() === 'win32' ? process.env.USERPROFILE : '/root') || '.';
const CORE_DIR = resolveCoreDir();
process.env.XRAY_LOCATION_ASSET = resolveAssetDir(CORE_DIR); // 确保在非 root 降级目录时依然能正确载入 geoip.dat / geosite.dat

const SUB_FILE          = path.join(CORE_DIR, 'sub.txt');
const UUID_FILE         = fs.existsSync(path.join(HOME, 'uuid.txt')) ? path.join(HOME, 'uuid.txt') : path.join(CORE_DIR, '.session.key');
const SUB_TOKEN_FILE    = fs.existsSync(path.join(HOME, 'sub-token.txt')) ? path.join(HOME, 'sub-token.txt') : path.join(CORE_DIR, '.sub-token');
const SS_PASS_FILE      = fs.existsSync(path.join(HOME, 'ss-pass.txt')) ? path.join(HOME, 'ss-pass.txt') : path.join(CORE_DIR, '.ss-pass');
const S5_CREDS_FILE     = fs.existsSync(path.join(HOME, 's5-creds.json')) ? path.join(HOME, 's5-creds.json') : path.join(CORE_DIR, '.s5-creds.json');
const CONFIG_FILE       = path.join(CORE_DIR, '.config.json');
const REALITY_KEY_FILE  = fs.existsSync(path.join(HOME, 'reality-keys.json')) ? path.join(HOME, 'reality-keys.json') : path.join(CORE_DIR, '.reality-keys.json');
const PID_FILE          = path.join(CORE_DIR, '.pids');

function secureFilePermissions(filePath) {
  try {
    if (os.platform() !== 'win32') fs.chmodSync(filePath, 0o600);
  } catch {}
}

function secureWriteText(filePath, content) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tmpPath = path.join(dir, `${path.basename(filePath)}.tmp.${Date.now()}_${process.pid}`);
  try {
    fs.writeFileSync(tmpPath, content, { mode: 0o600, encoding: 'utf-8' });
    secureFilePermissions(tmpPath);
    fs.renameSync(tmpPath, filePath);
    secureFilePermissions(filePath);
  } catch (err) {
    try { fs.unlinkSync(tmpPath); } catch {}
    throw err;
  }
}

function recordPid(pid) {
  try {
    let pids = [];
    if (fs.existsSync(PID_FILE)) {
      pids = fs.readFileSync(PID_FILE, 'utf8').split('\n').map(x => x.trim()).filter(Boolean);
    }
    if (!pids.includes(String(pid))) {
      pids.push(String(pid));
      secureWriteText(PID_FILE, pids.join('\n'));
    }
  } catch {}
}

function removePid(pid) {
  try {
    if (fs.existsSync(PID_FILE)) {
      const pids = fs.readFileSync(PID_FILE, 'utf8').split('\n').map(x => x.trim()).filter(p => p && p !== String(pid));
      secureWriteText(PID_FILE, pids.join('\n'));
    }
  } catch {}
}

function killStalePids() {
  try {
    if (fs.existsSync(PID_FILE)) {
      const pids = fs.readFileSync(PID_FILE, 'utf8').split('\n').map(x => x.trim()).filter(Boolean);
      for (const p of pids) {
        const pid = parseInt(p, 10);
        if (pid && !isNaN(pid)) {
          let shouldKill = false;
          // Linux 下校验 /proc/<pid>/cmdline，避免 PID 复用误杀无关系统进程
          if (os.platform() === 'linux') {
            try {
              const cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
              const isOurArgv0  = /\/app\/(worker|bridge|metrics)\.js/i.test(cmdline);
              const isInCoreDir = CORE_DIR && cmdline.includes(CORE_DIR + path.sep);
              shouldKill = isOurArgv0 || isInCoreDir;
            } catch {
              shouldKill = false;
            }
          }
          if (shouldKill) {
            try { process.kill(pid, 'SIGTERM'); } catch {}
          }
        }
      }
      try { fs.unlinkSync(PID_FILE); } catch {}
    }
  } catch {}
}

const XRAY_BIN_NAME     = os.platform() === 'win32' ? 'worker.exe' : 'worker';
const XRAY_BIN_PATH     = path.join(CORE_DIR, XRAY_BIN_NAME);
const CF_BIN_NAME       = os.platform() === 'win32' ? 'bridge.exe' : 'bridge';
const CF_BIN_PATH       = path.join(CORE_DIR, CF_BIN_NAME);
const KM_BIN_NAME       = os.platform() === 'win32' ? 'metrics.exe' : 'metrics';
const KM_BIN_PATH       = path.join(CORE_DIR, KM_BIN_NAME);

// ──────────────────────────────────────────────
// 协议常量定义（单端口复用与内部流转接）
// ──────────────────────────────────────────────
const WS_PATH_VMESS     = '/vmess-ws';
const WS_PATH_VLESS     = '/vless-ws';
const WS_PATH_TROJAN    = '/trojan-ws';
const XHTTP_PATH_VLESS  = '/vless-xhttp';

// Xray 内部入站端口映射
const V_VMESS_PORT      = 10000;
const V_VLESS_PORT      = 10001;
const V_TROJAN_PORT     = 10002;
const V_XHTTP_PORT      = 10003;

// Cloudflare 优选域名候选池
const CF_PREFER_HOST_CANDIDATES = [
  'www.visa.com.tw',
  'www.visa.com.sg',
  'www.visa.com.hk',
  'ip.sb',
  'cf.877774.xyz',
  'cf.090227.xyz',
  'skk.moe',
  'time.is'
];

// 地域自适应合规 Reality 伪装域名池
const GEO_REALITY_DOMAINS = {
  JP: ['www.iij.ad.jp', 'www.rakuten.co.jp'],
  HK: ['www.hkt.com', 'www.hkix.net'],
  SG: ['www.starhub.com', 'www.myrepublic.net'],
  US: ['gateway.icloud.com', 'dl.fedoraproject.org'],
  DE: ['www.ovh.com', 'debian.mirror.liteserver.nl'],
  NL: ['debian.mirror.liteserver.nl', 'www.ovh.com'],
  FR: ['www.ovh.com', 'debian.mirror.liteserver.nl'],
  GB: ['www.ovh.com', 'gateway.icloud.com'],
  DEFAULT: ['www.iij.ad.jp', 'gateway.icloud.com']
};

function getSafeChildEnv(extra = {}) {
  const allowedKeys = [
    'PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL',
    'TMPDIR', 'TEMP', 'TMP',
    'SYSTEMROOT', 'WINDIR', 'APPDATA', 'LOCALAPPDATA', 'COMSPEC', 'PATHEXT',
    'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ',
    'LD_LIBRARY_PATH', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'
  ];
  const safe = {};
  for (const k of allowedKeys) {
    if (process.env[k] !== undefined) safe[k] = process.env[k];
  }
  return { ...safe, ...extra };
}

// ──────────────────────────────────────────────
// 工具函数库
// ──────────────────────────────────────────────
function makeExecutable(filePath) {
  try {
    if (os.platform() !== 'win32') fs.chmodSync(filePath, 0o755);
  } catch {}
}

function normalizeUUID(u) {
  if (!u || typeof u !== 'string') return '';
  const clean = u.trim().toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(clean) ? clean : '';
}

function getOrGenerateUUID() {
  const envVal = normalizeUUID(PRESET_UUID || process.env.UUID);
  if (envVal) return envVal;
  try {
    if (fs.existsSync(UUID_FILE)) {
      const saved = normalizeUUID(fs.readFileSync(UUID_FILE, 'utf8'));
      if (saved) return saved;
    }
  } catch {}
  const generated = crypto.randomUUID();
  try {
    secureWriteText(UUID_FILE, generated);
  } catch {}
  return generated;
}

function getOrGenerateSubToken(presetToken) {
  const custom = (presetToken || process.env.SUB_TOKEN || '').trim();
  if (custom) return custom;
  try {
    if (fs.existsSync(SUB_TOKEN_FILE)) {
      const saved = fs.readFileSync(SUB_TOKEN_FILE, 'utf8').trim();
      if (saved) return saved;
    }
  } catch {}
  const generated = crypto.randomBytes(16).toString('hex');
  try {
    secureWriteText(SUB_TOKEN_FILE, generated);
  } catch {}
  return generated;
}

function getOrGenerateSSPass(presetPass) {
  const custom = (presetPass || process.env.SS_PASS || '').trim();
  if (custom) {
    try {
      const decoded = Buffer.from(custom, 'base64');
      if (decoded.length === 16) return custom;
      console.warn(`[SS] 自定义 SS_PASS base64 解码后为 ${decoded.length} 字节（必须为 16 字节），将自动生成标准密钥`);
    } catch {}
  }
  try {
    if (fs.existsSync(SS_PASS_FILE)) {
      const saved = fs.readFileSync(SS_PASS_FILE, 'utf8').trim();
      if (saved && Buffer.from(saved, 'base64').length === 16) return saved;
    }
  } catch {}
  const generated = crypto.randomBytes(16).toString('base64');
  try {
    secureWriteText(SS_PASS_FILE, generated);
  } catch {}
  return generated;
}

function getOrGenerateS5Creds(presetUser, presetPass) {
  let user = (presetUser || process.env.S5_USER || '').trim();
  let pass = (presetPass || process.env.S5_PASS || '').trim();
  if (user && pass) return { user, pass };

  try {
    if (fs.existsSync(S5_CREDS_FILE)) {
      const saved = JSON.parse(fs.readFileSync(S5_CREDS_FILE, 'utf8'));
      if (saved.user && saved.pass) return saved;
    }
  } catch {}

  user = user || ('u' + crypto.randomBytes(4).toString('hex'));
  pass = pass || crypto.randomBytes(12).toString('base64url');
  try {
    secureWriteText(S5_CREDS_FILE, JSON.stringify({ user, pass }, null, 2));
  } catch {}
  return { user, pass };
}

function timingSafeEqualStr(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function checkIpv6Supported() {
  try {
    return Object.values(os.networkInterfaces()).flat()
      .some(i => i && (i.family === 'IPv6' || i.family === 6) && i.internal);
  } catch {
    return false;
  }
}
const LISTEN_ADDR = checkIpv6Supported() ? '::' : '0.0.0.0';

function validateIp(raw) {
  if (!raw || typeof raw !== 'string') return '';
  const cand = raw.trim().replace(/^\[/, '').replace(/\]$/, '');
  return net.isIP(cand) ? cand : '';
}

function validateHost(raw) {
  if (!raw || typeof raw !== 'string') return '';
  const cand = raw.trim().replace(/^\[/, '').replace(/\]$/, '');
  if (validateIp(cand)) return cand;
  // 允许合规的域名/DDNS 主机名 (总长 <= 253, 标签 1-63 字符且符合 RFC 1123, 最后一个标签 TLD 必须包含字母，杜绝全数字伪 IP)
  if (cand.length <= 253 && /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9-]*[a-zA-Z][a-zA-Z0-9-]*$/.test(cand)) {
    return cand;
  }
  return '';
}

function httpGet(url, timeoutMs = 3000) {
  return new Promise((resolve) => {
    try {
      const client = url.startsWith('https:') ? https : http;
      const req = client.get(url, {
        timeout: timeoutMs,
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
      }, (res) => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          res.resume();
          return resolve('');
        }
        let data = '';
        res.setEncoding('utf8');
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => resolve(data.trim()));
      });
      req.on('timeout', () => { req.destroy(); resolve(''); });
      req.on('error', () => resolve(''));
    } catch {
      resolve('');
    }
  });
}

async function findAvailablePort(startPort = 3000) {
  function testPort(p) {
    return new Promise(resolve => {
      const s = net.createServer();
      s.listen(p, '0.0.0.0', () => {
        s.once('close', () => resolve(true));
        s.close();
      });
      s.on('error', () => resolve(false));
    });
  }
  for (let p = startPort; p < startPort + 1000; p++) {
    if (await testPort(p)) return p;
  }
  return startPort;
}

function waitPortReady(port, host = '127.0.0.1', maxWaitMs = 10000) {
  return new Promise((resolve) => {
    const start = Date.now();
    function check() {
      const sock = new net.Socket();
      sock.setTimeout(500);
      sock.on('connect', () => {
        sock.destroy();
        resolve(true);
      });
      sock.on('error', () => {
        sock.destroy();
        if (Date.now() - start >= maxWaitMs) return resolve(false);
        setTimeout(check, 200);
      });
      sock.on('timeout', () => {
        sock.destroy();
        if (Date.now() - start >= maxWaitMs) return resolve(false);
        setTimeout(check, 200);
      });
      sock.connect(port, host);
    }
    check();
  });
}

// ──────────────────────────────────────────────
// Reality 伪装域名可用性与 TLS 1.3 探测
// ──────────────────────────────────────────────
function testTls13(domain, port = 443, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const s = tls.connect({
      host: domain,
      port,
      servername: domain,
      minVersion: 'TLSv1.3',
      maxVersion: 'TLSv1.3',
      ALPNProtocols: ['h2', 'http/1.1'],
      rejectUnauthorized: true
    });
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        try { s.destroy(); } catch {}
        resolve(false);
      }
    }, timeoutMs);

    s.once('secureConnect', () => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        const alpn = s.alpnProtocol;
        const authorized = s.authorized;
        try { s.destroy(); } catch {}
        resolve(Boolean(authorized && alpn === 'h2'));
      }
    });

    s.once('error', () => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        try { s.destroy(); } catch {}
        resolve(false);
      }
    });
  });
}

async function resolveBestRealityDomain(countryCode, userCustomDomain) {
  if (userCustomDomain && typeof userCustomDomain === 'string' && userCustomDomain.trim()) {
    const d = userCustomDomain.trim();
    const ok = await testTls13(d);
    if (ok) return d;
    console.warn(`[Reality] 自定义伪装域名 ${d} 未能通过 TLS 1.3 / HTTP/2 探测，尝试自动降级...`);
  }

  const pool = GEO_REALITY_DOMAINS[countryCode] || GEO_REALITY_DOMAINS.DEFAULT;
  for (const domain of pool) {
    if (await testTls13(domain)) {
      return domain;
    }
  }
  const fallback = pool[0] || 'www.iij.ad.jp';
  console.warn(`[Reality] 警告: 所有候选伪装站点 TLS/h2 探测均未通过（若运行于精简容器请确认是否安装 ca-certificates），已回退默认伪装站点: ${fallback}`);
  return fallback;
}

// ──────────────────────────────────────────────
// 二进制下载、解压与自检引擎
// ──────────────────────────────────────────────
function downloadBinary(url, destPath, timeoutMs = 30000, maxRedirects = 5) {
  return new Promise((resolve, reject) => {
    const tmpPath = `${destPath}.tmp_${Date.now()}`;
    let settled = false;

    function cleanupTmp() {
      try { if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath); } catch {}
    }
    function fail(err) {
      if (settled) return;
      settled = true;
      cleanupTmp();
      reject(err);
    }
    function succeed() {
      if (settled) return;
      settled = true;
      try {
        if (fs.existsSync(destPath)) fs.unlinkSync(destPath);
        fs.renameSync(tmpPath, destPath);
        resolve(destPath);
      } catch (e) {
        cleanupTmp();
        reject(e);
      }
    }

    function get(currentUrl, redirectCount) {
      if (redirectCount > maxRedirects) {
        return fail(new Error(`超过最大重定向次数 (${maxRedirects})`));
      }
      const client = currentUrl.startsWith('https:') ? https : http;
      const req = client.get(currentUrl, {
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' },
        timeout: timeoutMs
      }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const nextUrl = new URL(res.headers.location, currentUrl).href;
          if (currentUrl.startsWith('https:') && nextUrl.startsWith('http:')) {
            res.resume();
            return fail(new Error('禁止从 HTTPS 降级到 HTTP 重定向 (Insecure redirect)'));
          }
          res.resume();
          return get(nextUrl, redirectCount + 1);
        }
        if (res.statusCode !== 200) {
          res.resume();
          return fail(new Error(`下载失败，HTTP 状态码: ${res.statusCode}`));
        }
        const fileStream = fs.createWriteStream(tmpPath);
        res.pipe(fileStream);
        fileStream.on('finish', () => {
          fileStream.close(() => succeed());
        });
        fileStream.on('error', (err) => fail(err));
        res.on('error', (err) => fail(err));
        res.on('aborted', () => fail(new Error('下载连接意外中断 (Aborted)')));
      });

      req.on('timeout', () => {
        req.destroy();
        fail(new Error(`下载超时 (${timeoutMs}ms)`));
      });
      req.on('error', (err) => fail(err));
    }
    get(url, 0);
  });
}

async function fetchText(url, timeoutMs = 15000, maxRedirects = 5) {
  const tmp = path.join(CORE_DIR, `.tmp_txt_${Date.now()}_${Math.random().toString(36).slice(2)}`);
  try {
    await downloadBinary(url, tmp, timeoutMs, maxRedirects);
    return fs.readFileSync(tmp, 'utf8');
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}

function extractZip(zipPath, targetDir) {
  fs.mkdirSync(targetDir, { recursive: true });
  // 策略 1: 尝试系统自带 tar (Windows 10/11 bsdtar, macOS, Linux 均支持解压 zip)
  try {
    execFileSync('tar', ['-xf', zipPath, '-C', targetDir], { stdio: 'ignore' });
    return true;
  } catch {}

  // 策略 2: 尝试 unzip
  try {
    execFileSync('unzip', ['-q', '-o', zipPath, '-d', targetDir], { stdio: 'ignore' });
    return true;
  } catch {}

  // 策略 3: 尝试 python3 / python zipfile 模块
  for (const py of ['python3', 'python']) {
    try {
      execFileSync(py, ['-m', 'zipfile', '-e', zipPath, targetDir], { stdio: 'ignore' });
      return true;
    } catch {}
  }

  // 策略 4: Windows PowerShell
  if (os.platform() === 'win32') {
    try {
      execFileSync('powershell', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${zipPath}' -DestinationPath '${targetDir}' -Force`], { stdio: 'ignore' });
      return true;
    } catch {}
  }

  throw new Error('未找到可用的解压工具 (tar, unzip, python -m zipfile 或 PowerShell)');
}

function checkBinaryHealthy(binPath, versionArgs = ['version']) {
  if (!fs.existsSync(binPath)) return false;
  try {
    const out = execFileSync(binPath, versionArgs, { encoding: 'utf8', stdio: 'pipe', timeout: 5000 });
    return !!(out && out.length > 0);
  } catch {
    return false;
  }
}

async function prepareXrayCore() {
  if (checkBinaryHealthy(XRAY_BIN_PATH, ['version'])) {
    return XRAY_BIN_PATH;
  }
  // 检查系统 PATH 中的 xray
  for (const sysBin of ['/usr/local/bin/xray', '/usr/bin/xray', 'xray']) {
    if (checkBinaryHealthy(sysBin, ['version'])) {
      console.log(`[Xray] 使用已存在的系统核心: ${sysBin}`);
      return sysBin;
    }
  }

  console.log('[Xray] 正在自动检索并下载 XTLS/Xray-core 官方发行版...');
  const archMap = {
    x64: '64',
    arm64: 'arm64-v8a',
    arm: 'arm32-v7a',
    s390x: 's390x'
  };
  const platMap = {
    linux: 'linux',
    darwin: 'macos',
    win32: 'windows'
  };

  const p = platMap[os.platform()];
  const a = archMap[os.arch()];
  if (!p || !a) throw new Error(`不支持的系统架构: ${os.platform()}-${os.arch()}`);

  const assetName = `Xray-${p}-${a}.zip`;
  const url = `https://github.com/XTLS/Xray-core/releases/latest/download/${assetName}`;
  const dgstUrl = `${url}.dgst`;
  const tmpZip = path.join(CORE_DIR, `.xray_dl_${Date.now()}.zip`);
  const tmpExtract = path.join(CORE_DIR, `.xray_extract_${Date.now()}`);

  try {
    let expectedSha256 = '';
    try {
      const dgst = await fetchText(dgstUrl, 15000);
      const m = dgst.match(/(?:SHA2-256|SHA256)=\s*([a-f0-9]{64})/i);
      if (m) expectedSha256 = m[1].toLowerCase();
    } catch (e) {
      console.warn(`[Xray] 获取 dgst 校验和文件失败: ${e.message}`);
    }

    await downloadBinary(url, tmpZip, 45000);

    if (expectedSha256) {
      const actualHash = crypto.createHash('sha256').update(fs.readFileSync(tmpZip)).digest('hex').toLowerCase();
      if (actualHash !== expectedSha256) {
        throw new Error(`Xray 核心包 SHA256 校验不匹配! 预期: ${expectedSha256}, 实际: ${actualHash}`);
      }
      console.log(`[Xray] 核心包 SHA256 校验通过 (${expectedSha256.slice(0, 16)}...)`);
    } else {
      const allowUnverified = ['true', '1'].includes(String(process.env.ALLOW_UNVERIFIED_BIN || '').toLowerCase());
      if (allowUnverified) {
        console.warn('[Xray] 未能获取有效 SHA256 校验和，因 ALLOW_UNVERIFIED_BIN=true 降级跳过哈希核验');
      } else {
        throw new Error('[安全错误] 未能获取 Xray 的有效 SHA256 校验和 (.dgst)，已中止执行！如需强制跳过校验，请设置环境变量 ALLOW_UNVERIFIED_BIN=true');
      }
    }

    extractZip(tmpZip, tmpExtract);

    const binarySource = path.join(tmpExtract, os.platform() === 'win32' ? 'xray.exe' : 'xray');
    if (!fs.existsSync(binarySource)) throw new Error('解压产物中未找到 xray 执行文件');

    fs.copyFileSync(binarySource, XRAY_BIN_PATH);
    makeExecutable(XRAY_BIN_PATH);

    // 复制 geoip.dat 与 geosite.dat 规则文件至核心目录
    for (const dat of ['geoip.dat', 'geosite.dat']) {
      const srcDat = path.join(tmpExtract, dat);
      if (fs.existsSync(srcDat)) {
        fs.copyFileSync(srcDat, path.join(CORE_DIR, dat));
      }
    }
    console.log('[Xray] 核心引擎及数据资产部署就绪');
    return XRAY_BIN_PATH;
  } finally {
    try { fs.unlinkSync(tmpZip); } catch {}
    try { fs.rmSync(tmpExtract, { recursive: true, force: true }); } catch {}
  }
}

async function prepareCloudflared() {
  if (checkBinaryHealthy(CF_BIN_PATH, ['version'])) return CF_BIN_PATH;
  for (const sysBin of ['/usr/local/bin/cloudflared', '/usr/bin/cloudflared', 'cloudflared']) {
    if (checkBinaryHealthy(sysBin, ['version'])) return sysBin;
  }

  console.log('[Argo] 正在自动下载 Cloudflare Tunnel 桥接组件...');
  const table = {
    linux:  { x64: 'linux-amd64', arm64: 'linux-arm64', arm: 'linux-arm' },
    darwin: { x64: 'darwin-amd64', arm64: 'darwin-arm64' },
    win32:  { x64: 'windows-amd64.exe', ia32: 'windows-386.exe' }
  };
  const suffix = table[os.platform()] && table[os.platform()][os.arch()];
  if (!suffix) throw new Error(`不支持的 Cloudflared 平台架构: ${os.platform()}-${os.arch()}`);

  const isMac = os.platform() === 'darwin';
  const asset = `cloudflared-${suffix}${isMac ? '.tgz' : ''}`;
  const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}`;

  if (isMac) {
    const tgz = path.join(CORE_DIR, `.bridge_${Date.now()}.tgz`);
    const dir = path.join(CORE_DIR, `.bridge_extract_${Date.now()}`);
    try {
      await downloadBinary(url, tgz, 30000);
      fs.mkdirSync(dir, { recursive: true });
      execFileSync('tar', ['-xzf', tgz, '-C', dir]);
      const bin = path.join(dir, 'cloudflared');
      fs.copyFileSync(bin, CF_BIN_PATH);
    } finally {
      try { fs.unlinkSync(tgz); } catch {}
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
    }
  } else {
    await downloadBinary(url, CF_BIN_PATH, 30000);
  }
  makeExecutable(CF_BIN_PATH);
  console.log('[Argo] 桥接组件部署就绪');
  return CF_BIN_PATH;
}

async function prepareKomariAgent() {
  if (checkBinaryHealthy(KM_BIN_PATH, ['--version'])) return KM_BIN_PATH;
  for (const sysBin of ['/usr/local/bin/komari-agent', 'komari-agent']) {
    if (checkBinaryHealthy(sysBin, ['--version'])) return sysBin;
  }

  const table = {
    linux:  { x64: 'linux-amd64', arm64: 'linux-arm64', arm: 'linux-armv7' },
    darwin: { x64: 'darwin-amd64', arm64: 'darwin-arm64' },
    win32:  { x64: 'windows-amd64.exe' }
  };
  const suffix = table[os.platform()] && table[os.platform()][os.arch()];
  if (!suffix) return null;

  console.log('[Komari] 正在下载探针监控组件...');
  const asset = `komari-agent-${suffix}`;
  const url = `https://github.com/komari-monitor/komari-agent/releases/latest/download/${asset}`;
  try {
    await downloadBinary(url, KM_BIN_PATH, 20000);
    makeExecutable(KM_BIN_PATH);
    return KM_BIN_PATH;
  } catch (err) {
    console.warn(`[Komari] 探针下载失败: ${err.message}`);
    return null;
  }
}

// ──────────────────────────────────────────────
// 进程管理与保活守护
// ──────────────────────────────────────────────
function superviseProcess(tag, launcher) {
  let restartCount = 0;
  function start() {
    if (isShuttingDown) return;
    let proc;
    try {
      proc = launcher();
    } catch (err) {
      console.error(`[进程守护] ${tag} 创建失败: ${err.message}`);
      if (!isShuttingDown) {
        restartCount++;
        const delay = Math.min(1000 * Math.pow(1.5, restartCount), 15000);
        setTimeout(start, delay);
      }
      return;
    }
    if (!proc) return;
    if (proc.pid) recordPid(proc.pid);
    trackedProcesses.push(proc);
    const stableTimer = setTimeout(() => {
      restartCount = 0;
    }, 30000);

    let handled = false;
    function scheduleRestart(reason) {
      if (handled) return;
      handled = true;
      clearTimeout(stableTimer);
      if (proc.pid) removePid(proc.pid);
      const idx = trackedProcesses.indexOf(proc);
      if (idx !== -1) trackedProcesses.splice(idx, 1);
      if (isShuttingDown) return;
      restartCount++;
      const delay = Math.min(1000 * Math.pow(1.5, restartCount), 15000);
      console.warn(`[进程守护] ${tag} ${reason}，将在 ${(delay / 1000).toFixed(1)}s 后自动拉起...`);
      setTimeout(start, delay);
    }

    proc.on('error', (err) => {
      console.error(`[进程守护] ${tag} 进程执行异常: ${err.message}`);
      if (!proc.pid) {
        scheduleRestart(`启动失败: ${err.message}`);
      }
    });
    proc.on('exit', (code, sig) => {
      scheduleRestart(`异常退出 (code: ${code}, sig: ${sig})`);
    });
  }
  start();
}

function setupContainerUptime() {
  if (!isContainerEnvironment() || uptimeTimer) return;
  try {
    const fakeUptime = '/tmp/.fake_uptime';
    const startSec = Math.floor(Date.now() / 1000);
    fs.writeFileSync(fakeUptime, '0.00 0.00\n');
    execSync(`mount --bind ${fakeUptime} /proc/uptime`, { stdio: 'ignore' });
    uptimeTimer = setInterval(() => {
      const up = (Math.floor(Date.now() / 1000) - startSec).toFixed(2);
      try { fs.writeFileSync(fakeUptime, `${up} ${up}\n`); } catch {}
    }, 2000);
  } catch {}
}

// ──────────────────────────────────────────────
// Reality 密钥对生成与持久化
// ──────────────────────────────────────────────
function getOrGenerateRealityKeys(xrayBin) {
  let privKey = '', pubKey = '', shortId = '';
  if (fs.existsSync(REALITY_KEY_FILE)) {
    try {
      const saved = JSON.parse(fs.readFileSync(REALITY_KEY_FILE, 'utf8'));
      if (saved.privKey && saved.pubKey) {
        privKey = saved.privKey;
        pubKey  = saved.pubKey;
        shortId = saved.shortId || '';
      }
    } catch {}
  }
  if (!shortId) {
    shortId = crypto.randomBytes(4).toString('hex');
  }
  if (!privKey || !pubKey) {
    try {
      const out = execFileSync(xrayBin, ['x25519'], { encoding: 'utf8', timeout: 5000 });
      const privMatch = out.match(/(?:Private\s*key|PrivateKey)\s*:\s*(\S+)/i);
      const pubMatch  = out.match(/(?:Password\s*\(PublicKey\)|Public\s*key|PublicKey|Password)\s*:\s*(\S+)/i);
      if (privMatch && pubMatch) {
        privKey = privMatch[1];
        pubKey  = pubMatch[1];
        secureWriteText(REALITY_KEY_FILE, JSON.stringify({ privKey, pubKey, shortId }, null, 2));
      } else {
        console.warn(`[Reality] x25519 密钥解析未完全匹配 (输出: ${out.replace(/\s+/g, ' ').trim()})`);
      }
    } catch (e) {
      console.error(`[Reality] x25519 密钥生成失败: ${e.message}`);
    }
  } else {
    // 确保已存在密钥时 shortId 也能被持久化保存
    try {
      secureWriteText(REALITY_KEY_FILE, JSON.stringify({ privKey, pubKey, shortId }, null, 2));
    } catch {}
  }
  return { privKey, pubKey, shortId };
}

// ──────────────────────────────────────────────
// 主程序启动引擎
// ──────────────────────────────────────────────
async function main() {
  killStalePids();

  // 1. 载入伪装网页内容
  try {
    const htmlPaths = [
      path.join(__dirname, 'index.html'),
      path.join(CORE_DIR, 'index.html'),
      path.join(process.cwd(), 'index.html')
    ];
    for (const hp of htmlPaths) {
      if (fs.existsSync(hp)) {
        const content = fs.readFileSync(hp, 'utf8');
        // 严格防泄露保护：绝不将管理部署面板（包含配置生成控件）作为对外 Web 伪装页使用
        if (content.includes('Xray 部署面板') || content.includes('id="field-uuid"') || content.includes('data-key="reality"')) {
          console.warn(`[Web 伪装] 检测到 ${hp} 为部署面板页面，已自动跳过以防管理界面外泄`);
          continue;
        }
        global.CAMOUFLAGE_HTML = content;
        break;
      }
    }
  } catch {}

  const UUID = getOrGenerateUUID();
  const TROJAN_PASS = UUID;
  const SUB_PATH = (PRESET_SUB || process.env.SUB || 'sub').trim().replace(/^\/+/, '');
  const SUB_TOKEN = getOrGenerateSubToken(PRESET_SUB_TOKEN);
  const INBOUND_PORT = parseInt(PRESET_PORT || process.env.PORT || '0', 10) || await findAvailablePort(3000);
  const ARGO_PORT = parseInt(PRESET_ARGO_PORT || process.env.ARGO_PORT || '8001', 10);
  const DISABLE_ARGO = (PRESET_DISABLE_ARGO || process.env.DISABLE_ARGO || '').toLowerCase() === 'true';
  const ARGO_DOMAIN = (PRESET_ARGO_DOMAIN || process.env.ARGO_DOMAIN || '').trim();
  const ARGO_AUTH = (PRESET_ARGO_AUTH || process.env.ARGO_AUTH || '').trim();
  const ARGO_PROTOCOL = (PRESET_ARGO_PROTOCOL || process.env.ARGO_PROTOCOL || '').trim();

  const XHTTP_DOWN_MODE = (PRESET_XHTTP_DOWN_MODE || process.env.XHTTP_DOWN_MODE || '').trim().toLowerCase();
  const XHTTP_DOWN_DOMAIN = (PRESET_XHTTP_DOWN_DOMAIN || process.env.XHTTP_DOWN_DOMAIN || '').trim();
  const XHTTP_DOWN_HOST = (PRESET_XHTTP_DOWN_HOST || process.env.XHTTP_DOWN_HOST || '').trim();

  const REALITY_PORT = (PRESET_REALITY_PORT || process.env.REALITY_PORT || '').trim();
  const SS_PORT = (PRESET_SS_PORT || process.env.SS_PORT || '').trim();
  const SS_PASS = getOrGenerateSSPass(PRESET_SS_PASS);
  const S5_PORT = (PRESET_S5_PORT || process.env.S5_PORT || '').trim();
  const s5Creds = getOrGenerateS5Creds(PRESET_S5_USER, PRESET_S5_PASS);
  const S5_USER = s5Creds.user;
  const S5_PASS = s5Creds.pass;

  // 端口防冲突检查
  const configuredPorts = [
    { name: 'PORT', port: INBOUND_PORT },
    { name: 'ARGO_PORT', port: ARGO_PORT },
    { name: 'REALITY_PORT', port: parseInt(REALITY_PORT, 10) },
    { name: 'SS_PORT', port: parseInt(SS_PORT, 10) },
    { name: 'S5_PORT', port: parseInt(S5_PORT, 10) }
  ].filter(p => !isNaN(p.port) && p.port > 0);

  const portMap = new Map();
  for (const { name, port } of configuredPorts) {
    if (portMap.has(port)) {
      console.error(`[配置致命错误] 端口配置冲突: ${name} 与 ${portMap.get(port)} 同时使用了端口 ${port}`);
      process.exit(1);
    }
    portMap.set(port, name);
  }

  const parsedTimeout = parseInt(process.env.XRAY_IDLE_TIMEOUT || process.env.IDLE_TIMEOUT || '300', 10);
  const IDLE_TIMEOUT_SEC = !isNaN(parsedTimeout) ? parsedTimeout : 300;
  const IDLE_TIMEOUT_MS = IDLE_TIMEOUT_SEC > 0 ? IDLE_TIMEOUT_SEC * 1000 : 0;

  const KOMARI_DOMAIN = (PRESET_KOMARI_DOMAIN || process.env.KOMARI_DOMAIN || '').trim();
  const KOMARI_TOKEN  = (PRESET_KOMARI_TOKEN  || process.env.KOMARI_TOKEN  || '').trim();

  // 2. 准备核心二进制
  const xrayBin = await prepareXrayCore();

  // 3. 异步并发地理探测与节点名称预解析
  let geoCountry = 'DEFAULT';
  let geoOrg = '';
  const rawIpConf = PRESET_IP || process.env.PUBLIC_IP || process.env.IP || '';
  let PUBLIC_IP = validateHost(rawIpConf);
  if (rawIpConf && !PUBLIC_IP) {
    console.warn(`[网络] 显式配置的 IP/域名格式无效: '${rawIpConf}'，将尝试自动探测公网 IP`);
  }
  let NODE_NAME = (PRESET_NAME || process.env.NODE_NAME || (process.env.NAME && !process.env.WSL_DISTRO_NAME ? process.env.NAME : '')).trim();

  const geoPromise = (async () => {
    try {
      if (!PUBLIC_IP || geoCountry === 'DEFAULT') {
        const jsonStr = await httpGet('https://ipinfo.io/json');
        if (jsonStr) {
          try {
            const data = JSON.parse(jsonStr);
            if (!PUBLIC_IP && data.ip) PUBLIC_IP = validateIp(String(data.ip));
            if (data.country) geoCountry = String(data.country).trim().toUpperCase();
            if (data.org) geoOrg = String(data.org).trim();
          } catch {}
        }
      }
    } catch {}
    if (!PUBLIC_IP) {
      try {
        const ipStr = await httpGet('https://api.ipify.org');
        if (ipStr) PUBLIC_IP = validateIp(ipStr);
      } catch {}
    }
    if (!NODE_NAME) {
      const validCountry = geoCountry && geoCountry !== 'DEFAULT' ? geoCountry : '';
      if (validCountry && geoOrg) {
        NODE_NAME = `${validCountry}-${geoOrg.replace(/[^a-zA-Z0-9]/g, '')}`;
      } else if (validCountry) {
        NODE_NAME = validCountry;
      } else {
        NODE_NAME = 'xray';
      }
    }
  })();

  await geoPromise; // 等待地理探测与 IP 解析完成，确保后续 Reality 伪装域名匹配真实的地理区域

  // 4. 构建 Xray 配置 JSON
  const inbounds = [];

  // Argo 内部反代入站
  if (!DISABLE_ARGO) {
    inbounds.push(
      {
        tag: 'vmess-ws-in',
        port: V_VMESS_PORT,
        listen: '127.0.0.1',
        protocol: 'vmess',
        settings: { clients: [{ id: UUID, alterId: 0 }] },
        streamSettings: { network: 'ws', wsSettings: { path: WS_PATH_VMESS } }
      },
      {
        tag: 'vless-ws-in',
        port: V_VLESS_PORT,
        listen: '127.0.0.1',
        protocol: 'vless',
        settings: { clients: [{ id: UUID }], decryption: 'none' },
        streamSettings: { network: 'ws', wsSettings: { path: WS_PATH_VLESS } }
      },
      {
        tag: 'trojan-ws-in',
        port: V_TROJAN_PORT,
        listen: '127.0.0.1',
        protocol: 'trojan',
        settings: { clients: [{ password: TROJAN_PASS }] },
        streamSettings: { network: 'ws', wsSettings: { path: WS_PATH_TROJAN } }
      },
      {
        tag: 'vless-xhttp-in',
        port: V_XHTTP_PORT,
        listen: '127.0.0.1',
        protocol: 'vless',
        settings: { clients: [{ id: UUID }], decryption: 'none' },
        streamSettings: {
          network: 'xhttp',
          xhttpSettings: {
            path: XHTTP_PATH_VLESS,
            mode: 'packet-up'
          }
        }
      }
    );
  }

  // 直连协议：VLESS-Reality
  let realityDomainFinal = '';
  if (REALITY_PORT && !isNaN(parseInt(REALITY_PORT, 10))) {
    const keys = getOrGenerateRealityKeys(xrayBin);
    if (keys.privKey && keys.pubKey) {
      global.REALITY_PUB_KEY = keys.pubKey;
      const realityShortId = keys.shortId;
      global.REALITY_SHORT_ID = realityShortId;
      realityDomainFinal = await resolveBestRealityDomain(geoCountry, PRESET_REALITY_DOMAIN || process.env.REALITY_DOMAIN);
      console.log(`[Reality] 启用 VLESS-Reality (Vision)，端口: ${REALITY_PORT}，伪装站点: ${realityDomainFinal}，shortId: ${realityShortId}`);

      const hasXhttp = inbounds.some(ib => ib.tag === 'vless-xhttp-in');
      inbounds.push({
        tag: 'reality-in',
        port: parseInt(REALITY_PORT, 10),
        listen: LISTEN_ADDR,
        protocol: 'vless',
        settings: {
          clients: [{ id: UUID, flow: 'xtls-rprx-vision' }],
          decryption: 'none',
          ...(hasXhttp ? { fallbacks: [{ dest: V_XHTTP_PORT, xver: 0 }] } : {})
        },
        streamSettings: {
          network: 'tcp',
          security: 'reality',
          realitySettings: {
            show: false,
            dest: `${realityDomainFinal}:443`,
            xver: 0,
            serverNames: [realityDomainFinal],
            privateKey: keys.privKey,
            shortIds: [realityShortId]
          }
        },
        sniffing: {
          enabled: true,
          destOverride: ['http', 'tls', 'quic']
        }
      });
    }
  }

  // 直连协议：Shadowsocks 2022
  if (SS_PORT && !isNaN(parseInt(SS_PORT, 10))) {
    console.log(`[SS] 启用 Shadowsocks 2022 (blake3-aes-128-gcm)，端口: ${SS_PORT}`);
    inbounds.push({
      tag: 'ss-in',
      port: parseInt(SS_PORT, 10),
      listen: LISTEN_ADDR,
      protocol: 'shadowsocks',
      settings: {
        method: '2022-blake3-aes-128-gcm',
        password: SS_PASS,
        network: 'tcp,udp'
      }
    });
  }

  // 直连协议：Socks5
  if (S5_PORT && !isNaN(parseInt(S5_PORT, 10))) {
    console.log(`[S5] 启用 Socks5，端口: ${S5_PORT}`);
    inbounds.push({
      tag: 's5-in',
      port: parseInt(S5_PORT, 10),
      listen: LISTEN_ADDR,
      protocol: 'socks',
      settings: {
        auth: 'password',
        accounts: [{ user: S5_USER, pass: S5_PASS }],
        udp: true,
        ...(validateIp(PUBLIC_IP) ? { ip: PUBLIC_IP } : {})
      }
    });
  }

  const xrayConfig = {
    log: { loglevel: 'warning' },
    routing: {
      domainStrategy: 'IPIfNonMatch',
      rules: [
        {
          type: 'field',
          outboundTag: 'block',
          ip: ['geoip:private']
        }
      ]
    },
    inbounds,
    outbounds: [
      { protocol: 'freedom', tag: 'direct' },
      { protocol: 'blackhole', tag: 'block' }
    ]
  };

  secureWriteText(CONFIG_FILE, JSON.stringify(xrayConfig, null, 2));

  // 校验 Xray 配置文件合法性
  try {
    execFileSync(xrayBin, ['-test', '-config', CONFIG_FILE], { stdio: 'pipe' });
    console.log('[Xray] 配置预校验成功 (Syntax OK)');
  } catch (e) {
    console.error(`[Xray] 配置校验失败: ${e.message}\n${(e.stdout||'')}${(e.stderr||'')}`);
    process.exit(1);
  }

  // 启动 Xray 核心守护进程
  superviseProcess('Xray-core', () => {
    return spawn(xrayBin, ['run', '-config', CONFIG_FILE], {
      argv0: os.platform() !== 'win32' ? 'node /app/worker.js' : undefined,
      stdio: 'ignore',
      env: getSafeChildEnv({ XRAY_LOCATION_ASSET: CORE_DIR })
    });
  });

  if (!DISABLE_ARGO) {
    const readyResults = await Promise.all([
      waitPortReady(V_VMESS_PORT).then(r => ({ port: V_VMESS_PORT, name: 'VMess', ok: r })),
      waitPortReady(V_VLESS_PORT).then(r => ({ port: V_VLESS_PORT, name: 'VLESS', ok: r })),
      waitPortReady(V_TROJAN_PORT).then(r => ({ port: V_TROJAN_PORT, name: 'Trojan', ok: r })),
      waitPortReady(V_XHTTP_PORT).then(r => ({ port: V_XHTTP_PORT, name: 'XHTTP', ok: r }))
    ]);
    const failed = readyResults.filter(r => !r.ok);
    if (failed.length > 0) {
      console.warn(`[核心监控] 警告: 内部入站端口就绪超时: ${failed.map(f => `${f.name}(${f.port})`).join(', ')}，请检查 Xray 核心是否正常运行`);
    }
  }

  // 5. 启动内部 Argo 智能分流多路复用服务 (HTTP / Sub / WS / xhttp)
  let currentArgoHost = ARGO_DOMAIN || '';

  function handleHttp(req, res) {
    let urlObj;
    try {
      urlObj = new URL(req.url, 'http://127.0.0.1');
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      return res.end('Bad Request');
    }
    const pathname = urlObj.pathname;

    // A. VLESS-xhttp (SplitHTTP) 流反向代理（仅在内部 argoServer 或禁用 Argo / 显式开启直连时分流）
    if (pathname === XHTTP_PATH_VLESS || pathname.startsWith(XHTTP_PATH_VLESS + '/')) {
      const isMainServer = req.socket && req.socket.localPort === parseInt(INBOUND_PORT, 10);
      const allowXhttp = !isMainServer || DISABLE_ARGO || process.env.ENABLE_DIRECT_WS === 'true';
      if (allowXhttp) {
        const proxyReq = http.request({
          host: '127.0.0.1',
          port: V_XHTTP_PORT,
          method: req.method,
          path: req.url,
          headers: req.headers
        }, (proxyRes) => {
          proxyRes.on('error', () => {
            res.destroy();
          });
          res.writeHead(proxyRes.statusCode, proxyRes.headers);
          proxyRes.pipe(res);
        });
        if (IDLE_TIMEOUT_MS > 0) {
          proxyReq.setTimeout(IDLE_TIMEOUT_MS, () => {
            proxyReq.destroy();
            res.destroy();
          });
          req.setTimeout(IDLE_TIMEOUT_MS, () => {
            req.destroy();
            proxyReq.destroy();
          });
        }
        proxyReq.on('error', (err) => {
          if (!res.headersSent) {
            res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end(`Bad Gateway: ${err.message}`);
          } else {
            res.destroy();
          }
        });
        res.on('close', () => {
          if (!res.writableEnded) proxyReq.destroy();
        });
        req.on('error', () => proxyReq.destroy());
        req.pipe(proxyReq);
        return;
      }
    }

    // B. /sub 节点订阅接口
    if (pathname === `/${SUB_PATH}` || pathname === `/${SUB_PATH}/`) {
      if (SUB_TOKEN) {
        const tokenParam = urlObj.searchParams.get('token') || '';
        if (!timingSafeEqualStr(tokenParam, SUB_TOKEN)) {
          res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
          return res.end('Not Found');
        }
      }
      if (!global.SUB_CONTENT) {
        res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
        return res.end('Tunnel initializing, please retry in 5 seconds...');
      }
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache, no-store'
      });
      return res.end(global.SUB_CONTENT || '');
    }

    // C. 根路径与默认伪装网页
    if (req.method === 'GET' || req.method === 'HEAD') {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'public, max-age=3600'
      });
      if (req.method === 'HEAD') return res.end();
      if (global.CAMOUFLAGE_HTML) return res.end(global.CAMOUFLAGE_HTML);
      return res.end('<!DOCTYPE html><html><body><h1>Welcome</h1></body></html>');
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }

  // WebSocket 多协议分流处理 (供内部 argoServer 与外部 mainServer 共同复用)
  function handleUpgrade(req, socket, head) {
    const reqPath = req.url.split('?')[0];
    let targetPort = null;
    if (reqPath === WS_PATH_VLESS)       targetPort = V_VLESS_PORT;
    else if (reqPath === WS_PATH_VMESS)  targetPort = V_VMESS_PORT;
    else if (reqPath === WS_PATH_TROJAN) targetPort = V_TROJAN_PORT;
    else {
      socket.destroy();
      return;
    }

    const proxy = net.connect(targetPort, '127.0.0.1', () => {
      const safeHeaders = Object.entries(req.headers)
        .filter(([k, v]) => !/[\r\n]/.test(k) && !/[\r\n]/.test(String(v)))
        .map(([k, v]) => `${k}: ${v}`)
        .join('\r\n');
      proxy.write(`${req.method} ${req.url} HTTP/${req.httpVersion}\r\n${safeHeaders}\r\n\r\n`);
      if (head && head.length > 0) proxy.write(head);
      socket.pipe(proxy);
      proxy.pipe(socket);
    });

    if (IDLE_TIMEOUT_MS > 0) {
      socket.setTimeout(IDLE_TIMEOUT_MS);
      socket.on('timeout', () => socket.destroy());
      proxy.setTimeout(IDLE_TIMEOUT_MS);
      proxy.on('timeout', () => proxy.destroy());
    }

    proxy.on('error', () => socket.destroy());
    socket.on('error', () => proxy.destroy());
  }

  if (!DISABLE_ARGO) {
    const argoServer = http.createServer(handleHttp);
    argoServer.requestTimeout = 0;
    argoServer.on('error', (e) => console.error(`[Argo] 内部服务异常: ${e.message}`));
    argoServer.on('upgrade', handleUpgrade);

    const argoListenHost = XHTTP_DOWN_MODE === 'cdn' ? '0.0.0.0' : '127.0.0.1';
    argoServer.listen(ARGO_PORT, argoListenHost, () => {
      console.log(`[Argo] 多协议单端口复用引擎运行于 ${argoListenHost}:${ARGO_PORT}`);
      if (argoListenHost === '0.0.0.0') {
        console.warn(`[安全提醒] XHTTP_DOWN_MODE=cdn 模式下 Argo 端口监听 0.0.0.0:${ARGO_PORT} (明文 HTTP)，请确保仅供前置反代/CDN 访问或配置防火墙`);
      }
    });
  }

  // 6. 启动外部直连主 HTTP 服务 (挂载 Web、订阅、xhttp；仅在无 Argo 或显式开启时挂载直连 WS)
  const mainServer = http.createServer(handleHttp);
  mainServer.requestTimeout = 0;
  mainServer.on('error', (e) => console.error(`[HTTP] 主服务异常: ${e.message}`));
  if (DISABLE_ARGO || process.env.ENABLE_DIRECT_WS === 'true') {
    mainServer.on('upgrade', handleUpgrade);
  }
  mainServer.listen(INBOUND_PORT, '0.0.0.0', () => {
    console.log(`[HTTP] Web 伪装站点与订阅服务已就绪: http://0.0.0.0:${INBOUND_PORT}`);
    if (DISABLE_ARGO) {
      console.warn('[安全提醒] DISABLE_ARGO 模式下主端口为明文 HTTP，若向公网暴露，建议配置反代或 TLS 证书');
    }
  });

  // 7. 订阅生成器
  function buildSubscription(preferHost, currentHost) {
    const list = [];
    const name = NODE_NAME || 'xray';
    const formattedIp = PUBLIC_IP && PUBLIC_IP.includes(':') ? `[${PUBLIC_IP}]` : PUBLIC_IP;

    let xhExtraParam = '';
    if (XHTTP_DOWN_MODE === 'reality' && REALITY_PORT && global.REALITY_PUB_KEY && formattedIp) {
      const rxAddr = formattedIp.replace(/^\[/, '').replace(/\]$/, '');
      const extraObj = {
        xmux: {
          maxConcurrency: '16-32',
          maxConnections: 0,
          cMaxReuseTimes: 0,
          hMaxRequestTimes: '600-900',
          hMaxReusableSecs: '1800-3000'
        },
        downloadSettings: {
          address: rxAddr,
          port: parseInt(REALITY_PORT, 10),
          network: 'xhttp',
          security: 'reality',
          realitySettings: {
            serverName: realityDomainFinal,
            fingerprint: 'chrome',
            show: false,
            publicKey: global.REALITY_PUB_KEY,
            shortId: global.REALITY_SHORT_ID || '',
            spiderX: ''
          },
          xhttpSettings: {
            path: XHTTP_PATH_VLESS,
            mode: 'auto'
          }
        }
      };
      xhExtraParam = `&extra=${encodeURIComponent(JSON.stringify(extraObj))}`;
    } else if (XHTTP_DOWN_MODE === 'cdn' && XHTTP_DOWN_DOMAIN) {
      const downHost = XHTTP_DOWN_HOST || XHTTP_DOWN_DOMAIN;
      const extraObj = {
        xmux: {
          maxConcurrency: '16-32',
          maxConnections: 0,
          cMaxReuseTimes: 0,
          hMaxRequestTimes: '600-900',
          hMaxReusableSecs: '1800-3000'
        },
        downloadSettings: {
          address: downHost,
          port: 443,
          network: 'xhttp',
          security: 'tls',
          tlsSettings: {
            serverName: XHTTP_DOWN_DOMAIN,
            alpn: ['h2', 'http/1.1'],
            fingerprint: 'chrome'
          },
          xhttpSettings: {
            path: XHTTP_PATH_VLESS,
            host: XHTTP_DOWN_DOMAIN,
            mode: 'auto'
          }
        }
      };
      xhExtraParam = `&extra=${encodeURIComponent(JSON.stringify(extraObj))}`;
    }

    if (!DISABLE_ARGO && currentHost) {
      // A. VLESS-xhttp
      list.push(`vless://${UUID}@${preferHost}:443?encryption=none&security=tls&type=xhttp&host=${currentHost}&path=${encodeURIComponent(XHTTP_PATH_VLESS)}&mode=packet-up&sni=${currentHost}${xhExtraParam}#${encodeURIComponent(name + '-VLESS-xhttp')}`);
      // B. VLESS-WS
      list.push(`vless://${UUID}@${preferHost}:443?encryption=none&security=tls&type=ws&host=${currentHost}&path=${encodeURIComponent(WS_PATH_VLESS)}&sni=${currentHost}#${encodeURIComponent(name + '-VLESS-WS')}`);
      // C. VMess-WS
      const vmessConf = {
        v: '2',
        ps: `${name}-VMess-WS`,
        add: preferHost,
        port: '443',
        id: UUID,
        aid: '0',
        scy: 'auto',
        net: 'ws',
        type: 'none',
        host: currentHost,
        path: WS_PATH_VMESS,
        tls: 'tls',
        sni: currentHost
      };
      list.push(`vmess://${Buffer.from(JSON.stringify(vmessConf)).toString('base64')}`);
      // D. Trojan-WS
      list.push(`trojan://${TROJAN_PASS}@${preferHost}:443?security=tls&type=ws&host=${currentHost}&path=${encodeURIComponent(WS_PATH_TROJAN)}&sni=${currentHost}#${encodeURIComponent(name + '-Trojan-WS')}`);
    }

    // E. 直连 Reality
    if (REALITY_PORT && global.REALITY_PUB_KEY && formattedIp) {
      const sidParam = global.REALITY_SHORT_ID ? `&sid=${global.REALITY_SHORT_ID}` : '';
      list.push(`vless://${UUID}@${formattedIp}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${realityDomainFinal}&fp=chrome&pbk=${global.REALITY_PUB_KEY}${sidParam}&type=tcp#${encodeURIComponent(name + '-Reality')}`);
    }

    // F. 直连 Shadowsocks 2022
    if (SS_PORT && formattedIp) {
      const uInfo = Buffer.from(`2022-blake3-aes-128-gcm:${SS_PASS}`).toString('base64url');
      list.push(`ss://${uInfo}@${formattedIp}:${SS_PORT}#${encodeURIComponent(name + '-SS2022')}`);
    }

    // G. 直连 Socks5
    if (S5_PORT && formattedIp) {
      const s5Info = Buffer.from(`${S5_USER}:${S5_PASS}`).toString('base64url');
      list.push(`socks://${s5Info}@${formattedIp}:${S5_PORT}#${encodeURIComponent(name + '-Socks5')}`);
    }

    if (list.length > 0) {
      const b64 = Buffer.from(list.join('\n')).toString('base64');
      global.SUB_CONTENT = b64;
      try {
        secureWriteText(SUB_FILE, b64);
      } catch {}
      return { b64, list };
    }
    return { b64: '', list: [] };
  }

  // 8. 优选域名选择与初始订阅构建 (直连节点优先就绪，隧道就绪后再刷新 Argo 节点)
  const preferHost = PRESET_CF_PREFER_HOST || process.env.CF_PREFER_HOST || CF_PREFER_HOST_CANDIDATES[0];
  buildSubscription(preferHost, currentArgoHost);

  // 9. 启动 Cloudflare Tunnel
  if (!DISABLE_ARGO) {
    try {
      const cfBin = await prepareCloudflared();
      if (ARGO_DOMAIN && ARGO_AUTH) {
        console.log(`[Argo] 启动固定隧道: ${ARGO_DOMAIN}...`);
        const cfArgs = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate'];
        if (ARGO_PROTOCOL) cfArgs.push('--protocol', ARGO_PROTOCOL);
        cfArgs.push('run');

        let fixedNotified = false;
        superviseProcess('Cloudflared-Fixed', () => {
          const p = spawn(cfBin, cfArgs, {
            argv0: os.platform() !== 'win32' ? 'node /app/bridge.js' : undefined,
            env: getSafeChildEnv({ TUNNEL_TOKEN: ARGO_AUTH }),
            stdio: ['ignore', 'ignore', 'pipe']
          });
          p.stderr.on('data', (d) => {
            const line = d.toString();
            if (/Registered tunnel connection/i.test(line)) {
              if (!fixedNotified) {
                fixedNotified = true;
                console.log('[Argo] 固定隧道已建立连接 (Registered tunnel connection)');
                onTunnelReady(ARGO_DOMAIN);
              }
            }
          });
          p.on('exit', () => { fixedNotified = false; });
          return p;
        });
      } else {
        console.log('[Argo] 启动临时隧道 (Quick Tunnel)...');
        const cfArgs = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate'];
        if (ARGO_PROTOCOL) cfArgs.push('--protocol', ARGO_PROTOCOL);
        cfArgs.push('--url', `http://127.0.0.1:${ARGO_PORT}`);

        superviseProcess('Cloudflared-Quick', () => {
          const p = spawn(cfBin, cfArgs, {
            argv0: os.platform() !== 'win32' ? 'node /app/bridge.js' : undefined,
            env: getSafeChildEnv(),
            stdio: ['ignore', 'ignore', 'pipe']
          });
          p.stderr.on('data', (d) => {
            const line = d.toString();
            const match = line.match(/https:\/\/(?!api\.)([a-zA-Z0-9-]+\.trycloudflare\.com)/i);
            if (match && match[1]) {
              const newHost = match[1];
              if (newHost !== currentArgoHost) {
                currentArgoHost = newHost;
                console.log(`[Argo] 临时域名已分配: https://${newHost}`);
                onTunnelReady(newHost);
              }
            }
          });
          return p;
        });
      }
    } catch (err) {
      console.error(`[Argo] 隧道启动异常: ${err.message}`);
      console.warn('[Argo] Cloudflare 隧道未能启动，将仅提供直连协议订阅');
      onTunnelReady('');
    }
  } else {
    console.log('[Argo] 隧道已被禁用 (DISABLE_ARGO=true)，仅运行直连与本地分流服务');
    onTunnelReady('');
  }

  // 10. 启动 Komari 探针 (可选)
  if (KOMARI_DOMAIN && KOMARI_TOKEN) {
    try {
      const kmBin = await prepareKomariAgent();
      if (kmBin) {
        setupContainerUptime();
        let kmEndpoint = KOMARI_DOMAIN.trim();
        if (!/^https?:\/\//i.test(kmEndpoint)) kmEndpoint = `https://${kmEndpoint}`;
        const kmArgs = ['--disable-web-ssh', '--disable-auto-update', '-e', kmEndpoint];
        superviseProcess('Komari-Agent', () => {
          return spawn(kmBin, kmArgs, {
            argv0: os.platform() !== 'win32' ? 'node /app/metrics.js' : undefined,
            stdio: 'ignore',
            env: getSafeChildEnv({ AGENT_ENDPOINT: kmEndpoint, AGENT_TOKEN: KOMARI_TOKEN })
          });
        });
        console.log('[Komari] 监控探针已启动 (已禁用远程 Web SSH 与自动更新)');
      }
    } catch (err) {
      console.warn(`[Komari] 启动异常: ${err.message}`);
    }
  }

  function onTunnelReady(host) {
    currentArgoHost = host;
    const { list } = buildSubscription(preferHost, host);
    printInfo(host, list);
    sendTelegramNotice(host, list);
  }

  function printInfo(host, list) {
    const showLog = (PRESET_SHOW_LOG || process.env.SHOW_LOG || 'true').toLowerCase() !== 'false';
    if (!showLog) return;

    const subTokenQuery = SUB_TOKEN ? `?token=${encodeURIComponent(SUB_TOKEN)}` : '';
    const primarySubUrl = (!DISABLE_ARGO && host)
      ? `https://${host}/${SUB_PATH}${subTokenQuery}`
      : `http://${PUBLIC_IP || '127.0.0.1'}:${INBOUND_PORT}/${SUB_PATH}${subTokenQuery}`;

    console.log('\n============================================================');
    console.log(`🚀 Xray 多功能综合穿透代理服务已就绪`);
    console.log(`📌 节点标识: ${NODE_NAME} (地区: ${geoCountry})`);
    console.log(`🔗 外部订阅: ${primarySubUrl}`);
    if (!DISABLE_ARGO && host) console.log(`🛡️ Argo 域名: ${host}`);
    console.log('---------------- 节点订阅明细 ----------------');
    for (const link of list) {
      console.log(link);
    }
    console.log('============================================================\n');

    const clearMin = parseInt(PRESET_LOG_CLEAR_MINUTES || process.env.LOG_CLEAR_MINUTES || '2', 10);
    if (clearMin > 0) {
      setTimeout(() => {
        try {
          if (process.stdout.isTTY) {
            console.clear();
            console.log('[安全自洁] 控制台敏感节点信息已自动清空。');
          }
        } catch {}
      }, clearMin * 60 * 1000).unref();
    }
  }

  function sendTelegramNotice(host, list) {
    const token = (PRESET_TG_BOT_TOKEN || process.env.TG_BOT_TOKEN || '').trim();
    const chatId = (PRESET_TG_CHAT_ID || process.env.TG_CHAT_ID || '').trim();
    if (!token || !chatId) return;

    const subTokenQuery = SUB_TOKEN ? `?token=${encodeURIComponent(SUB_TOKEN)}` : '';
    const primarySubUrl = (!DISABLE_ARGO && host)
      ? `https://${host}/${SUB_PATH}${subTokenQuery}`
      : `http://${PUBLIC_IP || '127.0.0.1'}:${INBOUND_PORT}/${SUB_PATH}${subTokenQuery}`;

    let text = `🎉 *Xray 节点部署成功通知*\n` +
      `*节点*: \`${(NODE_NAME || 'xray').replace(/`/g, '')}\`\n`;
    if (!DISABLE_ARGO && host) {
      text += `*域名*: \`${host}\`\n`;
    }
    text += `*订阅*: \`${primarySubUrl}\``;

    const payload = JSON.stringify({
      chat_id: chatId,
      text,
      parse_mode: 'Markdown'
    });

    const req = https.request({
      hostname: 'api.telegram.org',
      path: `/bot${token}/sendMessage`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      },
      timeout: 5000
    });
    req.on('timeout', () => req.destroy());
    req.on('error', () => {});
    req.write(payload);
    req.end();
  }
}

main().catch(err => {
  console.error(`[致命错误] 服务启动异常中断: ${err && err.stack ? err.stack : err}`);
  process.exitCode = 1;
  gracefulExit('ERROR');
});
