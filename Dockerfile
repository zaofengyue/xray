FROM node:22-alpine

ARG TARGETARCH

WORKDIR /app

# 1. 安装基础工具（含 unzip, tar, curl, ca-certificates, gcompat, libc6-compat, tini）
RUN apk add --no-cache curl unzip tar openssl bash ca-certificates jq gcompat libc6-compat tini

# 2. 预置多架构 Xray、cloudflared 与 komari-agent 二进制至 /opt/xray-core
RUN set -eux; \
    mkdir -p /opt/xray-core /usr/local/bin; \
    touch /.komari-agent-container; \
    case "${TARGETARCH}" in \
      amd64) \
        XRAY_ARCH="64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
      arm64) \
        XRAY_ARCH="arm64-v8a"; CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;; \
      *) \
        XRAY_ARCH="64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
    esac; \
    # 下载 Xray 官方发布包与校验和文件，核验 SHA256 完整性
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -o /tmp/xray.zip; \
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip.dgst" -o /tmp/xray.zip.dgst; \
    EXPECTED_SHA="$(grep -iE '^SHA2?-256[[:space:]]*=' /tmp/xray.zip.dgst | awk -F'=' '{print $2}' | tr -d ' \r\n')"; \
    if [ -n "$EXPECTED_SHA" ]; then \
        echo "${EXPECTED_SHA}  /tmp/xray.zip" | sha256sum -c -; \
    else \
        echo "Error: Failed to obtain SHA256 checksum for Xray-core" >&2; exit 1; \
    fi; \
    unzip -q /tmp/xray.zip -d /tmp/xray_ext; \
    mv /tmp/xray_ext/xray /opt/xray-core/worker; \
    if [ -f /tmp/xray_ext/geoip.dat ]; then mv /tmp/xray_ext/geoip.dat /opt/xray-core/; fi; \
    if [ -f /tmp/xray_ext/geosite.dat ]; then mv /tmp/xray_ext/geosite.dat /opt/xray-core/; fi; \
    rm -rf /tmp/xray.zip /tmp/xray.zip.dgst /tmp/xray_ext; \
    chmod +x /opt/xray-core/worker; \
    # 下载 cloudflared 桥接组件
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" -o /opt/xray-core/bridge; \
    chmod +x /opt/xray-core/bridge; \
    # 下载 komari-agent 监控探针
    curl -fsSL "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${KM_ARCH}" -o /opt/xray-core/metrics || true; \
    [ -f /opt/xray-core/metrics ] && chmod +x /opt/xray-core/metrics || true; \
    # 建立系统伪装软链接
    ln -sf /opt/xray-core/worker /usr/local/bin/worker; \
    ln -sf /opt/xray-core/worker /usr/local/bin/xray; \
    ln -sf /opt/xray-core/bridge /usr/local/bin/bridge; \
    ln -sf /opt/xray-core/bridge /usr/local/bin/cloudflared; \
    [ -f /opt/xray-core/metrics ] && ln -sf /opt/xray-core/metrics /usr/local/bin/metrics || true; \
    chmod -R 755 /usr/local/bin; \
    chmod -R 777 /opt/xray-core

ENV XRAY_LOCATION_ASSET=/opt/xray-core

COPY nodejs/ ./
RUN chmod -R 777 /app

# 动态轻量化健康检查（避免周期性启动 Node 引擎产生的内存与 CPU 抖动）
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-3000}/" >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "index.js"]
