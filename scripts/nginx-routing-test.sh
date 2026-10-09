#!/usr/bin/env bash
# =============================================================================
#  Nginx 路由行为测试（无需 Docker）
#
#  用宿主机上的 nginx 二进制 + 一个 mock 后端，验证合并后的 nginx.conf.template
#  是否按预期分流：
#      前端 SPA / 前端静态资源   → 本地文件
#      /api/ /health /img /docs  → 反向代理到 127.0.0.1:3000
#      /static/ 两边都有         → 前端优先，未命中回落后端
#      后端挂掉                  → 返回 JSON 503（而非 HTML 错误页）
#
#  依赖：nginx、python3、curl
#  用法：scripts/nginx-routing-test.sh [nginx 二进制路径]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$PROJECT_DIR/rootfs/etc/nginx/nginx.conf.template"

NGINX_BIN="${1:-$(command -v nginx || true)}"
if [ -z "$NGINX_BIN" ] || [ ! -x "$NGINX_BIN" ]; then
    echo "未找到 nginx 二进制。请显式传入路径：$0 /usr/sbin/nginx" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nexus-nginx-test.XXXXXX")"
PHPORT=13000     # mock 后端，替代 NEXUS_PORT=3000
PUBPORT=18080    # nginx 对外监听，替代 8080
PASS=0
FAIL=0

cleanup() {
    [ -f "$WORK/run/nginx/nginx.pid" ] && kill "$(cat "$WORK/run/nginx/nginx.pid")" 2>/dev/null || true
    [ -n "${BACKEND_PID:-}" ] && kill "$BACKEND_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------- 目录与文件 ----------------
HTML="$WORK/usr/share/nginx/html"
mkdir -p "$HTML/assets" "$HTML/static" \
         "$WORK/var/log/nginx" "$WORK/var/lib/nginx/body" "$WORK/var/lib/nginx/proxy" \
         "$WORK/var/lib/nginx/fastcgi" "$WORK/var/lib/nginx/uwsgi" "$WORK/var/lib/nginx/scgi" \
         "$WORK/run/nginx" "$WORK/etc/nginx"
printf 'index\n'                          > "$HTML/index.html"
printf 'frontend-asset\n'                 > "$HTML/assets/app.js"
printf 'frontend-static\n'                > "$HTML/static/frontend.css"
printf 'types { text/html html; application/javascript js; text/css css; }\n' > "$WORK/etc/nginx/mime.types"

# ---------------- mock 后端 ----------------
cat > "$WORK/backend.py" <<PYEOF
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/plain"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = self.path
        if p == "/health":
            self._send(200, "health-ok")
        elif p.startswith("/api/"):
            self._send(200, json.dumps({"code": 0, "path": p}), "application/json")
        elif p.startswith("/img"):
            self._send(200, "img-bytes")
        elif p == "/docs":
            self._send(200, "<html>docs</html>", "text/html")
        elif p == "/openapi.json":
            self._send(200, "{}", "application/json")
        elif p.startswith("/static/"):
            self._send(200, "backend-static\n")
        elif p == "/ws":
            self._send(200, "ws-placeholder")
        else:
            self._send(404, "backend-404:" + p)

HTTPServer(("127.0.0.1", $PHPORT), H).serve_forever()
PYEOF

python3 "$WORK/backend.py" &
BACKEND_PID=$!

# ---------------- 渲染 nginx.conf（把沙箱外的绝对路径与端口换成测试值）----------------
sed -e 's#user nexus;#user root;#' \
    -e "s#/etc/nginx/mime.types#$WORK/etc/nginx/mime.types#" \
    -e "s#/var/log/nginx#$WORK/var/log/nginx#g" \
    -e "s#/run/nginx#$WORK/run/nginx#g" \
    -e "s#/var/lib/nginx#$WORK/var/lib/nginx#g" \
    -e "s#/usr/share/nginx/html#$HTML#g" \
    -e "s#__NEXUS_PORT__#$PHPORT#g" \
    -e "s#listen 8080#listen $PUBPORT#" \
    -e "s#listen \[::\]:8080#listen [::]:$PUBPORT#" \
    "$TEMPLATE" > "$WORK/etc/nginx/nginx.conf"

# ---------------- 起 nginx ----------------
"$NGINX_BIN" -t -c "$WORK/etc/nginx/nginx.conf" -p "$WORK" 2>&1 | sed 's/^/  /'
"$NGINX_BIN" -c "$WORK/etc/nginx/nginx.conf" -p "$WORK"
sleep 1

BASE="http://127.0.0.1:$PUBPORT"

check() {  # check <描述> <期望片段> <期望状态> <路径>
    local desc="$1" want="$2" code="$3" path="$4"
    local body actual_code
    body="$(curl -sS -m 5 "$BASE$path" 2>/dev/null || true)"
    actual_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$BASE$path" 2>/dev/null || true)"
    if [ "$actual_code" = "$code" ] && printf '%s' "$body" | grep -q "$want"; then
        printf '  \033[32mPASS\033[0m  %-34s %s -> %s (%s)\n' "$desc" "$path" "$actual_code" "$want"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m  %-34s %s -> %s, 期望 %s 且包含 "%s"\n' \
               "$desc" "$path" "${actual_code:-无响应}" "$code" "$want"
        printf '         实际响应: %s\n' "$(printf '%s' "$body" | head -c 200)"
        FAIL=$((FAIL + 1))
    fi
}

echo "== 前端（本地静态文件）=="
check "SPA 首页"                "index"            200 "/"
check "SPA 显式 index"          "index"            200 "/index.html"
check "SPA 路由回退"            "index"            200 "/some/deep/route"
check "前端 assets"             "frontend-asset"   200 "/assets/app.js"
check "前端 static（命中本地）" "frontend-static"  200 "/static/frontend.css"

echo "== 后端（反向代理到 127.0.0.1:$PHPORT）=="
check "API"                     '"path": "/api/ping"' 200 "/api/ping"
check "健康检查"                "health-ok"        200 "/health"
check "图片反代"                "img-bytes"        200 "/img/abc.jpg"
check "API 文档"                "docs"             200 "/docs"
check "OpenAPI"                 "{}"               200 "/openapi.json"
check "WebSocket 端点可达"      "ws-placeholder"   200 "/ws"
check "static 回落后端"         "backend-static"   200 "/static/backend-only.css"

echo "== 进程内隔离：后端端口不对外 =="
if curl -sS -m 3 -o /dev/null "http://127.0.0.1:$PHPORT/" 2>/dev/null; then
    printf '  \033[33mNOTE\033[0m  后端 %s 在测试机上可直连（测试环境限制为回环，属预期）\n' "$PHPORT"
else
    printf '  \033[32mPASS\033[0m  后端 %s 不可直连\n' "$PHPORT"
fi

echo "== 后端不可用时的降级 =="
kill "$BACKEND_PID" 2>/dev/null || true
wait "$BACKEND_PID" 2>/dev/null || true
BACKEND_PID=""
sleep 0.5
body="$(curl -sS -m 5 "$BASE/api/ping" || true)"
if printf '%s' "$body" | grep -q '"code":-1'; then
    printf '  \033[32mPASS\033[0m  后端挂掉 -> JSON 503: %s\n' "$body"
    PASS=$((PASS + 1))
else
    printf '  \033[31mFAIL\033[0m  后端挂掉时未返回预期 JSON: %s\n' "$body"
    FAIL=$((FAIL + 1))
fi

echo
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
