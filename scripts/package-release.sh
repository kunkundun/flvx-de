#!/usr/bin/env bash
# 打包发布产物：多架构 paneld 二进制 + install.sh + sha256
#
#   ./scripts/package-release.sh            # 版本号取 git describe
#   VERSION=3.0.0 ./scripts/package-release.sh
#
# 产物在 dist/ 下：
#   flvx-paneld-linux-amd64 / -arm64   给 install.sh 下载用
#   flvx-de-<version>.tar.gz           整套（含 install.sh、systemd 单元、文档）
#   SHA256SUMS
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/dist"
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

echo "▶ 版本：$VERSION"
# 没有全局 pnpm 时退回 npx（CI 里用 npm i -g pnpm）
PNPM="pnpm"
command -v pnpm >/dev/null 2>&1 || PNPM="npx --yes pnpm@10"
# 本机 Node 版本不在 package.json 的 engines 里时也能构建（CI 用官方 Node 版本即可）
export npm_config_engine_strict="${npm_config_engine_strict:-false}"

echo "▶ 构建前端"
(cd "$ROOT/vite-frontend" && $PNPM install --frozen-lockfile >/dev/null && $PNPM run build >/dev/null)
rm -rf "$ROOT/go-backend/internal/webserver/dist"
mkdir -p "$ROOT/go-backend/internal/webserver/dist"
cp -R "$ROOT/vite-frontend/dist/." "$ROOT/go-backend/internal/webserver/dist/"

mkdir -p "$OUT"

for arch in amd64 arm64; do
	echo "▶ 编译 linux/$arch"
	(
		cd "$ROOT/go-backend"
		CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
			go build -trimpath \
			-ldflags="-s -w -X main.version=$VERSION" \
			-o "$OUT/flvx-paneld-linux-$arch" ./cmd/paneld
	)
done

echo "▶ 打包整套"
tar czf "$OUT/flvx-de-$VERSION.tar.gz" \
	-C "$ROOT" install.sh README.md docs/native-deploy.md deploy/native

echo "▶ 校验和"
(
	cd "$OUT"
	sha256sum flvx-paneld-linux-* flvx-de-"$VERSION".tar.gz >SHA256SUMS
	cat SHA256SUMS
)

echo
echo "✅ 完成：$OUT"
ls -lh "$OUT" | tail -6
echo
echo "发布：gh release create $VERSION dist/* --title \"$VERSION\" --notes \"FLVX 面板原生部署版\""
