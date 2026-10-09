# Nexus Media All-in-One

把 **Nginx + nexus-media（后端）+ nexus-media-web（前端）** 整合进 **一个容器**，
对外只暴露一个端口。

- 镜像：`edwinhuish/nexus-media-allinone`
- 上游项目：[linyuan0213/nexus-media](https://github.com/linyuan0213/nexus-media)、[linyuan0213/nexus-media-web](https://github.com/linyuan0213/nexus-media-web)
- 安装步骤与格式对齐上游 [docs/installation.md](https://github.com/linyuan0213/nexus-media/blob/master/docs/installation.md)，
  与本镜像的差异见文末「与上游两容器方案的差异」

## 关于本仓库

本仓库因上游 issue
[**#184 FEATURE: DOCKER 容器编排**](https://github.com/linyuan0213/nexus-media/issues/184)
中反馈的部署问题而建立，该 issue 指出的两个问题：

1. **对外暴露端口过多** —— 上游需要同时暴露前端 `8080` 与后端 API `3000`，管理混乱；
2. **重复的 Nginx 进程** —— 前端镜像与后端镜像各自内嵌了一个 Nginx。

issue 中给出两个方案：

| 方案 | 结构 | 说明 |
|---|---|---|
| 方案 A | `nginx + frontend + backend` 三容器 | 仅 nginx 暴露端口，更贴合容器规范 |
| 方案 B | 三者合并进一个容器 | 容器数量最少 |

上游对该 issue 最终 **Close as not planned**，故在此独立维护并实现 **方案 B**：
单容器、单 Nginx、只暴露一个端口。

## 1. 架构与网络边界

```
                   宿主机
                     │  -p 8080:8080   ← 唯一对外端口
        ┌────────────▼──────────────────────────────────────────┐
        │ 容器 nexus-media                                       │
        │                                                        │
        │   Nginx :8080  ← 唯一对外服务入口                        │
        │     │                                                  │
        │     ├── /  /assets/ /static/  → /usr/share/nginx/html  │ 前端产物
        │     │                            (nexus-media-web)     │
        │     │                                                  │
        │     └── /api/ /img/ /ws /health /docs /openapi.json    │
        │            │                                           │
        │            ▼  http://127.0.0.1:3000  仅回环，不可外达     │
        │        Granian (nexus-media)  127.0.0.1:3000           │
        │                                                        │
        │   s6-overlay 统一管进程：nexus-media → nginx（有依赖顺序）│
        └────────────────────────────────────────────────────────┘
                     │
                     ▼  nexus-media-network（内网）
              Redis，以及可选的 MySQL / PostgreSQL / OCR / Chrome
              （由 docker-compose.*.yml 变体提供，同样不发布后端端口）
```

## 2. 为什么只保留一个 Nginx

上游两个镜像各自内嵌 Nginx，但它们的职责其实完全不同：

| 镜像 | 内嵌 Nginx 的作用 | 本质 |
|---|---|---|
| `nexus-media-web` | 托管前端静态产物 + 反代 API 到后端 | **静态文件打包器**（前端本身没有常驻进程） |
| `nexus-media` | 反代 API 到容器内 Granian | **API 网关** |

前端镜像里的 Nginx 没有独立业务能力，把两个 Nginx 串起来（nginx → nginx → 应用）
只会换来多一次代理跳转、多一份内存、多一个 supervisor 和一套多余的端口约定。
因此本镜像：**前端镜像只贡献 `/usr/share/nginx/html`（丢弃其 Nginx）**，
由后端镜像自带的 Nginx 统一对外服务，两份 nginx 配置合并成一份。

## 3. 镜像特点

- 单容器：Nginx + 后端 + 前端静态产物，前端不再是独立服务
- **只暴露一个端口**（容器内 8080），后端 3000 仅绑容器内回环
- 基于上游后端镜像（Debian `python:3.14-slim-trixie`），支持 amd64 / arm64
- 非 root 用户运行（`nexus:nexus`，UID 911，可用 PUID/PGID 覆盖）
- s6-overlay 进程管理，支持优雅退出
- 数据库迁移在容器启动时自动执行（`alembic upgrade head`，幂等，无需独立 migration 容器）

## 4. 端口约定（重要）

本镜像只有 **一个对外端口**：容器内 Nginx 监听 **8080**，反向代理到内部 nexus-media 服务（3000）。

| 服务 | 容器内端口 | 宿主机映射 |
|---|---|---|
| 全部服务（经 Nginx） | 8080 | `${WEB_PORT:-8080}:8080` |
| nexus-media 后端 | 3000（仅绑 `127.0.0.1`） | 不映射，容器外不可达 |
| Redis | 6379 | 不映射（仅内网） |
| MySQL（可选） | 3306 | `3306:3306` |
| PostgreSQL（可选） | 5432 | 不映射（仅内网，需从宿主机直连可自行加 `ports`） |
| nexus-chrome | 9850 / 6080 | `9850:9850` / `6080:6080` |
| nexus-verify | 9300 | `9300:9300` |

> 与上游不同：上游前端用 `8080:8080`、后端另用 `3000:8080` 暴露两个端口；
> 本镜像后端不发布端口，API 与 WebSocket 同样经 8080 转发。

## 5. Docker Compose 安装（推荐）

本仓库提供 **3 个独立 compose 文件**，按部署场景选一个：

| 文件 | 场景 | 启动 |
|---|---|---|
| `docker-compose.yml` | 前后端 + Redis（SQLite，开箱即用） | `docker compose up -d` |
| `docker-compose.mysql.yml` | MySQL 完整版（+Redis+OCR+Chrome） | `docker compose -f docker-compose.mysql.yml up -d` |
| `docker-compose.postgresql.yml` | PostgreSQL 完整版（+Redis+OCR+Chrome） | `docker compose -f docker-compose.postgresql.yml up -d` |

> ⚠️ 三个文件**互斥**（`container_name` / 端口 / 网络名相同），只选一个部署。

### 1. 修改配置

先复制环境变量模板，再按需修改：

```bash
cp .env.example .env
```

**必填项**（在 `.env` 中设置）：

```bash
# 媒体库目录（宿主机路径，必须修改为你的实际目录）
VIDEO_DIR=/mnt/media

# 唯一对外端口（宿主机端口 → 容器内 Nginx 8080）
WEB_PORT=8080
```

**密码**（MySQL / PostgreSQL 变体必填，禁止使用默认密码）：

```bash
DB_PASSWORD=你的应用密码              # 后端 + 数据库用户密码
MYSQL_ROOT_PASSWORD=你的root密码      # 仅 docker-compose.mysql.yml
VNC_PASSWORD=你的Chrome VNC密码       # 仅 Chrome 变体
```

**容器内进程身份**：填宿主机 `id -u` / `id -g`，容器写出的文件即与宿主机同属主：

```bash
PUID=1000
PGID=1000
```

宿主机侧还需保证数据目录对 `PUID:PGID` 可写（详见第 11 节）：

```bash
mkdir -p data
sudo chown -R "$(id -u):$(id -g)" data
```

### 2. 启动服务

```bash
docker compose up -d                                    # 基础版（SQLite + Redis）
docker compose -f docker-compose.mysql.yml up -d        # MySQL 完整版
docker compose -f docker-compose.postgresql.yml up -d   # PostgreSQL 完整版
```

数据库迁移由后端启动时自动执行，无需单独操作。

### 3. 访问

- 前端 Web UI：http://localhost:8080
- 后端 API：http://localhost:8080/api/
- 健康检查：http://localhost:8080/health

### 4. 常见坑：容器间网络互通

启动后，本容器会通过网桥访问 `mysql` / `postgresql` / `redis`（**服务名即主机名**）。
网桥不通、容器连不上数据库或 Redis 是这类部署最常见的失败原因，表现为后端反复重试、一直 `unhealthy`。

**先看状态与日志**

```bash
docker compose -f docker-compose.mysql.yml ps
docker compose -f docker-compose.mysql.yml logs nexus-media | tail -30
```

**验证容器间是否互通**（所有服务都应在同一自定义网桥 `nexus-media-network` 上）

```bash
docker exec nexus-media getent hosts mysql            # 应解析出容器 IP
docker network inspect nexus-media-network --format '{{range .Containers}}{{.Name}} {{end}}'
```

- `getent hosts mysql` 无输出 → DNS / 网络不通
- 能解析但连接超时 → 网络层问题

**清理残留后重启**（保留数据卷 `./data`、`./mysql_data`、`./postgres_data`）

```bash
docker compose -f docker-compose.mysql.yml down
docker network rm nexus-media-network
docker rm -f nexus-media nexus-media-mysql nexus-media-postgresql nexus-media-redis
docker compose -f docker-compose.mysql.yml up -d
```

| 现象 | 原因 | 处理 |
|---|---|---|
| `Can't connect to MySQL server ... (Connection refused)` | 连不上数据库容器 | 验证网络；确认数据库已 healthy |
| `getent hosts mysql` 无输出 | 容器不在同一网桥 / DNS 失败 | 清理网络与旧容器后重启 |
| `name already in use` | 旧容器残留 | `docker rm -f` 后重启 |
| 后端反复重试、一直 `unhealthy` | 数据库未就绪或密码不一致 | 看后端日志；核对 `.env` 密码 |
| 启动报错提示密码必填 | `.env` 未配置 | 在 `.env` 设置对应密码 |

## 6. 单独运行（不使用 compose）

```bash
docker run -d \
  --name nexus-media \
  --hostname nexus-media \
  -p 8080:8080 \
  -v "$(pwd)/data:/data" \
  -v /mnt/media:/media \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e TZ=Asia/Shanghai \
  -e REDIS__HOST=你的redis地址 \
  --restart always \
  edwinhuish/nexus-media-allinone:latest
```

> 单容器运行时不带 Redis / 数据库，需用 `REDIS__*` / `DATABASE__*` 指向外部实例；
> compose 里已经带了一个不发布端口的 Redis。

## 7. 反向代理部署

只需代理**唯一的对外端口**（宿主机 `8080`）即可，前端页面与 `/api`、`/ws` 都在其下。

> ⚠️ **必须配置 WebSocket 转发头**，否则日志、进度等实时推送功能不可用。

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name media.example.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 500m;
        proxy_read_timeout 300s;
    }
}
server {
    listen 80;
    server_name media.example.com;
    return 301 https://$host$request_uri;
}
```

配合设置：

1. 在 **系统设置 → 基础设置 → 系统** 中「外网访问地址」填 `https://media.example.com`
2. 子路径部署（如 `/nexus`）暂不支持
3. 使用**企业微信交互功能**时，`/wechat` 也需经上述 `location /` 转发（本镜像同样由 Nginx 统一代理）

## 8. 可选组件：nexus-verify 与 nexus-chrome

`docker-compose.mysql.yml` 与 `docker-compose.postgresql.yml` 已内置这两个组件：

| 组件 | 镜像 | 端口 | 作用 |
|---|---|---|---|
| nexus-verify | `linyuan0213/nexus-verify` | 9300 | OCR 验证码识别，用于站点自动签到 |
| nexus-chrome | `linyuan0213/nexus-chrome` | 9850 / 6080 | 浏览器自动化，用于 Cookie 更新、网页自动化登录、AI 助手网页抓取 |

启用方式（**系统设置 → 基础设置 → 实验室**）：

- 验证码识别：填 `http://nexus-verify:9300`
- 网页自动化：填 `http://nexus-chrome:9850`

**nexus-chrome 认证（可选）**：设置 `AUTH_PASSWORD` 后启用登录页 + API 鉴权。

1. 在管理台（`http://<宿主机>:9850/ui/api-keys`）创建 API Key，权限范围建议「会话」+「画像」
2. 将 Key（`ncmk_` 前缀）填入实验室「访问凭证（API Key）」
3. 同时用作指纹画像配置中心推送凭证

未设置 `AUTH_PASSWORD` 时留空即可（本地模式，不鉴权）。

> nexus-chrome 的浏览器页面可通过 VNC（端口 6080）实时查看。
> **安全提示**：VNC 密码为必填项，**禁止使用默认值 `password`**；
> 未在 `.env` 中设置 `VNC_PASSWORD` 时 `docker compose up` 会直接报错。
>
> nexus-chrome 的指纹配置中心数据库、会话记录、指纹画像、浏览器用户数据统一存放在容器
> `/app/data`，compose 已挂载到宿主机 `./data/chrome`。

## 9. 环境变量

优先级：`环境变量 > .env > config.yaml`。嵌套分隔符为 `__`，
例如 `APP__WEB_HOST`、`DATABASE__TYPE`、`REDIS__HOST`。

### 部署变量（`.env`）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `IMAGE_TAG` | `latest` | 使用的镜像标签 |
| `WEB_PORT` | `8080` | 宿主机端口（容器内固定 8080） |
| `VIDEO_DIR` | `/video` | 媒体库挂载目录 |
| `PUID` / `PGID` | `0` | 容器内 nexus 用户的 uid / gid |
| `UMASK` | `000` | 新建文件权限掩码 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `DB_TYPE` | `postgresql` | `sqlite` / `mysql` / `postgresql` |
| `DB_HOST` | `postgresql` | 数据库地址（compose 服务名） |
| `DB_PORT` | `5432` | 数据库端口（MySQL 为 `3306`） |
| `DB_USERNAME` / `DB_DATABASE` | `nexus_media` | 数据库用户名 / 库名 |
| `DB_PASSWORD` | — | 数据库密码，**必填** |
| `MYSQL_ROOT_PASSWORD` | — | 仅 MySQL 变体，**必填** |
| `VNC_PASSWORD` | — | 仅 Chrome 变体，**必填** |
| `AUTH_PASSWORD` | 空 | 仅 Chrome 变体，留空则不鉴权 |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_DB` | `redis` / `6379` / `0` | 容器内映射为 `REDIS__HOST` 等 |

### 镜像专用变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NEXUS_HOST` | `127.0.0.1` | **本镜像新增**：后端监听地址，默认只绑回环 |
| `NEXUS_PORT` | `3000` | 后端监听端口，**同时决定** Granian 监听端口与 Nginx upstream |
| `NEXUS_MEDIA_DATA` | `/data` | 数据目录（配置 / SQLite / 插件） |
| `NEXUS_MEDIA_CONFIG` | `/data/config.yaml` | 配置文件路径（可选） |
| `SKIP_MIGRATION` | `false` | `true` 时跳过启动时的 `alembic upgrade head` |

已被本镜像**废弃**的上游前端变量：`BACKEND_HOST`、`BACKEND_PORT`
（前端不再是独立服务，反代目标由合并后的 nginx 配置固定为 `127.0.0.1:$NEXUS_PORT`）。

### 应用配置变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `APP__WEB_HOST` | `127.0.0.1` | Web 监听地址（本镜像固定回环） |
| `APP__WEB_PORT` | `3000` | Web 监听端口 |
| `APP__LOGIN_USER` | `admin` | 默认登录用户名 |
| `APP__LOGIN_PASSWORD` | `password` | 默认登录密码 |
| `APP__TMDB_DOMAIN` | `api.themoviedb.org` | TMDB API 域名 |
| `APP__DEBUG` | `false` | 开启后提供 `/docs` API 文档 |
| `DATABASE__TYPE` / `DATABASE__HOST` / `DATABASE__PORT` / `DATABASE__USERNAME` / `DATABASE__PASSWORD` / `DATABASE__DATABASE` | — | 数据库连接（compose 由 `DB_*` 映射） |
| `DATABASE__SQLITE_PATH` | `data/user.db` | SQLite 文件路径 |
| `REDIS__HOST` / `REDIS__PORT` / `REDIS__PASSWORD` / `REDIS__DB` | — | Redis 连接（compose 由 `REDIS_*` 映射） |
| `LOG__FORMAT` | `text` | 设为 `json` 输出 ELK 兼容日志 |

> 完整变量清单以上游文档为准：
> [docs/installation.md](https://github.com/linyuan0213/nexus-media/blob/master/docs/installation.md)。

## 10. 目录说明

| 容器路径 | 说明 |
|---|---|
| `/data` | 配置文件、数据库、插件数据（必须挂载） |
| `/data/redis_data` | Redis 持久化数据（compose 内） |
| `/data/chrome` | nexus-chrome 数据 |
| `/usr/share/nginx/html` | 前端静态产物（本镜像由 Nginx 直接托管） |
| `/media` | 媒体库目录（需自行映射） |

## 11. PUID / PGID 机制

**目标：容器内进程以宿主机用户的身份运行，写出来的文件属主与宿主机一致，不用互相 `chown`。**

两道 cont-init 接力（s6 按文件名顺序执行）：

| 脚本 | 来源 | 做什么 |
|---|---|---|
| `020-fixuser` | 上游继承 | `groupmod -o -g $PGID nexus`、`usermod -o -u $PUID nexus`，并 chown `${HOME}`(= `/nexus`) 与 `/config` |
| `030-nginx-runtime-perms` | **本镜像新增** | 把 **Web 根目录**与 **nginx 的 log / pid / temp 目录**重新 chown 给调整后的 nexus |

为什么必须补第二道？上游镜像只处理了 `/nexus` 与 `/config`，而本镜像引入了新目录，
`PUID != 911`（nexus 用户在上游镜像中的原始 uid）时它们不匹配，会依次炸出下面几种故障：

| 目录 | 不处理的后果 |
|---|---|
| `/usr/share/nginx/html` | 前端页面 **403**（nginx worker 以 nexus 身份读不到） |
| `/var/log/nginx` | nginx **启动失败**（连 access_log 都开不了） |
| `/run/nginx`（pid） | nginx **启动失败**（pid 文件写不进） |
| `/var/lib/nginx/body` 等 | **大文件上传 500**（请求体超过 buffer 要落盘到 `client_body_temp_path`） |

**宿主机侧还需要一步**：容器要写 `./data`，宿主机的 `./data` 目录必须对 `PUID:PGID` 可写：

```bash
mkdir -p data data/redis_data
sudo chown -R "$(id -u):$(id -g)" data
```

> 媒体目录 `/media` 建议**只读挂载**或按需给写权限（`-v /mnt/media:/media:ro`），
> 本镜像刻意**不**递归 chown `/data`、`/media`——媒体库往往很大，
> 每次启动递归 chown 既慢又可能改坏宿主机权限，交给上面的宿主侧一次性处理更安全。

## 12. 首次使用

1. 访问前端页面 http://localhost:8080
2. 默认账号密码：用户名 `admin`，密码 `password`
3. **首次登录后必须修改默认密码**
4. 进入 **设置 > 基础设置 > 媒体** 配置 TMDB API Key（必须）
5. 进入 **设置 > 下载器** 添加下载器
6. 进入 **设置 > 媒体服务器** 添加 Emby/Jellyfin/Plex
7. 进入 **站点 > 站点维护** 添加 PT 站点

## 13. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 前端 403 | `PUID/PGID` 与 `/usr/share/nginx/html` 属主不一致 —— 检查 `030-nginx-runtime-perms` 是否执行：`docker logs nexus-media \| grep cont-init` |
| nginx 起不来，日志报 permission | 同上，重点看 `/var/log/nginx`、`/run/nginx` 属主 |
| 大文件上传 500 / 413 | 413 是 `client_max_body_size`（已设 500M）；500 多为 `/var/lib/nginx/body` 不可写 |
| 接口返回 `{"code":-1,"message":"服务正在启动中..."}` | Nginx 起着但后端未就绪：首次启动要跑 `alembic upgrade head`；`docker logs -f nexus-media` 看迁移进度 |
| 数据库连不上 / 一直 unhealthy | 见第 5.4 节「容器间网络互通」 |
| `required variable DB_PASSWORD is missing` | compose 要求显式设置密码，在 `.env` 里填 `DB_PASSWORD`（MySQL 变体还要 `MYSQL_ROOT_PASSWORD`，Chrome 变体还要 `VNC_PASSWORD`） |
| 改了 `NEXUS_PORT` 后连不上 | 本镜像已把应用端口与 upstream 打通，改完重启容器即可 |
| 想换对外端口 | 容器内固定 8080，改宿主机映射即可：`WEB_PORT=9000 docker compose up -d` |
| 数据没持久化 | `/data` 必须挂载；compose 已挂 `./data:/data`，注意宿主侧属主（见第 11 节） |

## 附录 A：与上游两容器方案的差异

| 维度 | 上游（2 容器） | 本镜像（1 容器） |
|---|---|---|
| 容器数 | 2（web + backend） | 1 |
| Nginx 实例 | 2 | **1** |
| 对外端口 | 8080(前端) + 3000(后端 API) | **只有 8080** |
| 前端→后端 | `BACKEND_HOST:PORT` 跨容器 | `127.0.0.1:$NEXUS_PORT`，容器内回环 |
| 后端暴露面 | 宿主机可直连 3000 | 只绑 `127.0.0.1`，不可达 |
| 进程管理 | 前端 nginx 裸跑 + 后端 s6 | 统一 s6 托管，`nginx` 依赖 `nexus-media` 就绪后启动 |
| `NEXUS_PORT` 语义 | 只改 Nginx upstream（改了反而代理到错端口） | 同时作用于应用与 Nginx，语义自洽 |
| `pid` 路径 | `/var/run/nginx.pid`（非 root 时不可写） | `/run/nginx/nginx.pid`，cont-init 预置属主 |
| 大文件上传 | 依赖 PUID=0 才能落盘 | 显式声明 temp 目录并保证可写 |

## 附录 B：Nginx 配置合并取舍

| 分歧点 | 上游后端 | 上游前端 | 本镜像取法 |
|---|---|---|---|
| `/static/` | alias 到 `/nexus-media/static/` | `root html` + `try_files =404` | 前端优先，未命中 `@backend_static` 回落后端 —— 两边都能用 |
| 502/503/504 | 返回 JSON `{"code":-1,...}` | 转 `/50x.html` | 取 JSON：前端 SPA 能直接读 message 提示「服务正在启动」 |
| `client_max_body_size` | `500M` | 无（1m） | 取 `500M`，否则媒体上传会 413 |
| `.mjs` MIME | 无 | `types { application/javascript mjs; }` | 取前者做法（Vben 产物含 `.mjs`） |
| `gzip_static` | 无 | `on` | 取 `on` |
| `/docs` `/openapi.json` | 靠兜底 `/` 转发 | 显式 location | 显式 location（本镜像 `/` 归前端 SPA，必须显式转发） |
