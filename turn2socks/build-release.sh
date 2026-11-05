#!/usr/bin/env bash
# 构建 turn2socks 的 linux/amd64 与 linux/arm64 发布文件，并生成安装脚本期望格式的 .sha256
# 用法: ./build-release.sh   (产物位于 ./dist/，上传到 Release 时请把 .sha256 一并上传)
set -euo pipefail
cd "$(dirname "$0")"
go vet ./... && go test -count=1 ./...
rm -rf dist && mkdir dist
for arch in amd64 arm64; do
  out="turn2socks-linux-${arch}"
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -ldflags="-s -w" -trimpath -o "dist/${out}" .
  (cd dist && sha256sum "${out}" > "${out}.sha256")
  echo "built dist/${out}  $(cut -c1-16 "dist/${out}.sha256")..."
done
