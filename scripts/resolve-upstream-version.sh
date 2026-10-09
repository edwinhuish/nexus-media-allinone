#!/usr/bin/env bash
# =============================================================================
#  解析上游镜像版本号（Docker Hub），并给出本次发布的决策
#
#  必需环境变量：
#    IMAGE_NAME     本镜像仓库，用于判断指定版本是否已发布
#    BACKEND_REPO   上游后端仓库
#    FRONTEND_REPO  上游前端仓库
#  可选环境变量：
#    VERSION        用户指定的版本号（如 4.22.1）；为空则取上游最新版本
#
#  输出协议 —— stdout 只输出 key=value（每行一条），便于调用方直接消费：
#    publish=true|false          是否需要构建并推送
#    update_overview=true|false  是否需要同步说明文档
#    backend_tag=<版本>          上游后端使用的版本（publish=false 时省略）
#    frontend_tag=<版本>         上游前端使用的版本（publish=false 时省略）
#
#  进度与错误信息一律写到 stderr，失败时以非 0 退出；不依赖任何 CI 平台专有变量。
#
#  用法（本地）：
#    IMAGE_NAME=edwinhuish/nexus-media-allinone \
#    BACKEND_REPO=linyuan0213/nexus-media \
#    FRONTEND_REPO=linyuan0213/nexus-media-web \
#    VERSION=4.22.1 ./scripts/resolve-upstream-version.sh
# =============================================================================
set -euo pipefail

: "${IMAGE_NAME:?缺少环境变量 IMAGE_NAME}"
: "${BACKEND_REPO:?缺少环境变量 BACKEND_REPO}"
: "${FRONTEND_REPO:?缺少环境变量 FRONTEND_REPO}"

VERSION="${VERSION:-}"
BACKEND_TAG=""
FRONTEND_TAG=""
PUBLISH=""
UPDATE_OVERVIEW=""

API_BASE="https://hub.docker.com/v2/repositories"

log() { printf '%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# 列出指定仓库的全部 tag 名（自动翻页）
fetch_tags() {
    local repo="$1" page=1 body names
    while :; do
        body="$(curl -fsSL --max-time 30 \
            "${API_BASE}/${repo}/tags?page_size=100&page=${page}")" \
            || die "无法访问 Docker Hub API：${repo}"
        names="$(printf '%s' "$body" | jq -r '.results[]?.name // empty')"
        if [ -n "$names" ]; then
            printf '%s\n' "$names"
        fi
        if [ "$(printf '%s' "$body" | jq -r '.next')" = "null" ]; then
            break
        fi
        page=$((page + 1))
    done
}

# 指定仓库是否存在该 tag（网络异常直接失败，不与「不存在」混淆）
tag_exists() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
        "${API_BASE}/$1/tags/$2")" \
        || die "无法访问 Docker Hub API（$1:$2）"
    [ "$code" = "200" ]
}

# 只保留 vX.Y.Z / X.Y.Z 形态（latest 等自动排除），输出「归一化版本<TAB>原始 tag」
version_tags() {
    fetch_tags "$1" \
        | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
        | awk '{ v = $0; sub(/^v/, "", v); print v "\t" $0 }'
}

# 最新版本 tag
latest_version_tag() {
    version_tags "$1" | sort -s -k1,1V | tail -n1 | cut -f2
}

# 大于 $2 且最接近的版本 tag
nearest_greater_version_tag() {
    version_tags "$1" \
        | awk -v b="$2" '{
              split($0, c, "\t"); split(c[1], x, "."); split(b, y, ".");
              if (x[1] > y[1] || (x[1] == y[1] && x[2] > y[2]) \
                  || (x[1] == y[1] && x[2] == y[2] && x[3] > y[3])) print
          }' \
        | sort -s -k1,1V | head -n1 | cut -f2
}

# 输出决策结果
emit() {
    printf 'publish=%s\n' "${PUBLISH}"
    printf 'update_overview=%s\n' "${UPDATE_OVERVIEW}"
    if [ -n "${BACKEND_TAG}" ]; then
        printf 'backend_tag=%s\n' "${BACKEND_TAG}"
    fi
    if [ -n "${FRONTEND_TAG}" ]; then
        printf 'frontend_tag=%s\n' "${FRONTEND_TAG}"
    fi
}

if [ -n "${VERSION}" ]; then
    SPEC="${VERSION#v}"
    if ! printf '%s' "$SPEC" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        die "版本号格式非法：${VERSION}（应形如 4.22.1）"
    fi

    # 该版本已发布过 → 整次跳过（不构建、不推送、不更新说明文档）
    if tag_exists "${IMAGE_NAME}" "${SPEC}"; then
        log "版本 ${SPEC} 已发布（${IMAGE_NAME}:${SPEC}），跳过构建与推送"
        PUBLISH=false
        UPDATE_OVERVIEW=false
        emit
        exit 0
    fi

    # 后端：必须存在该版本
    if ! tag_exists "${BACKEND_REPO}" "${SPEC}"; then
        die "上游 ${BACKEND_REPO} 不存在版本 ${SPEC}（最新版本为 $(latest_version_tag "${BACKEND_REPO}")）"
    fi
    BACKEND_TAG="${SPEC}"

    # 前端：优先同版本，否则取比它大且最接近的版本
    if tag_exists "${FRONTEND_REPO}" "${SPEC}"; then
        FRONTEND_TAG="${SPEC}"
    else
        FRONTEND_TAG="$(nearest_greater_version_tag "${FRONTEND_REPO}" "${SPEC}")"
        if [ -z "${FRONTEND_TAG}" ]; then
            die "上游 ${FRONTEND_REPO} 不存在 ${SPEC}，也没有比它更高的版本"
        fi
        log "上游前端无 ${SPEC}，改用更高的最近版本 ${FRONTEND_TAG}"
    fi

    PUBLISH=true
    UPDATE_OVERVIEW=false
else
    BACKEND_TAG="$(latest_version_tag "${BACKEND_REPO}")"
    FRONTEND_TAG="$(latest_version_tag "${FRONTEND_REPO}")"
    if [ -z "${BACKEND_TAG}" ] || [ -z "${FRONTEND_TAG}" ]; then
        die "未能解析到上游版本 tag（backend='${BACKEND_TAG}' frontend='${FRONTEND_TAG}'）"
    fi
    PUBLISH=true
    UPDATE_OVERVIEW=true
fi

log "上游版本：backend=${BACKEND_TAG} frontend=${FRONTEND_TAG}"
emit
