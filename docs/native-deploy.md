# 原生部署（不使用 Docker）

FLVX 现在可以完全脱离 Docker 运行：**一个静态二进制**同时提供面板界面、管理 API 与节点通道，
不需要 nginx，也不需要任何容器。

## 为什么可以

| 组件 | 原生实现 |
|---|---|
| 面板后端 + 前端 | `paneld` 单文件二进制，前端 `dist` 通过 `go:embed` 编进二进制 |
| 数据库 | SQLite 单文件（默认）或 PostgreSQL |
| 节点 agent | 上游 `gost-{arch}` 二进制 + systemd（与 Docker 方案完全一致） |
| 面板「一键升级」 | 由 `deploy/native/upgrade-paneld.sh` 取代（Docker 方案里唯一依赖 docker 的功能） |

代码里唯一调用外部命令的地方是面板自升级用的 `docker`，没有 docker 时该功能只显示"不可用"，不影响其它功能。

## 运行形态

```
paneld（systemd: flvx-paneld）
├─ 面板端口 :6366   /（内嵌 SPA）+ /api/v1/ + /system-info(type=0)
└─ 节点端口 :6365   /system-info(type=1) + /flow/{test,upload,config}   面板页面与 API 在这里都是 404
```

端口、路径、HTTPS 全部在**面板设置页**里改（存 SQLite 的 `vite_config`）：

| 设置项 | 键 | 说明 |
|---|---|---|
| 面板端口 | `panel_port` | UI + API 的监听端口 |
| 节点连接端口 | `panel_agent_port` | agent 专用；节点安装命令里的地址要写 `服务器IP:这个端口` |
| 面板路径 | `panel_path` | `/` 或 `/kunta`；**运行期可改，无需重新构建前端** |
| 隐藏根路径 | `panel_hide_root` | 路径非 `/` 时，`/` 返回 404（开）或 302 跳到面板路径（关） |
| 启用 HTTPS | `panel_tls_enable` | 面板端口本身改用 HTTPS，不额外占用 443 |
| 证书 / 私钥路径 | `panel_cert_file` / `panel_key_file` | 服务器绝对路径；证书按 mtime 热加载 |

保存后约 **3 秒**自动重绑监听（前端会弹出新地址提示）。新配置绑定失败会自动回退旧配置；
证书文件不可用时自动按 HTTP 启动，不会把面板锁在门外。

## 目录布局

```
/usr/local/bin/flvx-paneld        二进制（内嵌前端）
/usr/local/bin/flvx-paneld.prev   上一版，回滚用
/etc/flvx/paneld.env              JWT_SECRET、DB 路径、首次启动的默认端口
/etc/flvx/certs/                  证书目录（放 fullchain.pem / privkey.pem）
/var/lib/flvx/gost.db             SQLite 数据库（systemd StateDirectory）
/etc/systemd/system/flvx-paneld.service
```

## 安装 / 升级

**推荐直接用根目录的一键脚本 `install.sh`**（建用户、生成 JWT_SECRET、原子替换、装 systemd、启动/回滚都在里面）：

```bash
# 本机构建
cd go-backend && ./scripts/build-panel.sh
# 上传并安装（重复执行即升级）
scp bin/paneld root@服务器:/root/flvx-paneld
scp install.sh  root@服务器:/root/
ssh root@服务器 'sudo bash /root/install.sh /root/flvx-paneld'
```

下面是最小化手工步骤（不使用脚本时参考）：

构建（在源码目录）：

```bash
cd go-backend
GOOS=linux GOARCH=amd64 ./scripts/build-panel.sh      # 自动先构建前端并 embed 进二进制
# 产物：go-backend/bin/paneld
```

部署：

```bash
scp go-backend/bin/paneld root@服务器:/root/flvx-paneld
scp deploy/native/flvx-paneld.service deploy/native/install-paneld.sh \
    deploy/native/upgrade-paneld.sh root@服务器:/root/flvx-native/
ssh root@服务器 'bash /root/flvx-native/install-paneld.sh /root/flvx-paneld'
```

- 首次执行 = 安装（建用户、生成 `JWT_SECRET`、装 unit、启动）
- 再次执行 = 原地升级（只换二进制并重启，数据库与设置不动）
- 只想换版本：`upgrade-paneld.sh /root/flvx-paneld`（带健康检查 + 失败自动回滚）

## 常用运维

```bash
systemctl status flvx-paneld
journalctl -u flvx-paneld -f                 # 面板日志（含每个请求）
systemctl restart flvx-paneld                # 手动重启（改 .env 后需要）
kill -HUP $(systemctl show -p MainPID --value flvx-paneld)   # 只按数据库配置重绑监听
cp /usr/local/bin/flvx-paneld.prev /usr/local/bin/flvx-paneld && systemctl restart flvx-paneld  # 回滚
```

备份只需要一个文件：`/var/lib/flvx/gost.db`（SQLite WAL 模式，建议 `sqlite3 gost.db ".backup"` 或停服务后拷贝）。

## 加节点

1. 面板 →「网站配置 → 面板后端地址」填 `服务器IP:节点端口`（例如 `192.168.10.247:6365`）
2. 「节点 → 新增」填服务器 IP 与端口范围
3. 点「安装」复制命令，到节点机执行（脚本会下载 `gost-{arch}` 并装成 `flux_agent.service`）
4. 节点状态变为在线即完成

节点端口只需要放行这 4 个路径（其它一律 404）：`/system-info`、`/flow/test`、`/flow/upload`、`/flow/config`。
但**没有身份认证之外的防护**——别把节点端口暴露到不可信网络；如需公网接入，请配合防火墙白名单。

## 与 Docker 方案的差异

| | Docker 方案 | 原生方案 |
|---|---|---|
| 活动部件 | docker + 2~3 个容器 | 1 个进程 |
| 内存占用 | 约 200MB+（含容器/nginx） | 约 40MB |
| 面板一键升级 | 面板内点击 | `upgrade-paneld.sh` |
| 面板端口/路径/TLS | 需要生成 nginx 配置并重建容器 | 设置页保存后 3 秒生效 |
| 升级粒度 | 拉镜像 | 换二进制（保留 `.prev` 可回滚） |

## 已知限制

- 节点 agent 通道目前是明文 HTTP/WS（内网场景）；如果要用 `wss`，需要给节点端口也配 TLS（当前只给面板端口做了同端口 HTTPS）。
- nftables 转发模式需要面板能 SSH 到节点，并且节点上可执行 `nft`（root 或 `sudo -n nft`）。
- 面板自升级（把面板更新到新版本）在原生方案下线，改由脚本完成。
