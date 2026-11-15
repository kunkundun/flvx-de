# FLVX · 原生部署版（flvx-de）

把 FLVX 转发面板做成**一个静态二进制**：面板界面、管理 API、节点通道全部由同一个进程提供，
**不需要 Docker、不需要 nginx、不需要容器编排**。

```
paneld（systemd）
├─ 面板端口 :6366   /（内嵌前端）+ /api/v1/ + /system-info(type=0)
└─ 节点端口 :6365   /system-info(type=1) + /flow/*     ← 面板页面和 API 在这里一律 404
└─ SQLite  /var/lib/flvx/gost.db（业务数据 + 面板自己的设置）
```

## 特性

- **单进程**：跑起来只有一个 `flvx-paneld`，约 40～60MB 内存
- **前端内嵌**：`go:embed` 把面板前端编进二进制，升级/迁移只搬一个文件
- **面板路径运行期可改**：`/` 或 `/kunta`，保存即生效，**不用重新构建前端**
- **同端口 HTTPS**：面板端口自己就能上 HTTPS，不额外占用 443；HTTP 访问会 301 到同端口；证书按文件变化热加载
- **端口/路径/证书都在设置页里改**：面板「网站配置」直接调，保存后约 3 秒重绑监听；新配置起不来会自动回退
- **节点通道独立端口**：只放行 `/system-info`、`/flow/*`，不暴露面板页面与管理 API
- 单机可跑（SQLite），也支持 PostgreSQL
- 转发能力沿用 FLVX：TCP/UDP、端口转发与隧道转发、限速限流、流量统计与套餐计费、分组权限、面板互联、nftables 转发模式等

## 一键安装

### 方式 A：脚本（仓库公开时最省事）

```bash
curl -fsSL https://raw.githubusercontent.com/kunkundun/flvx-de/main/install-panel.sh | sudo bash
```

自定义端口 / 路径：

```bash
curl -fsSL https://raw.githubusercontent.com/kunkundun/flvx-de/main/install-panel.sh \
  | sudo bash -s -- --port 8443 --path /kunta
```

> 私有仓库需要带 token：`sudo GH_TOKEN=<你的token> bash install-panel.sh`

### 方式 B：先构建，再一键装（推荐，私有仓库/离线都适用）

本机（macOS/Linux 均可，需要 Go 1.26.10+ 与 Node 22）：

```bash
git clone <本仓库> flvx-de && cd flvx-de
cd go-backend && ./scripts/build-panel.sh      # 自动：构建前端 → embed → 编译
# 产物：go-backend/bin/paneld
```

上传并安装到服务器：

```bash
scp go-backend/bin/paneld root@服务器:/root/flvx-paneld
scp install-panel.sh      root@服务器:/root/
ssh root@服务器 'sudo bash /root/install-panel.sh /root/flvx-paneld'
```

也可以把 `flvx-paneld` 和 `install-panel.sh` 放在同一目录，直接 `sudo bash install-panel.sh`。

### 方式 C：从 Release 安装

```bash
sudo FLVX_BINARY_URL=https://github.com/kunkundun/flvx-de/releases/download/<版本>/flvx-paneld-linux-amd64 \
  bash install-panel.sh
```

安装脚本做的事：建 `flvx` 系统用户 → 建目录 → 生成 `JWT_SECRET` → 原子替换二进制（保留 `.prev` 可回滚）
→ 装 systemd 单元 → 启动 → 打印访问地址。

装完会打印：

```
面板地址 : http://<IP>:6366/
节点端口 : <IP>:6365   （节点安装命令里的地址填这个）
初始账号 : admin_user / admin_user（首次登录强制改密码）
```

## 安装后三步

1. 浏览器打开面板，**改掉初始密码**
2. 「网站配置 → 面板后端地址」填 `服务器IP:6365`（节点端口）
3. 「节点 → 新增」填节点服务器 IP 与端口范围 → 复制安装命令 → 到节点机执行

节点机上会装成 `flux_agent.service`（agent 二进制从 GitHub Release 下载）。

## 面板设置（网站配置页）

| 设置项 | 说明 |
|---|---|
| 面板端口 | UI + API 的监听端口，默认 6366 |
| 节点连接端口 | agent 专用，默认 6365；只提供 `/system-info`、`/flow/*` |
| 面板路径 | `/` 或 `/kunta` 等子路径，运行期可改 |
| 隐藏根路径 | 路径非 `/` 时：开 = `/` 返回 404；关 = `/` 302 跳到面板路径 |
| 启用 HTTPS | 面板端口本身改用 HTTPS（不占 443）；HTTP 访问 301 到 https 同端口 |
| 证书 / 私钥路径 | 服务器绝对路径，建议放 `/etc/flvx/certs/`；文件更新自动热加载 |

保存后约 3 秒生效：地址变了会自动跳转提示；危险变更（隐藏根路径、开关 HTTPS）会二次确认；
新配置绑定失败（端口被占用、证书不可用）会自动回退到上一份配置，不会把面板锁在门外。

## 常用命令

```bash
systemctl status flvx-paneld            # 状态
journalctl -u flvx-paneld -f            # 日志（含每个请求）
systemctl restart flvx-paneld           # 重启（改 /etc/flvx/paneld.env 后需要）
kill -HUP $(systemctl show -p MainPID --value flvx-paneld)   # 按数据库设置重绑监听
```

升级（保留 `.prev`，健康检查失败自动回滚）：

```bash
sudo bash install-panel.sh /root/flvx-paneld-new      # 或 deploy/native/upgrade-paneld.sh
```

回滚：

```bash
sudo cp /usr/local/bin/flvx-paneld.prev /usr/local/bin/flvx-paneld && sudo systemctl restart flvx-paneld
```

卸载（保留数据库）：

```bash
sudo bash install-panel.sh --uninstall
```

## 目录布局

```
/usr/local/bin/flvx-paneld        二进制（内嵌前端）
/usr/local/bin/flvx-paneld.prev   上一版本，回滚用
/etc/flvx/paneld.env              JWT_SECRET、数据库路径、首次安装的默认端口
/etc/flvx/certs/                  证书目录
/var/lib/flvx/gost.db             SQLite 数据库
/etc/systemd/system/flvx-paneld.service
```

备份只需要一个文件：`/var/lib/flvx/gost.db`（建议 `sqlite3 gost.db ".backup 备份文件"`，或停服务后拷贝）。

## 从源码构建（开发）

```bash
# 后端 + 前端（一条命令，产物 go-backend/bin/paneld）
cd go-backend && ./scripts/build-panel.sh

# 只跑前端开发服务器（路径走 /，接口代理到后端）
cd vite-frontend && pnpm dev

# 打多架构发布包（linux/amd64 + linux/arm64 + 校验和 + 整包）
VERSION=3.0.0 ./scripts/package-release.sh
```

环境要求：**Go 1.26.10+**、**Node 22.23.4+**（pnpm 10.28.1）。后端构建使用 `CGO_ENABLED=0`，产物是静态二进制。

## 端口与网络

| 端口 | 用途 | 建议暴露范围 |
|---|---|---|
| 6366（面板端口） | 面板 UI + 管理 API | 内网 / VPN；要公网访问请上 HTTPS + 反代 + 认证 |
| 6365（节点端口） | 节点 agent 通道 | 只对节点所在网络开放；公网接入请在其前面做 TLS（agent 会自动用 `wss`） |

节点端口只接受 4 个路径，其它一律 404：`/system-info`、`/flow/test`、`/flow/upload`、`/flow/config`。
这些端点靠节点 `secret` 鉴权，但仍建议加防火墙白名单，只放行自己的节点 IP。

## 与 Docker 版 FLVX 的差异

| | Docker 版 | 本版本 |
|---|---|---|
| 运行方式 | docker + 2~3 个容器 | 1 个进程 |
| 内存 | 200MB+ | 40~60MB |
| 前端 | 独立 nginx 容器 | `go:embed` 进二进制 |
| 面板「一键升级」 | 面板内点击 | `install-panel.sh <新二进制>`（保留回滚） |
| 端口/路径/TLS | 改 compose + 重建容器 | 设置页保存，3 秒生效 |

## 已知限制

- 节点通道目前是明文 HTTP/WS（内网场景）；TLS 请在节点端口前面做
- 面板自升级（在面板里点一下把自己更新）在原生方案下线，改由 `install-panel.sh` 完成
- nftables 转发模式需要面板能 SSH 到节点，且节点上可执行 `nft`（root 或 `sudo -n nft`）
- 只支持 Linux（systemd / OpenRC 均可运行，脚本按 systemd 写；Alpine 需自行写 OpenRC 单元）

## 许可与声明

基于 FLVX（Apache-2.0）源码改造，遵循同一许可。
本项目为流量转发工具，仅供合法合规用途，请遵守所在国家或地区法律法规。
