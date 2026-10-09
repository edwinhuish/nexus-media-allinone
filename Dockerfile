# syntax=docker/dockerfile:1

# =============================================================================
#  Nexus Media All-in-One
#  单容器整合：后端运行时基座 + 前端静态产物 + 唯一 Nginx
#
#  · 只保留一个 Nginx：前端镜像仅贡献 /usr/share/nginx/html，丢弃其 Nginx
#  · 对外只暴露 8080；后端 Granian 绑 127.0.0.1，容器外不可达
#  · 进程沿用上游 s6-overlay 托管，保留 PUID / PGID 机制
#
#  上游镜像：linyuan0213/nexus-media、linyuan0213/nexus-media-web
#  上游源码：https://github.com/linyuan0213/nexus-media
# =============================================================================

ARG BACKEND_IMAGE=linyuan0213/nexus-media
ARG BACKEND_TAG=latest
ARG FRONTEND_IMAGE=linyuan0213/nexus-media-web
ARG FRONTEND_TAG=latest

# --- 阶段 1：前端镜像，只取静态产物 ---
FROM ${FRONTEND_IMAGE}:${FRONTEND_TAG} AS web

# --- 阶段 2：最终镜像，后端基座 + 前端产物 + 合并版 Nginx 配置 ---
FROM ${BACKEND_IMAGE}:${BACKEND_TAG}

# ARG 在 FROM 之后不再自动可用，需重新声明
ARG BACKEND_IMAGE
ARG BACKEND_TAG
ARG FRONTEND_IMAGE
ARG FRONTEND_TAG

LABEL org.opencontainers.image.title="nexus-media-allinone" \
      org.opencontainers.image.description="Nexus Media 后端 + 前端 + Nginx 单容器整合镜像（仅 Nginx 对外暴露端口）" \
      org.opencontainers.image.source="https://github.com/linyuan0213/nexus-media" \
      org.opencontainers.image.base.name="${BACKEND_IMAGE}:${BACKEND_TAG}" \
      org.opencontainers.image.version="web=${FRONTEND_IMAGE}:${FRONTEND_TAG}"

# 前端静态产物（Nginx 以 nexus 身份读取，故直接 chown）
COPY --from=web --chown=nexus:nexus /usr/share/nginx/html/ /usr/share/nginx/html/

# 合并版 Nginx 配置模板：上游 021-nginx-port 启动时渲染 __NEXUS_PORT__ 并覆盖 nginx.conf
COPY --chmod=644 rootfs/etc/nginx/nginx.conf.template /etc/nginx/nginx.conf.template

# 覆盖后端服务脚本：应用绑定回环，且 NEXUS_PORT 同时作用于应用与 Nginx
COPY --chmod=755 rootfs/etc/services.d/nexus-media/run /etc/services.d/nexus-media/run

# 新增 cont-init：PUID / PGID 生效后重新对齐 Nginx 运行目录属主
COPY --chmod=755 rootfs/etc/cont-init.d/030-nginx-runtime-perms /etc/cont-init.d/030-nginx-runtime-perms

# 后端监听地址：仅容器内回环，与 NEXUS_PORT（默认 3000）配套
ENV NEXUS_HOST=127.0.0.1

# 容器内唯一对外端口；上游基座残留的 EXPOSE 3000 只是元数据，不发布端口
EXPOSE 8080

# 配置文件 / SQLite / 插件数据 / 日志；未显式挂载时也不随容器销毁而丢失
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1

# 沿用上游 s6-overlay 入口：拉起 nexus-media 与 nginx 两个受管服务
ENTRYPOINT ["/init"]
