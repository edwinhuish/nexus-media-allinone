# syntax=docker/dockerfile:1

# =============================================================================
#  Nexus Media All-in-One
#  Nginx（唯一对外入口） + nexus-media 后端 + nexus-media-web 前端（静态产物）
#
#  设计要点
#    1. 只保留【一个】Nginx。前端镜像里的 Nginx 只被当作“静态产物打包器”，
#       取出其 /usr/share/nginx/html 后，由后端镜像自带的 Nginx 统一对外服务。
#       → 不做 nginx 套 nginx 的二次转发，单进程树 / 单日志 / 单配置。
#    2. 对外只暴露 8080（Nginx）。后端 Granian 绑定 127.0.0.1，只在容器内回环
#       可达，既不发布端口，也不监听外部网卡 → 前后端通信完全限制在容器内部。
#    3. 进程管理沿用上游后端的 s6-overlay（已有 nexus-media / nginx 两个受管
#       服务及其依赖关系），并保留其 PUID / PGID 机制。
#
#  上游镜像（本文件以此为基座，不重新编译上游源码）
#    linyuan0213/nexus-media      运行时基座：python:3.14-slim-trixie + uv .venv
#                                 + nginx + s6-overlay + nexus 用户（UID 911）
#    linyuan0213/nexus-media-web  前端静态产物：nginx:stable-alpine + dist
#  上游源码
#    https://github.com/linyuan0213/nexus-media
#    https://github.com/linyuan0213/nexus-media-web
# =============================================================================

ARG BACKEND_IMAGE=linyuan0213/nexus-media
ARG BACKEND_TAG=latest
ARG FRONTEND_IMAGE=linyuan0213/nexus-media-web
ARG FRONTEND_TAG=latest

# -----------------------------------------------------------------------------
# 阶段 1：前端镜像 —— 只取静态产物，丢弃其 Nginx
# -----------------------------------------------------------------------------
FROM ${FRONTEND_IMAGE}:${FRONTEND_TAG} AS web

# -----------------------------------------------------------------------------
# 阶段 2：最终镜像 —— 后端运行时基座 + 前端产物 + 合并版 Nginx 配置
# -----------------------------------------------------------------------------
FROM ${BACKEND_IMAGE}:${BACKEND_TAG}

# 重新声明，供 LABEL 使用（ARG 在 FROM 之后不再自动可用）
ARG BACKEND_IMAGE
ARG BACKEND_TAG
ARG FRONTEND_IMAGE
ARG FRONTEND_TAG

LABEL org.opencontainers.image.title="nexus-media-allinone" \
      org.opencontainers.image.description="Nexus Media 后端 + 前端 + Nginx 单容器整合镜像（仅 Nginx 对外暴露端口）" \
      org.opencontainers.image.source="https://github.com/linyuan0213/nexus-media" \
      org.opencontainers.image.base.name="${BACKEND_IMAGE}:${BACKEND_TAG}" \
      org.opencontainers.image.version="web=${FRONTEND_IMAGE}:${FRONTEND_TAG}"

# --- 前端静态产物（Nginx 以 nexus 身份读取，故直接 chown）---
COPY --from=web --chown=nexus:nexus /usr/share/nginx/html/ /usr/share/nginx/html/

# --- 合并版 Nginx 配置模板 ---
# 上游自带的 /etc/cont-init.d/021-nginx-port 会在每次启动时把模板里的
# __NEXUS_PORT__ 渲染为 $NEXUS_PORT 并覆盖 /etc/nginx/nginx.conf，故只需替换模板。
COPY --chmod=644 rootfs/etc/nginx/nginx.conf.template /etc/nginx/nginx.conf.template

# --- 覆盖后端服务脚本：应用绑定回环地址，且让 NEXUS_PORT 同时作用于应用与 Nginx ---
COPY --chmod=755 rootfs/etc/services.d/nexus-media/run /etc/services.d/nexus-media/run

# --- 新增 cont-init：PUID / PGID 生效后，重新对齐 Nginx 运行所需目录的属主 ---
# 上游 020-fixuser 只处理 ${HOME} 与 /config；本镜像引入了 Web 根目录以及
# nginx 的 log / pid / temp 目录，必须一并对齐：
#   · Web 根目录不可读   → 前端页面 403
#   · /var/log/nginx 不可写 → nginx 启动失败
#   · /var/lib/nginx/* 不可写 → 大文件上传（client_body_temp）返回 500
COPY --chmod=755 rootfs/etc/cont-init.d/030-nginx-runtime-perms /etc/cont-init.d/030-nginx-runtime-perms

# --- 后端监听地址：仅容器内回环，外部不可达 ---
# 与 NEXUS_PORT（默认 3000，继承自上游基座镜像）配套，映射到 APP__WEB_HOST / APP__WEB_PORT
ENV NEXUS_HOST=127.0.0.1

# 容器内唯一对外端口：Nginx
# 注：上游基座镜像残留的 EXPOSE 3000 只是元数据，不会发布端口；实际发布端口
#     由 docker run -p / compose ports 决定，本镜像只发布 8080。
EXPOSE 8080

# 配置 / SQLite / 插件数据 / 日志目录；未显式挂载时也保证不随容器销毁而丢失
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1

# 沿用上游 s6-overlay 入口：拉起 nexus-media 与 nginx 两个受管服务
ENTRYPOINT ["/init"]
