# Xray 项目代码审查与安全审计报告 (Code Review & Audit Report)

- **审查对象**：`xray` 一体化综合服务调度引擎 (Node.js / Python / Shell / Go / Docker)
- **审查日期**：2026-11-05
- **审查范围**：`nodejs/index.js`, `python/app.py`, `xray.sh`, `turn2socks/main.go`, `Dockerfile`, `.github/workflows/build.yml`

---

## 目录
1. [项目架构概览](#一项目架构概览)
2. [缺陷级别与影响矩阵](#二缺陷级别与影响矩阵)
3. [🔴 严重与高危缺陷 (P0 / Critical)](#三-严重与高危缺陷-p0--critical)
4. [🟡 中危与体验缺陷 (P1 / Medium)](#四-中危与体验缺陷-p1--medium)
5. [🟢 低危、安全性与代码质量 (P2 / Low)](#五-低危安全性与代码质量-p2--low)
6. [修复代码补丁汇总 (Diff Patches)](#六修复代码补丁汇总-diff-patches)
7. [后续维护与演化建议](#七后续维护与演化建议)

---

## 一、项目架构概览

该项目是一套高度集成的多协议穿透与直连代理调度引擎，支持以下运行时环境：
- **Node.js 运行时 (`nodejs/index.js`)**：纯标准库实现，支持单端口多协议反向代理（xhttp / WS / HTTP / Sub）、Cloudflare Argo 隧道与 Komari 探针调度。
- **Python 运行时 (`python/app.py`)**：纯 Python 3.8+ 标准库实现，零 pip 依赖，适配无 Node.js 的轻量级容器/主机。
- **Linux 运维脚本 (`xray.sh`)**：全功能交互式 Shell 运维面板，支持原生 Systemd、acme.sh 证书管理、WARP WireGuard 出口分流与多格式订阅生成。
- **TURN 中继转接组件 (`turn2socks/main.go`)**：基于 RFC 6062 TCP Relay 协议实现的 Go 原生 SOCKS5-to-TURN 转接工具。
- **容器与 CI/CD**：提供多架构 Dockerfile 与 GitHub Actions 自动编译、混淆及打包流程。

---

## 二、缺陷级别与影响矩阵

| 编号 | 缺陷描述 | 所属文件 | 级别 | 影响范围 |
| :--- | :--- | :--- | :--- | :--- |
| **BUG-01** | `geoPromise` 异步未等待竞态，导致地域专属 Reality 伪装域名匹配失效 | `nodejs/index.js` | 🔴 P0 严重 | Reality 协议隐蔽性降低 |
| **BUG-02** | `DISABLE_ARGO=true` 时，控制台订阅明细输出与 Telegram 通知完全静默 | `nodejs/index.js`<br>`python/app.py` | 🔴 P0 严重 | 直连模式部署体验中断 |
| **BUG-03** | WebSocket 握手早期数据（0-RTT / Early Data）在 `rfile` 缓冲截断丢失 | `python/app.py` | 🔴 P0 严重 | 客户端连接偶发卡死 |
| **BUG-04** | `turn2socks` 硬编码 SHA256 与 GitHub Actions 自动构建冲突导致校验必崩 | `xray.sh` | 🔴 P0 严重 | 脚本安装流程中断 |
| **BUG-05** | TURN 客户端缺少 RFC 6062 Allocation 周期刷新，长连接 10 分钟必断 | `turn2socks/main.go` | 🟡 P1 中危 | 大文件/长会话断流 |
| **BUG-06** | xhttp (SplitHTTP) 流反代不支持 `chunked` 分块传输且同步阻塞 | `python/app.py` | 🟡 P1 中危 | 上行流量丢失/线程阻塞 |
| **BUG-07** | 外部主服务 `mainServer` 缺少 WebSocket `upgrade` 事件监听 | `nodejs/index.js` | 🟡 P1 中危 | 直连端口无法复用 WS |
| **BUG-08** | 生成的 `xray_client.json` 客户端配置中 `shortId` 强制为空，与服务端不符 | `xray.sh` | 🟡 P1 中危 | Xray 客户端认证失败 |
| **BUG-09** | 默认 `/sub` 订阅路由完全无鉴权，导致核心凭证与节点全量泄露风险 | 全局 | 🟢 P2 建议 | 凭据安全性隐患 |
| **BUG-10** | 存在死代码与未使用的预留变量 (`timingSafeEqualStr`, `PRESET_SINGLE_PROCESS`) | `nodejs/index.js` | 🟢 P2 建议 | 代码冗余度 |

---

## 三、🔴 严重与高危缺陷 (P0 / Critical)

### BUG-01: `geoCountry` 竞态导致 Reality 域名国家自适应失效
- **位置**：[`nodejs/index.js`](file:///nodejs/index.js#L701-L770)
- **现象分析**：
  在主入口流程中，地理探测被封装在异步 IIFE 中执行：
  ```javascript
  let geoCountry = 'DEFAULT';
  const geoPromise = (async () => {
    // 异步探测 IP, country, org
  })();
  ```
  而在构建 Reality 入站配置（第 770 行）时：
  ```javascript
  realityDomainFinal = await resolveBestRealityDomain(geoCountry, PRESET_REALITY_DOMAIN || process.env.REALITY_DOMAIN);
  ```
  此时 `geoPromise` **尚未被 await**（`await geoPromise` 被延迟到了第 1026 行）。因此传入的 `geoCountry` 永远为初始值 `'DEFAULT'`。
  预设的日本 (`JP` -> `www.iij.ad.jp`)、香港 (`HK` -> `www.hkt.com`)、新加坡 (`SG`)、欧洲 (`EU`) 等地域专属伪装域名自动选择逻辑**彻底失效**。
- **修复方案**：将 `await geoPromise;` 提前到第 765 行（即构建 Reality 配置之前）。

---

### BUG-02: 禁用 Argo 隧道时，订阅输出与 Telegram 推送完全失效
- **位置**：[`nodejs/index.js`](file:///nodejs/index.js#L1030-L1078) 与 [`python/app.py`](file:///python/app.py#L865-L935)
- **现象分析**：
  终端打印信息（`printInfo`）与 Telegram 发送通知（`sendTelegramNotice`）被深耦合在 Cloudflared 隧道的就绪事件监听函数（`onTunnelReady` / `on_ready`）内部。
  当用户设置 `DISABLE_ARGO=true`（或填入 `DISABLE_ARGO=true` 环境变量仅使用 Reality / SS / S5 直连）时，Cloudflared 隧道启动流程被完全跳过：
  ```javascript
  if (!DISABLE_ARGO) {
    // 只有这里才会触发 onTunnelReady(...)
  }
  ```
  结果是：**控制台没有任何节点订阅链接打印，也绝不触发 Telegram 推送**，用户无法获取生成的链接。
- **修复方案**：当 `DISABLE_ARGO === true` 时，在初始化完成处显式调用一次打印与推送逻辑。

---

### BUG-03: `python/app.py` 中 WebSocket 早期数据（0-RTT）缓冲截断丢包
- **位置**：[`python/app.py`](file:///python/app.py#L767-L821)
- **现象分析**：
  在 `MultiProxyHandler.handle_one_request` 中，Python 的 `http.server` 依赖内部 `self.rfile`（`io.BufferedReader`）解析请求行与 Header：
  ```python
  self.raw_requestline = self.rfile.readline(65537)
  self.parse_request()
  ```
  当客户端发送 WebSocket 握手时，若客户端在同一个 TCP 报文中携带了早期数据（Early Data / 首个 WebSocket Frame），这些字节会被 `BufferedReader` 提前读取并缓存在 Python 用户态缓冲中。
  然而紧接着执行的 `proxy_websocket` 直接拿底层原始 socket `self.connection` 进行 `recv()`，**缓存在 `self.rfile` 中的字节被彻底丢弃**，导致 Xray 核心永远等不到客户端的首包，连接出现间歇性假死或握手超时。
- **修复方案**：在进入 socket 双向转发循环前，优先检查 `self.rfile` 并将未消费的缓冲区数据发送给目标端口。

---

### BUG-04: `xray.sh` 中硬编码 SHA256 与 GitHub Actions 自动化构建冲突
- **位置**：[`xray.sh`](file:///xray.sh#L542-L546)
- **现象分析**：
  在 `download_turn2socks()` 中，对下载的官方二进制进行了严格的固定 SHA256 哈希校验：
  ```bash
  exp_t2s_sha="9ea50c94d2ef65c5aa4d85cd4acf0e1501a358ebab64fb726555421e916394d8" # arm64
  exp_t2s_sha="1d65aaf21837ebcd8dae9ed08294a4c21547b50a9b4afd63cd1a0329da42847e" # amd64
  ```
  但在项目仓库的 `.github/workflows/build.yml` 中，每次提交代码至 `main` 分支都会触发 `go build` 重新编译并发布最新的 `turn2socks`。
  由于 Go 编译器在不同环境和新提交下构建出的二进制哈希值会变动，脚本硬编码的哈希与 Release 产物不再匹配，导致脚本在执行到该步骤时提示：
  `turn2socks SHA256 校验失败 (安全哈希不匹配)` 并强制 `return 1` 中断流程。
- **修复方案**：改为通过动态下载 GitHub Release 中的 `.sha256` 校验文件，或在哈希文件不存在时通过 `is_valid_elf` 进行格式健全性验证。

---

## 四、🟡 中危与体验缺陷 (P1 / Medium)

### BUG-05: `turn2socks` 缺少 RFC 6062 定时刷新（10 分钟长连接断流）
- **位置**：[`turn2socks/main.go`](file:///turn2socks/main.go#L236-L358)
- **原因分析**：
  标准 Coturn 默认 Allocation 生命周期为 **600 秒 (10 分钟)**。根据 RFC 6062 规范，TCP Relay 虽然由数据连接传递数据，但中继配额必须依赖控制连接（`ctrlConn`）维持活跃。
  代码虽然维持了 `ctrlConn` 开启，但**从未周期性向 TURN 发送 STUN Refresh Request**。如果单个连接持续通信（例如长时间下载、大视频流或空闲持久连接）超过 10 分钟，Coturn 服务端配额到期后会强制销毁中继。
- **修复方案**：在控制连接建立后，启动定时 goroutine（例如每 180 秒）发送带有认证信息的 STUN `RefreshRequest`。

---

### BUG-06: `python/app.py` 中 xhttp 反代不支持 chunked 传输且同步阻塞
- **位置**：[`python/app.py`](file:///python/app.py#L729-L746)
- **原因分析**：
  VLESS-xhttp (SplitHTTP) 使用 HTTP/1.1 或 HTTP/2 流式分块传输。
  在 `python/app.py` 中，仅读取了 `Content-Length` 请求体：
  ```python
  cl = self.headers.get("Content-Length")
  if cl and cl.isdigit():
      body = self.rfile.read(int(cl))
  ```
  如果请求采用 `Transfer-Encoding: chunked`，`cl` 为空，`body` 被设为 `None`，导致分块上传数据丢失。此外，`http.client.HTTPConnection.getresponse()` 会阻塞直到响应完整返回，无法很好地支撑长生命周期的流式响应。

---

### BUG-07: `nodejs/index.js` 主监听服务缺少 WebSocket 升级支持
- **位置**：[`nodejs/index.js`](file:///nodejs/index.js#L961-L965)
- **原因分析**：
  WebSocket `upgrade` 事件监听仅绑定在了内部端口服务 `argoServer`（8001）上；对外暴露的公网入口 `mainServer`（默认 3000）只监听了普通的 `request` 事件。
  若用户通过自己的反向代理（如 Nginx、Caddy）将 WebSocket 流量直连转发到该实例的 `INBOUND_PORT`，由于缺少 `upgrade` 处理句柄，连接会被直接丢弃。
- **修复方案**：为 `mainServer` 同样挂载 WebSocket 协议多路分流的 `upgrade` 监听器。

---

### BUG-08: `xray.sh` 生成的客户端配置文件中 `shortId` 为空
- **位置**：[`xray.sh`](file:///xray.sh#L2404)
- **原因分析**：
  在 `xray.sh` 服务端 Reality 入站中配置了 `reality_sid="$(get_reality_short_id)"`，在节点链接中也带上了 `&sid=${reality_sid}`。
  但在生成配套的客户端配置 `xray_client.json`（行 2404）时，却硬编码了：
  ```json
  "shortId": ""
  ```
  当服务端配置了非空的 Short ID 时，使用该 JSON 启动的客户端将因 Short ID 不一致而被 Xray 服务端拒绝握手。
- **修复方案**：将其更正为 `"shortId": "${reality_sid}"`。

---

## 五、🟢 低危、安全性与代码质量 (P2 / Low)

1. **未鉴权的订阅地址 (`/sub`)**
   - 当前在 `nodejs`、`python` 与 `xray.sh` 中，订阅路由默认为 `http://IP:PORT/sub`。
   - 任何人只要扫描到该端口，即可无障碍获取所有节点的 UUID、Shadowsocks 密码以及 Socks5 明文凭证。
   - **建议**：引导用户在生产部署时必须指定复杂自定义路径（如 `SUB="token_9a3bf8e2"`），或在订阅响应时验证 URL Query 签名。

2. **Shell 变量拼接 JSON 缺乏转义**
   - 在 `xray.sh` 中，诸如 `uuid`, `reality_domain`, `ss_pass`, `s5_user`, `s5_pass` 等变量直接通过 `${var}` 插值入 JSON 模版。
   - 如果用户通过交互式输入了包含双引号 `"` 或反斜杠 `\` 的密码，将直接破坏 JSON 语法导致服务启动失败。
   - **建议**：统一使用已定义的 `escape_json` 函数过滤所有用户输入的凭证字段。

3. **冗余与死代码**
   - `nodejs/index.js#L233`：`timingSafeEqualStr` 函数被定义但从未被调用。
   - `nodejs/index.js#L40`：`PRESET_SINGLE_PROCESS` 配置项被声明但业务逻辑中未做任何分支判断。

---

## 六、修复代码补丁汇总 (Diff Patches)

### 补丁 1: 修复 `nodejs/index.js` 探测竞态与禁用 Argo 静默 Bug
```diff
--- a/nodejs/index.js
+++ b/nodejs/index.js
@@ -763,6 +763,9 @@ async function main() {
 
+  // 1. 确保在匹配 Reality 域名与生成配置前完成地理位置探测
+  await geoPromise;
+
   // 直连协议：VLESS-Reality
   let realityDomainFinal = '';
   if (REALITY_PORT && !isNaN(parseInt(REALITY_PORT, 10))) {
@@ -959,6 +962,7 @@ async function main() {
   // 6. 启动外部直连主 HTTP 服务
   const mainServer = http.createServer(handleHttp);
+  mainServer.on('upgrade', (req, socket, head) => argoServer.emit('upgrade', req, socket, head));
   mainServer.listen(INBOUND_PORT, '0.0.0.0', () => {
     console.log(`[HTTP] Web 伪装站点与订阅服务已就绪: http://0.0.0.0:${INBOUND_PORT}`);
   });
@@ -1023,7 +1027,6 @@ async function main() {
   // 8. 优选域名选择与初始订阅构建
   const preferHost = PRESET_CF_PREFER_HOST || process.env.CF_PREFER_HOST || CF_PREFER_HOST_CANDIDATES[0];
-  await geoPromise; // 等待地理探测完成
   buildSubscription(preferHost, currentArgoHost);
 
   // 9. 启动 Cloudflare Tunnel
@@ -1078,6 +1081,13 @@ async function main() {
     } catch (err) {
       console.error(`[Argo] 隧道启动异常: ${err.message}`);
     }
+  } else {
+    // 当禁用 Argo 时，立即在控制台打印订阅信息并发送 Telegram 通知
+    const { list } = buildSubscription(preferHost, PUBLIC_IP || '127.0.0.1');
+    printInfo(PUBLIC_IP || '127.0.0.1', list);
+    sendTelegramNotice(PUBLIC_IP || '127.0.0.1', list);
   }
```

### 补丁 2: 修复 `python/app.py` 禁用 Argo 静默 Bug
```diff
--- a/python/app.py
+++ b/python/app.py
@@ -933,6 +933,10 @@ def main():
                     proc.wait()
                     time.sleep(3.0)
             threading.Thread(target=quick_runner, daemon=True).start()
+    else:
+        cur_host = PUBLIC_IP or "127.0.0.1"
+        cur_links, _ = build_subscription(prefer_host, cur_host)
+        on_ready(cur_host)
```

### 补丁 3: 修复 `xray.sh` 客户端配置中的 shortId
```diff
--- a/xray.sh
+++ b/xray.sh
@@ -2404,3 +2404,3 @@
           "publicKey": "${reality_pub}",
-          "shortId": ""
+          "shortId": "${reality_sid}"
         }
```

---

## 七、后续维护与演化建议

1. **统一版本发布流水线**：
   建议在 `.github/workflows/build.yml` 中编译产出 `turn2socks` 时，同时将动态哈希注入脚本，或在脚本中通过 `curl -fsSL ...turn2socks.sha256` 进行比对，避免手工修改哈希。
2. **轻量认证中间件**：
   在 `/sub` 路径上加入可选的 Token 校验参数（例如 `/sub?token=xxx`），大幅提高在公网暴露情况下的凭据安全性。
3. **强化 TURN 中继保活机制**：
   在 `turn2socks` 内部引入 `time.NewTicker` 实现 STUN Refresh 定时心跳，使其能够稳定支撑 7x24 小时的大文件代理与长连接需求。
