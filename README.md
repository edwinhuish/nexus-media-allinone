# Nexus Media All-in-One

把 **Nginx + nexus-media（后端）+ nexus-media-web（前端）** 整合进 **一个容器**，
对外只暴露 Nginx，前后端通信完全限制在容器内部。

- 上游镜像：`linyuan0213/nexus-media`、`linyuan0213/nexus-media-web`
- 上游源码：[linyuan0213/nexus-media](https://github.com/linyuan0213/nexus-media)、[linyuan0213/nexus-media-web](https://github.com/linyuan0213/nexus-media-web)

---

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
                 Redis（同网络，同样不发布端口）
```

| 端口 | 位置 | 是否对外 |
|---|---|---|
| 8080 | 容器内 Nginx | **是**（唯一入口） |
| 3000 | 容器内 Granian，且只绑 `127.0.0.1` | 否，容器外不可达（连同一 Docker 网络的其它容器也访问不到） |
| 6379 | 独立 Redis 容器 | 否，仅内网 |

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

## 3. 目录结构

```
nexus-media-allinone/
├── Dockerfile                                  # 唯一的构建文件
├── docker-compose.yml                          # 只发布 8080
├── .env.example                                # PUID/PGID/端口/媒体目录
├── Taskfile.yml                                # build / up / verify / nginx-test
├── rootfs/
│   └── etc/
│       ├── cont-init.d/
│       │   └── 030-nginx-runtime-perms         # 新增：PUID 生效后对齐 Nginx 目录属主
│       ├── nginx/
│       │   └── nginx.conf.template             # 合并改写：前端 SPA + 后端反代
│       └── services.d/
│           └── nexus-media/run                 # 覆盖上游：绑定回环 + NEXUS_PORT 贯通
└── scripts/
    ├── nginx-routing-test.sh                   # 不起 Docker 也能验证 Nginx 分流规则
    └── verify.sh                               # 容器启动后的验收脚本
```

## 4. 快速开始

```bash
cp .env.example .env      # 按需修改 PUID/PGID、媒体目录
docker compose up -d --build
open http://localhost:8080
```

或不用 compose：

```bash
docker build -t nexus-media-allinone:latest .

docker run -d \
  --name nexus-media \
  --hostname nexus-media \
  -p 8080:8080 \
  -v "$(pwd)/data:/data" \
  -v /mnt/media:/media \
  -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -e TZ=Asia/Shanghai \
  -e REDIS__HOST=你的redis地址 \
  --restart always \
  nexus-media-allinone:latest
```

> 单容器部署时 Redis / 数据库都在容器外，记得用 `REDIS__*` / `DATABASE__*` 指过去；
> compose 里已经带了一个不发布端口的 Redis。

## 5. PUID / PGID 机制

**目标：容器内进程以宿主机用户的身份运行，写出来的文件属主与宿主机一致，不用互相 `chown`。**

两道 cont-init 接力（s6 按文件名顺序执行）：

| 脚本 | 来源 | 做什么 |
|---|---|---|
| `020-fixuser` | 上游继承 | `groupmod -o -g $PGID nexus`、`usermod -o -u $PUID nexus`，并 chown `${HOME}`(= `/nexus`) 与 `/config` |
| `030-nginx-runtime-perms` | **本镜像新增** | 把 **Web 根目录**与 **nginx 的 log / pid / temp 目录**重新 chown 给调整后的 nexus |

为什么必须补第二道？上游镜像只处理了 `/nexus` 与 `/config`，而本期整合引入了新目录，
`PUID != 911`（nexus 的构建期 uid）时它们不匹配，会依次炸出下面三种故障：

| 目录 | 不处理的后果 |
|---|---|
| `/usr/share/nginx/html` | 前端页面 **403**（nginx worker 以 nexus 身份读不到） |
| `/var/log/nginx` | nginx **启动失败**（连 access_log 都开不了） |
| `/run/nginx`（pid） | nginx **启动失败**（pid 文件写不进；上游写 `/var/run/nginx.pid`，该目录默认仅 root 可写） |
| `/var/lib/nginx/body` 等 | **大文件上传 500**（请求体超过 buffer 要落盘到 `client_body_temp_path`） |

**宿主机侧还需要一步**：容器要写 `./data`，宿主机的 `./data` 目录必须对 `PUID:PGID` 可写：

```bash
mkdir -p data data/redis_data
sudo chown -R "$(id -u):$(id -g)" data      # 让 data 归属与 PUID/PGID 一致
```

> 媒体目录 `/media` 建议**只读挂载**或按需给写权限（`-v /mnt/media:/media:ro`），
> 本镜像刻意**不**递归 chown `/data`、`/media`——媒体库往往很大，
> 每次启动递归 chown 既慢又可能改坏宿主机权限，交给上面的宿主侧一次性处理更安全。

## 6. 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PUID` | `0` | 容器内 nexus 用户的 uid，填宿主机 `id -u` |
| `PGID` | `0` | 容器内 nexus 组的 gid，填宿主机 `id -g` |
| `UMASK` | `000` | 新建文件权限掩码 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `NEXUS_HOST` | `127.0.0.1` | **本镜像新增**：后端监听地址，默认只绑回环 |
| `NEXUS_PORT` | `3000` | 后端监听端口，**同时决定** Granian 监听端口与 Nginx upstream |
| `NEXUS_MEDIA_DATA` | `/data` | 数据目录（配置 / SQLite / 插件） |
| `NEXUS_MEDIA_CONFIG` | `/data/config.yaml` | 配置文件路径 |
| `SKIP_MIGRATION` | `false` | `true` 时跳过启动时的 `alembic upgrade head` |
| `REDIS__HOST/PORT/PASSWORD/DB` | — | Redis 连接；compose 中为 `redis` |
| `DATABASE__TYPE/HOST/PORT/...` | `sqlite` | 使用外部 MySQL / PostgreSQL 时设置 |

已被本镜像**废弃**的上游前端变量：`BACKEND_HOST`、`BACKEND_PORT`
（前端不再是独立服务，反代目标由合并后的 nginx 配置固定为 `127.0.0.1:$NEXUS_PORT`）。

> 除上述镜像变量外，其余配置项同上游：环境变量 > `.env` > `config.yaml`，
> 嵌套用 `__`，如 `APP__LOGIN_PASSWORD`、`LOG__FORMAT`，完整清单见上游
> [`docker/readme.md`](https://github.com/linyuan0213/nexus-media/blob/master/docker/readme.md)。

## 7. 相对上游两镜像方案的差异

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

### 配置合并时的取舍

| 分歧点 | 上游后端 | 上游前端 | 本镜像取法 |
|---|---|---|---|
| `/static/` | alias 到 `/nexus-media/static/` | `root html` + `try_files =404` | 前端优先，未命中 `@backend_static` 回落后端 —— 两边都能用 |
| 502/503/504 | 返回 JSON `{"code":-1,...}` | 转 `/50x.html` | 取 JSON：前端 SPA 能直接读 message 提示「服务正在启动」 |
| `client_max_body_size` | `500M` | 无（1m） | 取 `500M`，否则媒体上传会 413 |
| `.mjs` MIME | 无 | `types { application/javascript mjs; }` | 取前者做法（Vben 产物含 `.mjs`） |
| `gzip_static` | 无 | `on` | 取 `on`（已确认 Debian trixie 的 nginx 编译了该模块） |
| `/docs` `/openapi.json` | 靠兜底 `/` 转发 | 显式 location | 显式 location（本镜像 `/` 归前端 SPA，必须显式转发） |

## 8. 验证

### 8.1 Nginx 分流规则（不起 Docker 也能跑）

```bash
task nginx-test          # 或 bash scripts/nginx-routing-test.sh [/usr/sbin/nginx]
```

脚本会拉起一个 mock 后端 + 真 nginx，逐条断言路由行为。
**本仓库已用 Debian trixie 的 nginx 1.26.3（即基座镜像里的同一版本）实测通过 13/13：**

```
== 前端（本地静态文件）==
  PASS  SPA 首页 / SPA 显式 index / SPA 路由回退 / 前端 assets / 前端 static（命中本地）
== 后端（反向代理到 127.0.0.1:3000）==
  PASS  /api/ping  /health  /img/abc.jpg  /docs  /openapi.json  /ws  /static 回落后端
== 后端不可用时的降级 ==
  PASS  后端挂掉 -> JSON 503: {"code":-1,"message":"服务正在启动中，请稍后刷新..."}

结果：PASS=13 FAIL=0
```

> 本机没有 nginx 二进制时，可以直接借基座镜像里的那一个（镜像内含 python3 / curl / sed）：
>
> ```bash
> docker run --rm -v "$PWD:/w" -w /w --entrypoint bash \
>   nexus-media-allinone:latest scripts/nginx-routing-test.sh
> ```
>
> （复现本文档的验证时，nginx 二进制取自 Debian trixie 的
> `nginx_1.26.3-3+deb13u9_amd64.deb`，解包后直接对模板跑 `nginx -t` 与上述路由测试。）

### 8.2 容器启动后的验收

```bash
docker compose up -d --build
task verify              # 或 bash scripts/verify.sh nexus-media 8080
```

逐项核对：宿主机只发布 8080、容器内 3000 **只绑回环**、
nexus 用户 uid/gid 与 PUID/PGID 一致、前端产物与新目录属主一致、HTTP 三项通。

手工核对：

```bash
docker port nexus-media                      # 只应出现 8080/tcp
docker exec nexus-media id nexus             # uid/gid 应等于 PUID/PGID
docker exec nexus-media ps -ef               # nginx 与 Granian 各一份
docker exec nexus-media cat /etc/nginx/nginx.conf | head -40
```

## 9. 可选：完全从源码构建

本 Dockerfile 默认以**已发布的两个镜像**为基座（版本可用
`--build-arg BACKEND_TAG=4.21.9 FRONTEND_TAG=4.21.9` 锁定），构建快且与线上产物逐字节一致。
上游两个镜像都发布 `linux/amd64` 与 `linux/arm64`，因此本镜像同样可直接多架构构建
（前端产物是平台无关的静态文件，不会被 QEMU 拖累）。

若你要构建自己的 fork，只需先产出两个「中间镜像」，再交给本 Dockerfile：

```bash
# 1) 前端：在原生架构上构建，再把 dist 打成中间镜像
git clone https://github.com/<you>/nexus-media-web && cd nexus-media-web
pnpm install --frozen-lockfile && pnpm run build:nexus       # 产出 apps/nexus-media/dist
docker build -f scripts/deploy/Dockerfile.prod -t my/nexus-media-web:dev .

# 2) 后端
git clone https://github.com/<you>/nexus-media && cd nexus-media
docker build -t my/nexus-media:dev .

# 3) 用本仓库的 Dockerfile 组装
cd nexus-media-allinone
docker build \
  --build-arg BACKEND_IMAGE=my/nexus-media --build-arg BACKEND_TAG=dev \
  --build-arg FRONTEND_IMAGE=my/nexus-media-web --build-arg FRONTEND_TAG=dev \
  -t nexus-media-allinone:dev .
```

> 为什么不把前端编译直接塞进本 Dockerfile：多架构构建时 Node/Rolldown 在 QEMU 仿真下会卡死
> （上游 CI 已为此改成「原生 runner 编译一次 + 两个架构仅 COPY dist」）。
> 沿用同一策略可以避免踩同一个坑；单架构构建时你也可以在 Dockerfile 里加一个
> `FROM node:22 ... RUN pnpm install && pnpm run build:nexus` 的 stage 自行替换。

## 10. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 前端 403 | `PUID/PGID` 与 `/usr/share/nginx/html` 属主不一致 —— 检查 `030-nginx-runtime-perms` 是否执行：`docker logs nexus-media \| grep cont-init` |
| nginx 起不来，日志报 permission | 同上，重点看 `/var/log/nginx`、`/run/nginx` 属主 |
| 大文件上传 500 / 413 | 413 是 `client_max_body_size`（已设 500M）；500 多为 `/var/lib/nginx/body` 不可写 |
| 接口返回 `{"code":-1,"message":"服务正在启动中..."}` | Nginx 起着但后端未就绪：首次启动要跑 `alembic upgrade head`；`docker logs -f nexus-media` 看迁移进度 |
| 改了 `NEXUS_PORT` 后连不上 | 本镜像已把应用端口与 upstream 打通，改完重启容器即可；`task nginx-conf` 可确认渲染结果 |
| 想换内部端口 | 容器内固定 8080，改宿主机映射即可：`WEB_PORT=9000 docker compose up -d` |
| 数据没持久化 | `/data` 必须挂载；compose 已挂 `./data:/data`，注意宿主侧属主（见 §5） |
| 想加新的后端路径 | 在 `rootfs/etc/nginx/nginx.conf.template` 加一个 `location`，参照 `/docs` 的写法，再重新 build |
