#!/usr/bin/env bash
# =============================================================================
#  把本地 README 同步为 Docker Hub 仓库的 Overview（full_description）
#
#  为什么自己写而不用 peter-evans/dockerhub-description：
#    该 action 内部只做两件事 —— POST /v2/auth/token 换 JWT，再 PATCH 仓库
#    （源码见 src/dockerhub-helper.ts），它本身从不调用任何删除操作。但它把
#    失败压缩成一句 statusText（既无状态码也无响应体），而 Docker Hub 这个
#    接口的 403 有两种截然不同的成因：
#      1) token 权限档位不足（该接口在 Docker Hub 侧要求 Read+Write+Delete）
#      2) 前置的 Cloudflare WAF 拦截了请求内容（README 里的 shell 管道等）
#    两者症状一模一样，必须看到原始响应头与响应体才能区分 —— 本脚本会把它们
#    完整打印出来。若确为成因 2，则根本不需要提升 token 权限。
#
#  必需环境变量：
#    DOCKERHUB_USERNAME     Docker Hub 用户名
#    DOCKERHUB_TOKEN        Docker Hub 密码或 Personal Access Token
#    DOCKERHUB_REPOSITORY   目标仓库，形如 <命名空间>/<仓库名>
#  可选环境变量：
#    README_FILEPATH        要同步的文件（默认 ./README.md）
#    OVERVIEW_MAX_BYTES     Overview 字节上限（默认 25000，Docker Hub 侧限制）
#    DOCKERHUB_SHORT_DESCRIPTION   仓库简短描述；留空则不修改该项
#    SHORT_DESCRIPTION_MAX_BYTES   简短描述字节上限（默认 100，Docker Hub 侧限制）
#
#  CI 中由 .github/workflows/docker-publish.yml 以 run + env 直接调用，不依赖任何
#  第三方 action（原先使用的 peter-evans/dockerhub-description 已移除）。
#
#  用法（本地）：
#    DOCKERHUB_USERNAME=user DOCKERHUB_TOKEN=xxx \
#    DOCKERHUB_REPOSITORY=edwinhuish/nexus-media-allinone \
#    ./scripts/update-dockerhub-overview.sh
# =============================================================================
set -euo pipefail

: "${DOCKERHUB_USERNAME:?缺少环境变量 DOCKERHUB_USERNAME}"
: "${DOCKERHUB_TOKEN:?缺少环境变量 DOCKERHUB_TOKEN}"
: "${DOCKERHUB_REPOSITORY:?缺少环境变量 DOCKERHUB_REPOSITORY}"

README_FILEPATH="${README_FILEPATH:-./README.md}"
OVERVIEW_MAX_BYTES="${OVERVIEW_MAX_BYTES:-25000}"
SHORT_DESCRIPTION_MAX_BYTES="${SHORT_DESCRIPTION_MAX_BYTES:-100}"
API_BASE="https://hub.docker.com/v2"

log() { printf '%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# 按字节截断（stdin -> stdout），并丢弃截断处残留的半个多字节字符。
# head -c 按字节切，末尾可能切出半个 UTF-8 字符；iconv -c 会丢掉它，但此时
# iconv 自身反而以非 0 退出（stdout 仍是完好的前缀），必须吞掉这个状态，
# 否则配合 set -o pipefail 会让整个脚本中断。
byte_truncate() {
    head -c "$1" | { iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true; }
}

command -v curl >/dev/null || die "缺少 curl 命令"
command -v jq >/dev/null || die "缺少 jq 命令"
[ -f "$README_FILEPATH" ] || die "找不到文件：${README_FILEPATH}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1. 截断到 Docker Hub 的字节上限 ---------------------------------------
readme_file="${TMP_DIR}/readme.md"
size="$(wc -c < "$README_FILEPATH" | tr -d ' ')"
if [ "$size" -gt "$OVERVIEW_MAX_BYTES" ]; then
    log "提示：${README_FILEPATH} 为 ${size} 字节，超过上限 ${OVERVIEW_MAX_BYTES} 字节，已截断"
    byte_truncate "$OVERVIEW_MAX_BYTES" < "$README_FILEPATH" > "$readme_file"
else
    cp "$README_FILEPATH" "$readme_file"
fi

# 简短描述（可选）：同样按字节截断
short_description="${DOCKERHUB_SHORT_DESCRIPTION:-}"
if [ -n "$short_description" ]; then
    desc_size="$(printf '%s' "$short_description" | wc -c | tr -d ' ')"
    if [ "$desc_size" -gt "$SHORT_DESCRIPTION_MAX_BYTES" ]; then
        log "提示：简短描述为 ${desc_size} 字节，超过上限 ${SHORT_DESCRIPTION_MAX_BYTES} 字节，已截断"
        short_description="$(printf '%s' "$short_description" \
            | byte_truncate "$SHORT_DESCRIPTION_MAX_BYTES")"
    fi
fi

# --- 2. 用用户名 + 密码/PAT 换取 JWT ---------------------------------------
login_json="${TMP_DIR}/login.json"
jq -n --arg u "$DOCKERHUB_USERNAME" --arg s "$DOCKERHUB_TOKEN" \
    '{identifier: $u, secret: $s}' > "$login_json"

auth_body="${TMP_DIR}/auth.json"
auth_code="$(curl -sS -o "$auth_body" -w '%{http_code}' --max-time 30 \
    -X POST "${API_BASE}/auth/token" \
    -H 'Content-Type: application/json' \
    --data-binary @"$login_json")" || die "无法访问 Docker Hub 认证接口"

if [ "$auth_code" != "200" ]; then
    log "认证失败（HTTP ${auth_code}），响应体："
    cat "$auth_body" >&2
    printf '\n' >&2
    die "DOCKERHUB_USERNAME / DOCKERHUB_TOKEN 无效或已过期"
fi

token="$(jq -r '.access_token // empty' "$auth_body")"
[ -n "$token" ] || die "认证响应中没有 access_token 字段"

# 让 CI 日志自动屏蔽令牌；本地运行时不打，避免把令牌写进终端
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::add-mask::%s\n' "$token"
fi

# --- 3. 提交 Overview ------------------------------------------------------
patch_json="${TMP_DIR}/patch.json"
if [ -n "$short_description" ]; then
    jq -n --rawfile readme "$readme_file" --arg desc "$short_description" \
        '{full_description: $readme, description: $desc}' > "$patch_json"
else
    jq -n --rawfile readme "$readme_file" '{full_description: $readme}' > "$patch_json"
fi

resp_body="${TMP_DIR}/resp.body"
resp_head="${TMP_DIR}/resp.head"
resp_code="$(curl -sS -o "$resp_body" -D "$resp_head" -w '%{http_code}' --max-time 60 \
    -X PATCH "${API_BASE}/repositories/${DOCKERHUB_REPOSITORY}" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$patch_json")" || die "无法访问 Docker Hub 仓库接口"

if [ "$resp_code" = "200" ]; then
    log "已更新 ${DOCKERHUB_REPOSITORY} 的 Overview（$(wc -c < "$readme_file" | tr -d ' ') 字节）"
    exit 0
fi

# --- 4. 失败诊断 -----------------------------------------------------------
log "更新 ${DOCKERHUB_REPOSITORY} 的 Overview 失败，HTTP ${resp_code}"
log "--- 响应头（关键部分） ---"
log "（注意：Docker Hub 正常响应本身就带 server: cloudflare / cf-ray，仅凭这些不能判定被拦截）"
grep -iE '^(server|cf-|x-)' "$resp_head" >&2 || true
log "--- 响应体 ---"
cat "$resp_body" >&2
printf '\n' >&2

# Cloudflare WAF 与 token 权限不足都会回 403，只能靠拦截页特征区分
waf_hit=0
if grep -qiE 'you have been blocked|security service|attention required|cf-mitigated' \
        "$resp_body" "$resp_head" >/dev/null; then
    waf_hit=1
elif [ "$resp_code" = "403" ] && ! grep -qi 'application/json' "$resp_head"; then
    # 403 但响应不是 JSON（拦截页是 HTML）——同样指向 WAF
    waf_hit=1
fi

if [ "$waf_hit" -eq 1 ]; then
    die "这看起来是 Docker Hub 前置的 Cloudflare WAF 拦截了请求内容，与 token 权限无关。\
常见触发点是 README 中的 shell 管道（如 'xxx | tail -30'、'docker logs ... | grep ...'）\
或 /etc/passwd、/etc/shadow 一类字符串；改写这些片段后重试即可，无需提升 token 权限"
fi

case "$resp_code" in
    401)
        die "HTTP 401：凭据无效或已过期，请重新生成 DOCKERHUB_TOKEN"
        ;;
    403)
        die "HTTP 403 且响应是 Docker Hub 的 JSON 错误（无 Cloudflare 拦截特征）：\
这是 token 权限档位不足 —— 该接口要求 Personal Access Token 具备 Read + Write + Delete，\
仅 Read & Write 会被拒（action 仓库 issue #248 中有实测）"
        ;;
    404)
        die "HTTP 404：仓库不存在，或该账号对其无权限（组织仓库需 Admin）"
        ;;
    *)
        die "未预期的响应，请按上面的响应头与响应体排查"
        ;;
esac
