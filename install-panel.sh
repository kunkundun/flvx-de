#!/usr/bin/env bash
# FLVX 面板一键安装 / 升级 / 卸载（单二进制，无 Docker）
#
#   # 1) 一键（把脚本放到服务器后执行）
#   curl -fsSL https://raw.githubusercontent.com/kunkundun/flvx-de/main/install.sh | sudo bash
#
#   # 2) 已经拿到二进制（推荐：本机构建后 scp 上来）
#   sudo bash install.sh /root/flvx-paneld
#
#   # 3) 从指定 URL 拉二进制
#   sudo FLVX_BINARY_URL=https://.../flvx-paneld-linux-amd64 bash install.sh
#
#   # 4) 卸载
#   sudo bash install.sh --uninstall
#
# 可选参数：
#   --port <n>           面板端口（默认 6366，仅首次安装生效，之后在面板设置页改）
#   --agent-port <n>     节点连接端口（默认 6365）
#   --path </xxx>        面板路径（默认 /）
#   --version <v>        下载 Release 时指定版本（默认 latest）
#   --no-start           只安装不启动
set -euo pipefail

REPO="kunkundun/flvx-de"
SERVICE_NAME="flvx-paneld"
BIN_DST="/usr/local/bin/flvx-paneld"
CONF_DIR="/etc/flvx"
ENV_FILE="$CONF_DIR/paneld.env"
DATA_DIR="/var/lib/flvx"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

PORT=6366
AGENT_PORT=6365
PANEL_PATH="/"
VERSION=""
BIN_ARG=""
DO_START=1
DO_UNINSTALL=0
TMP_DIR=""

log() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "请用 root 执行（sudo bash $0 ...）"; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" || true; }
trap cleanup EXIT

# ── 参数解析 ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
	--uninstall) DO_UNINSTALL=1 ;;
	--port)
		PORT="${2:-}"
		shift
		;;
	--agent-port)
		AGENT_PORT="${2:-}"
		shift
		;;
	--path)
		PANEL_PATH="${2:-}"
		shift
		;;
	--version)
		VERSION="${2:-}"
		shift
		;;
	--no-start) DO_START=0 ;;
	-h | --help)
		sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*) die "未知参数：$1" ;;
	*) BIN_ARG="$1" ;;
	esac
	shift
done

# ── 卸载 ─────────────────────────────────────────────────────────────
if [ "$DO_UNINSTALL" = "1" ]; then
	need_root
	log "▶ 停止并移除服务"
	systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
	rm -f "$SERVICE_FILE"
	systemctl daemon-reload

	log "▶ 删除程序与配置（保留数据库 $DATA_DIR/gost.db）"
	rm -f "$BIN_DST" "$BIN_DST.prev" "$BIN_DST.rollback"
	rm -rf "$CONF_DIR"

	log "▶ 删除用户"
	userdel flvx 2>/dev/null || true

	log ""
	log "✅ 已卸载。数据库仍在 $DATA_DIR（确认不需要可手动 rm -rf $DATA_DIR）"
	exit 0
fi

need_root

# ── 环境检查 ─────────────────────────────────────────────────────────
command -v systemctl >/dev/null 2>&1 || die "需要 systemd（Debian/Ubuntu/CentOS 等）"
command -v curl >/dev/null 2>&1 || die "需要 curl"

case "$(uname -m)" in
x86_64 | amd64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "不支持的架构：$(uname -m)（提供 amd64 / arm64 预编译包，其它架构请自行构建）" ;;
esac

TMP_DIR=$(mktemp -d)

# ── 取得二进制 ───────────────────────────────────────────────────────
fetch_binary() {
	local target="$1"

	if [ -n "$BIN_ARG" ]; then
		[ -f "$BIN_ARG" ] || die "找不到二进制：$BIN_ARG"
		log "▶ 使用本地二进制：$BIN_ARG"
		cp -f "$BIN_ARG" "$target"
		return 0
	fi

	# 脚本同目录下如果放了 flvx-paneld，优先用它
	local script_dir
	script_dir=$(cd "$(dirname "$0")" && pwd)
	if [ -f "$script_dir/flvx-paneld" ]; then
		log "▶ 使用脚本同目录的 flvx-paneld"
		cp -f "$script_dir/flvx-paneld" "$target"
		return 0
	fi

	local url="${FLVX_BINARY_URL:-}"
	if [ -z "$url" ]; then
		if [ -n "$VERSION" ]; then
			url="https://github.com/${REPO}/releases/download/${VERSION}/flvx-paneld-linux-${ARCH}"
		else
			url="https://github.com/${REPO}/releases/latest/download/flvx-paneld-linux-${ARCH}"
		fi
	fi

	log "▶ 下载二进制：$url"
	local auth=()
	[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: token ${GH_TOKEN}")

	if ! curl -fsSL "${auth[@]}" -o "$target" "$url"; then
		cat >&2 <<EOF
❌ 下载失败。

可以改用下面任一方式：
  1) 本机构建后上传：
       cd go-backend && ./scripts/build-panel.sh
       scp bin/paneld 服务器:/root/flvx-paneld
       ssh 服务器 'sudo bash install.sh /root/flvx-paneld'
  2) 走代理 / 指定地址：
       sudo FLVX_BINARY_URL=<直链> bash install.sh
  3) 私有仓库需要 token：
       sudo GH_TOKEN=<你的 token> bash install.sh
EOF
		exit 1
	fi
}

fetch_binary "$TMP_DIR/flvx-paneld"
[ -s "$TMP_DIR/flvx-paneld" ] || die "拿到的二进制是空的"
chmod 0755 "$TMP_DIR/flvx-paneld"

# ── 用户与目录 ───────────────────────────────────────────────────────
log "▶ 创建用户与目录"
id flvx >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin flvx
install -d -m 0750 -o flvx -g flvx "$DATA_DIR"
install -d -m 0750 -g flvx "$CONF_DIR"
install -d -m 0750 -g flvx "$CONF_DIR/certs"

# ── 首次安装写配置 ───────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
	log "▶ 生成配置 $ENV_FILE"
	JWT=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
	cat >"$ENV_FILE" <<EOF
# FLVX 面板配置（首次安装生成）
# 端口 / 路径 / HTTPS 之后都在面板「网站配置」里改，数据库里的值优先于这里
JWT_SECRET=$JWT
DB_TYPE=sqlite
DB_PATH=$DATA_DIR/gost.db
TZ=Asia/Shanghai

PANEL_PORT=$PORT
AGENT_PORT=$AGENT_PORT
PANEL_PATH=$PANEL_PATH
PANEL_HIDE_ROOT=1
EOF
	chmod 0640 "$ENV_FILE"
	chgrp flvx "$ENV_FILE"
else
	log "▶ 已存在配置，保留不动（升级模式）"
fi

# ── 安装二进制 ───────────────────────────────────────────────────────
log "▶ 安装二进制 → $BIN_DST"
if [ -f "$BIN_DST" ]; then
	cp -a "$BIN_DST" "${BIN_DST}.prev"
fi
install -m 0755 "$TMP_DIR/flvx-paneld" "${BIN_DST}.new"
mv -f "${BIN_DST}.new" "$BIN_DST"

# ── systemd ──────────────────────────────────────────────────────────
log "▶ 写入 systemd 单元"
cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=FLVX panel (paneld)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=flvx
Group=flvx
EnvironmentFile=/etc/flvx/paneld.env
ExecStart=/usr/local/bin/flvx-paneld
WorkingDirectory=/var/lib/flvx
StateDirectory=flvx
StateDirectoryMode=0750

Restart=always
RestartSec=3
LimitNOFILE=1048576
TimeoutStopSec=20

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/flvx
ReadOnlyPaths=/etc/flvx

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null

if [ "$DO_START" = "1" ]; then
	log "▶ 启动服务"
	systemctl restart "$SERVICE_NAME"
	sleep 3
	if ! systemctl is-active --quiet "$SERVICE_NAME"; then
		echo "❌ 服务启动失败，最近日志：" >&2
		journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
		exit 1
	fi
fi

# 面板可能已经在设置页改过端口/路径，优先用数据库里的值（python3 只是可选增强）
read_setting() { # $1=键名 $2=默认值
	local value=""
	if command -v python3 >/dev/null 2>&1; then
		value=$(python3 -c 'import sqlite3,sys
key, default = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect("file:/var/lib/flvx/gost.db?mode=ro", uri=True)
    row = con.execute("SELECT value FROM vite_config WHERE name = ?", (key,)).fetchone()
    print((row[0] if row and row[0] else default).strip())
except Exception:
    print(default)' "$1" "$2" 2>/dev/null || true)
	fi
	[ -n "$value" ] || value="$2"
	echo "$value"
}

if [ -f "$DATA_DIR/gost.db" ]; then
	PORT=$(read_setting panel_port "$PORT")
	AGENT_PORT=$(read_setting panel_agent_port "$AGENT_PORT")
	PANEL_PATH=$(read_setting panel_path "$PANEL_PATH")
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "${IP:-}" ] || IP="<服务器IP>"
URL_PATH="/"
[ -n "$PANEL_PATH" ] && [ "$PANEL_PATH" != "/" ] && URL_PATH="/$(printf '%s' "$PANEL_PATH" | sed -e 's#^/*##' -e 's#/*$##')/"

cat <<EOF

✅ FLVX 面板已就绪

   面板地址 : http://${IP}:${PORT}${URL_PATH}
   节点端口 : ${IP}:${AGENT_PORT}   （节点安装命令里的地址填这个）
   初始账号 : admin_user / admin_user（首次登录会强制改密码）
   配置文件 : ${ENV_FILE}
   数据文件 : ${DATA_DIR}/gost.db

   常用命令 :
     systemctl status ${SERVICE_NAME}
     journalctl -u ${SERVICE_NAME} -f
     sudo bash install.sh --uninstall        # 卸载（保留数据库）

   下一步 :
     1. 浏览器打开面板，改掉初始密码
     2. 「网站配置 → 面板后端地址」填 ${IP}:${AGENT_PORT}
     3. 「节点 → 新增」→ 复制安装命令到节点机执行

   想改端口 / 路径 / HTTPS：直接在面板「网站配置」里改，保存后约 3 秒生效
EOF
