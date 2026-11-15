#!/usr/bin/env bash
# FLVX 面板原生安装/更新脚本（不依赖 Docker）
#
#   ./install-paneld.sh /path/to/flvx-paneld
#
# 做的事：
#   1. 建系统用户 flvx、目录（/etc/flvx、/var/lib/flvx）
#   2. 首次安装时生成 JWT_SECRET 与 /etc/flvx/paneld.env
#   3. 原子替换二进制（保留 .prev 一份用于回滚）
#   4. 安装 systemd 单元并（重）启动
#
# 已经装过时重复执行 = 原地升级：只换二进制并重启，数据库和设置不动。
set -euo pipefail

BIN_SRC="${1:-}"
SERVICE_NAME="flvx-paneld"
BIN_DST="/usr/local/bin/flvx-paneld"
CONF_DIR="/etc/flvx"
ENV_FILE="$CONF_DIR/paneld.env"
DATA_DIR="/var/lib/flvx"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
UNIT_SRC="$(cd "$(dirname "$0")" && pwd)/flvx-paneld.service"

die() { echo "❌ $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "请用 root 执行"; }

need_root
[ -n "$BIN_SRC" ] || die "用法：$0 /path/to/flvx-paneld"
[ -f "$BIN_SRC" ] || die "找不到二进制：$BIN_SRC"

echo "▶ 用户与目录"
if ! id flvx >/dev/null 2>&1; then
	useradd --system --home-dir /var/lib/flvx --shell /usr/sbin/nologin flvx
fi
install -d -m 0750 -o flvx -g flvx "$DATA_DIR"
install -d -m 0750 -g flvx "$CONF_DIR"
install -d -m 0750 -g flvx "$CONF_DIR/certs"

echo "▶ 配置 $ENV_FILE"
if [ ! -f "$ENV_FILE" ]; then
	JWT=$(openssl rand -hex 32)
	cat >"$ENV_FILE" <<EOF
# FLVX 面板配置（首次安装生成；面板端口/路径/TLS 之后在面板设置页里改，会覆盖这里的值）
JWT_SECRET=$JWT
DB_TYPE=sqlite
DB_PATH=$DATA_DIR/gost.db
TZ=Asia/Shanghai

# 首次启动的默认值（后续以数据库 vite_config 里的 panel_* 为准）
PANEL_PORT=6366
AGENT_PORT=6365
PANEL_PATH=/
PANEL_HIDE_ROOT=1
EOF
	chmod 0640 "$ENV_FILE"
	chgrp flvx "$ENV_FILE"
	echo "  ✓ 已生成 JWT_SECRET"
else
	echo "  ✓ 已存在，保留不动"
fi

echo "▶ 安装二进制 → $BIN_DST"
if [ -f "$BIN_DST" ]; then
	cp -a "$BIN_DST" "${BIN_DST}.prev"
fi
install -m 0755 "$BIN_SRC" "${BIN_DST}.new"
mv -f "${BIN_DST}.new" "$BIN_DST"

echo "▶ systemd 单元"
[ -f "$UNIT_SRC" ] || die "缺少 unit 文件：$UNIT_SRC"
install -m 0644 "$UNIT_SRC" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"

sleep 2
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
	die "服务没起来，看：journalctl -u ${SERVICE_NAME} -n 50"
fi

PORT=$(grep -E '^PANEL_PORT=' "$ENV_FILE" | cut -d= -f2)
echo
echo "✅ 完成"
echo "   状态：$(systemctl is-active "$SERVICE_NAME")"
echo "   版本：$(grep -E '^FLUX_VERSION=' "$ENV_FILE" | cut -d= -f2 || echo 'dev')"
echo "   访问：http://<服务器IP>:${PORT:-6366}/   （路径/端口/HTTPS 可在面板设置页改）"
echo "   日志：journalctl -u ${SERVICE_NAME} -f"
echo "   回滚：cp ${BIN_DST}.prev ${BIN_DST} && systemctl restart ${SERVICE_NAME}"
