# Xray 一体化综合服务调度引擎 (Xray-Core Universal Proxy)

基于 **XTLS/Xray-core** 与 **Cloudflare Argo 穿透** 的全协议轻量级综合代理系统。全面支持 **VLESS-Reality (Vision 原生流控)**、**VLESS-xhttp (SplitHTTP 现代流传输)**、**VLESS-WS**、**VMess-WS**、**Trojan-WS**、**Shadowsocks 2022** 与 **Socks5** 协议。

---

## 🌟 核心特性与架构亮点

1. **XTLS/Xray-core 官方原生内核**：集成最新官方多架构发行包，自带 `geoip.dat` 与 `geosite.dat` 规则资产。
2. **直连王牌：VLESS + Reality (xtls-rprx-vision)**：
   - 零证书申请，真实 TLS 1.3 偷取知名合规域名握手特征；
   - 内置**地域自适应候选池 (Geo-Aware)** 与毫秒级 TLS 1.3 探测自检，规避顶流大厂特征被 ASN 比对风控。
3. **CDN 穿透王牌：VLESS + xhttp (SplitHTTP, packet-up)**：
   - 全新 HTTP/2 & HTTP/3 双向流分块协议，彻底消除传统 WebSocket 明显的握手特征与 QoS 限速，穿透能力与稳定性远超 WS。
4. **Argo“六合一”单端口智能复用引擎**：
   - 本地仅需开放一个端口（如 `8001`），自动智能分流：
     - `GET /` ──▶ 高品质 Web 伪装主页；
     - `GET /sub` ──▶ 动态生成全协议 Base64 订阅；
     - `Upgrade: websocket` ──▶ 精准分流至 VLESS-WS、VMess-WS、Trojan-WS；
     - `POST /vless-xhttp` ──▶ 原生反代至 Xray SplitHTTP 流通道。
5. **0 阻塞秒级冷启动**：
   - 地理位置与公网 IP 采用并发异步后台探测，服务启动耗时从 12 秒压缩至 0.5 秒。
6. **多端同构支持**：
   - 完整提供 **Node.js 运行端**、**纯 Python 运行端**、**Linux 一键面板 (xray.sh)** 以及 **多架构 Docker 容器**。

---

## 🚀 部署方式

### 方式一：Docker 部署（推荐容器化部署）

支持 `linux/amd64` 与 `linux/arm64` 双架构，镜像基于 Node 22 LTS，权限加固至 `/opt/xray-core`，完美兼容各类受限 PaaS 容器云：

```bash
docker run -d \
  --name xray \
  --restart always \
  -p 3000:3000 \
  -e UUID=你的UUID \
  -e ARGO_DOMAIN=你的固定隧道域名 \
  -e ARGO_AUTH=你的固定隧道Token \
  -e REALITY_PORT=443 \
  -p 443:443 \
  ghcr.io/zaofengyue/xray:latest
```

---

### 方式二：Node.js 上传部署

适用于各类 Node.js PaaS 平台（如 Render、Koyeb、Zeabur、Railway、HuggingFace 等）或本地 VPS：

上传 `nodejs/` 目录下的文件：
```text
nodejs/
├── index.js          # 核心调度、多进程保活与单端口分流
├── package.json      # 项目元数据与启动配置
└── index.html        # 高质量 Web 伪装网页
```

启动命令：
```bash
npm start
# 或直接执行：node index.js
```

---

### 方式三：Python 部署（纯标准库，零 pip 依赖）

适用于 Python 运行时环境，无需安装 Node.js，内存占用极低：

上传 `python/` 目录下的文件：
```text
python/
├── app.py            # 纯 Python 异步服务与 Xray 调度引擎
├── requirements.txt  # 依赖占位项
└── index.html        # 伪装网页
```

启动命令：
```bash
python app.py
```

---

### 方式四：Linux 一键脚本（含完整交互管理面板）

适用于裸机 VPS，支持纯 IPv4、纯 IPv6 及双栈环境，内置自动后台守护、开机自启与快捷命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zaofengyue/xray/main/xray.sh)
```

安装完成后可随时在终端中使用以下快捷指令：
| 快捷命令 | 功能说明 |
| :--- | :--- |
| `xray` | 打开交互式综合管理面板（启停、修改端口、配置 Reality、Argo 隧道等） |
| `xray-sub` | 查看当前生成的 Base64 订阅内容与明文节点链接 |
| `xray-log` | 实时查看 Xray 核心、Argo 隧道或 Komari 探针日志 |
| `xray-del` | 一键彻底卸载清理相关服务、数据与软链接 |

---

## ⚙️ 环境变量与参数配置表

可通过环境变量或脚本配置项进行自定义，留空则自动按最优默认逻辑运行：

### 1. 基础配置
| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `UUID` | 自动生成标准 UUID | 全局用户核心鉴权凭证 |
| `PORT` | 自动分配空闲端口 (如 3000) | 对外 HTTP 伪装站与订阅端口 |
| `NAME` | 自动识别 (如 JP-IIJ) | 节点名称前缀 |
| `PUBLIC_IP` / `IP` | 自动并发探测 | 自定义入站公网 IP (NAT 机或弹性 IP 时手动指定) |
| `SUB` | `sub` | 订阅路径后缀 (即对应 `http://IP:PORT/sub`) |

### 2. Argo 隧道配置 (Cloudflare CDN 穿透)
| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `DISABLE_ARGO` | 空 (启用) | 填 `true` 彻底禁用 Argo 隧道 |
| `ARGO_DOMAIN` | 空 (启用临时隧道) | 固定隧道域名 |
| `ARGO_AUTH` | 空 | 固定隧道 Token 凭证 |
| `ARGO_PORT` | `8001` | Argo 内部多协议智能聚合分流端口 |
| `CF_PREFER_HOST` | 优选池自动测速 | Cloudflare 优选 IP 或优选域名 |

### 3. 可选直连协议配置 (填写端口即开启，留空不开启)
| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `REALITY_PORT` | 空 | VLESS-Reality (Vision) 直连端口 (推荐 443 或自定义高位) |
| `REALITY_DOMAIN` | 地域智能匹配 | Reality 伪装域名 (如 JP 默认 `www.iij.ad.jp`，自动 TLS 1.3 探活) |
| `SS_PORT` | 空 | Shadowsocks 2022 端口 (TCP/UDP, `2022-blake3-aes-128-gcm`) |
| `SS_PASS` | 自动生成 16 字节 Base64 | Shadowsocks 2022 密码 |
| `S5_PORT` | 空 | Socks5 代理端口 (TCP/UDP, 密码鉴权) |
| `S5_USER` / `S5_PASS` | UUID 截取 | Socks5 用户名与密码 |

### 4. 探针监控与推送通知
| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `KOMARI_DOMAIN` | 空 | Komari 监控服务端域名 |
| `KOMARI_TOKEN` | 空 | Komari 探针密钥 Token |
| `TG_BOT_TOKEN` | 空 | Telegram Bot Token (用于推送部署就绪通知) |
| `TG_CHAT_ID` | 空 | Telegram Chat ID |
| `SHOW_LOG` | `true` | 是否在控制台打印订阅信息 |
| `LOG_CLEAR_MINUTES` | `2` | 控制台敏感信息保留时间 (分钟)，`0` 为不清理 |
