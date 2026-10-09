#!/usr/bin/env bash
# =============================================================================
#  容器验收脚本 —— 容器启动后执行，逐项核对「只暴露 Nginx 端口」这一约束
#
#  用法：scripts/verify.sh [容器名] [宿主机端口]
#  依赖：docker、curl
# =============================================================================
set -uo pipefail

CTN="${1:-nexus-media}"
PORT="${2:-8080}"
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v docker >/dev/null || { echo "缺少 docker 命令"; exit 2; }
docker inspect "$CTN" >/dev/null 2>&1 || { echo "找不到容器 $CTN，先 docker compose up -d"; exit 2; }

# 十六进制端口：3000 -> 0BB8, 8080 -> 1F90
hexport() { printf '%04X' "$1"; }
APP_HEX="$(hexport 3000)"
NGX_HEX="$(hexport 8080)"

hdr "1. 端口发布（宿主机侧）"
published="$(docker port "$CTN" 2>/dev/null || true)"
echo "$published" | sed 's/^/      /'
extra="$(echo "$published" | awk -F/ '{print $1}' | cut -d: -f2 | grep -v "^${PORT}$" | grep -v '^$' || true)"
if [ -z "$extra" ]; then
    ok "只发布了 $PORT，无其他端口"
else
    bad "除 $PORT 外还发布了：$(echo "$extra" | tr '\n' ' ')"
fi

hdr "2. 监听地址（容器内 /proc/net/tcp，不依赖 ss/netstat）"
listen_addrs() {  # $1 = 十六进制端口
    docker exec "$CTN" sh -c "awk '\$2 ~ /:${1}\$/ && \$4==\"0A\" {print \$2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null" || true
}

ngx_listen="$(listen_addrs "$NGX_HEX")"
if echo "$ngx_listen" | grep -qiE '^(00000000|00000000000000000000000000000000):'; then
    ok "Nginx 监听在全部网卡（对外入口）：$(echo "$ngx_listen" | tr '\n' ' ')"
elif [ -n "$ngx_listen" ]; then
    note "Nginx 监听：$(echo "$ngx_listen" | tr '\n' ' ')"
else
    bad "容器内没有监听的 Nginx 端口 8080 —— 服务未起来？"
fi

app_listen="$(listen_addrs "$APP_HEX")"
if [ -z "$app_listen" ]; then
    bad "容器内没有监听的 3000 端口（后端未启动？）"
else
    non_loopback="$(echo "$app_listen" \
        | grep -vE '^0100007F:' \
        | grep -viE '^00000000000000000000000001000000:' || true)"
    if [ -z "$non_loopback" ]; then
        ok "后端 3000 仅绑回环（容器外不可达）：$(echo "$app_listen" | tr '\n' ' ')"
    else
        bad "后端 3000 监听在非回环地址：$(echo "$non_loopback" | tr '\n' ' ')"
    fi
fi

hdr "3. PUID / PGID 是否真的生效"
want_uid="$(docker exec "$CTN" printenv PUID 2>/dev/null || echo '?')"
want_gid="$(docker exec "$CTN" printenv PGID 2>/dev/null || echo '?')"
have="$(docker exec "$CTN" id nexus 2>/dev/null || true)"
echo "      PUID=${want_uid} PGID=${want_gid}  ->  ${have}"
have_uid="$(echo "$have" | sed -n 's/^uid=\([0-9]*\).*/\1/p')"
have_gid="$(echo "$have" | sed -n 's/.*gid=\([0-9]*\).*/\1/p')"
if [ "$have_uid" = "$want_uid" ] && [ "$have_gid" = "$want_gid" ]; then
    ok "nexus 用户 uid/gid 已按 PUID/PGID 调整"
else
    bad "nexus 用户 uid/gid 与 PUID/PGID 不一致"
fi

web_owner="$(docker exec "$CTN" stat -c '%u:%g' /usr/share/nginx/html 2>/dev/null || echo '?')"
if [ "$web_owner" = "${want_uid}:${want_gid}" ]; then
    ok "前端产物属主与 PUID/PGID 一致（$web_owner）"
else
    bad "前端产物属主为 $web_owner，期望 ${want_uid}:${want_gid}"
fi

for d in /var/log/nginx /run/nginx /var/lib/nginx/body; do
    owner="$(docker exec "$CTN" stat -c '%u:%g' "$d" 2>/dev/null || echo '?')"
    if [ "$owner" = "${want_uid}:${want_gid}" ]; then
        ok "$d 属主 = $owner"
    else
        bad "$d 属主 = $owner，期望 ${want_uid}:${want_gid}"
    fi
done

hdr "4. 受管进程（s6-overlay）"
docker exec "$CTN" sh -c 'ps -eo user,pid,args | grep -E "nginx|granian|run.py|s6-svscan" | grep -v grep' \
    | sed 's/^/      /' || true

hdr "5. HTTP 行为"
code() { curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"; }

c="$(code "$BASE/")"
[ "$c" = "200" ] && ok "前端首页 GET / -> 200" || bad "前端首页 GET / -> $c"

c="$(code "$BASE/health")"
[ "$c" = "200" ] && ok "后端健康检查 GET /health -> 200（经 Nginx 反代）" || bad "GET /health -> $c"

c="$(code "$BASE/api/")"
case "$c" in
    502|503|504) bad "GET /api/ -> $c（后端不可用）" ;;
    *)           ok  "GET /api/ -> $c（已转发到后端，非网关错误）" ;;
esac

hdr "6. 宿主机直连后端端口应为不通"
if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/3000" 2>/dev/null; then
    note "宿主机 127.0.0.1:3000 可连——若你另有服务占用该端口请忽略；否则说明端口被误发布"
else
    ok "宿主机 127.0.0.1:3000 不可连（未发布后端端口）"
fi

printf '\n\033[1m结果：PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
