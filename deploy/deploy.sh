#!/usr/bin/env bash
# ============================================================================
# deploy.sh — put the freshly-built nginx (ubus + OpenResty Lua) on the router
# ----------------------------------------------------------------------------
# Assumes you already have ./dist/{nginx,ngx_http_ubus_module.so,resty}
# (run build.sh, or docker build + docker cp — see README).
#
# Usage:
#   ./deploy/deploy.sh <ssh-host>          # e.g. ./deploy/deploy.sh router
#   LUA_TEST_CERT=/path/to.crt ./deploy/deploy.sh router   # custom lua-test cert
#
# Steps (idempotent, backs up the old binary each time):
#   1. stop nginx, back up /usr/sbin/nginx
#   2. unversioned .so symlinks the ubus module's NEEDED wants
#   3. upload nginx -> /usr/sbin/nginx
#   4. upload ubus module -> /usr/lib/nginx/modules/ngx_http_ubus_module.so
#   5. upload resty tree -> /usr/local/share/lua/5.1/resty  (lua-resty-core)
#   6. inject `load_module` into /etc/nginx/uci.conf.template, regenerate
#   7. add a /lua-test endpoint (content_by_lua) — proof Lua runs
#   8. persist the ubus socket symlink in /etc/rc.local
#   9. start nginx + smoke test (HTTP / HTTPS / /ubus / /lua-test)
#
# Rollback: ./deploy/rollback.sh <ssh-host>
# ============================================================================
set -euo pipefail

HOST="${1:?usage: deploy.sh <ssh-host>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$HERE/dist"

NGINX="$DIST/nginx"
MODULE="$DIST/ngx_http_ubus_module.so"
RESTY="$DIST/resty"
MODULE_PATH="/usr/lib/nginx/modules/ngx_http_ubus_module.so"
RESTY_PATH="/usr/local/share/lua/5.1/resty"
# host for the throwaway /lua-test vhost (default = test.local)
LUA_TEST_HOST="${LUA_TEST_HOST:-test.local}"
# cert for the throwaway /lua-test vhost (default = the router's Let's Encrypt cert)
LUA_TEST_CERT="${LUA_TEST_CERT:-/etc/ssl/certs/${LUA_TEST_HOST}.crt}"
LUA_TEST_KEY="${LUA_TEST_KEY:-/etc/ssl/private/${LUA_TEST_HOST}.key}"

[ -x "$NGINX" ]  || { echo "need $NGINX (run build.sh / docker build first)"; exit 1; }
[ -f "$MODULE" ] || { echo "need $MODULE"; exit 1; }
[ -d "$RESTY" ]  || { echo "need $RESTY"; exit 1; }

echo ">> deploying to $HOST"

ssh "$HOST" '
set -e
echo ">> [1/8] stop nginx + back up old binary"
NGINX_BAK="/usr/sbin/nginx.$(date +%Y%m%d%H%M%S)"
/etc/init.d/nginx stop || true
cp -a /usr/sbin/nginx "$NGINX_BAK"
echo "   old binary saved to $NGINX_BAK"
echo ">> [2/8] unversioned .so symlinks (ubus module NEEDED)"
mkdir -p /usr/lib/nginx/modules
[ -e /lib/libubus.so ]       || ln -s /lib/libubus.so.20210630 /lib/libubus.so
[ -e /usr/lib/libjson-c.so ] || ln -s /usr/lib/libjson-c.so.5  /usr/lib/libjson-c.so
'

echo ">> [3/8] upload nginx binary"
ssh "$HOST" 'cat > /usr/sbin/nginx.new && chmod 755 /usr/sbin/nginx.new' < "$NGINX"
ssh "$HOST" 'mv -f /usr/sbin/nginx.new /usr/sbin/nginx'

echo ">> [4/8] upload ubus module"
ssh "$HOST" "cat > $MODULE_PATH && chmod 755 $MODULE_PATH" < "$MODULE"

echo ">> [5/8] upload resty tree (lua-resty-core + lrucache)"
# tar the pure-Lua tree and stream it; untar on the router
tar -C "$DIST" -czf - resty | ssh "$HOST" "rm -rf $RESTY; mkdir -p $(dirname $RESTY); tar -C $(dirname $RESTY) -xzf -"
ssh "$HOST" "echo '   resty files on router: \$(find $RESTY -type f | wc -l)'"

echo ">> [6/8] inject load_module into uci.conf.template (idempotent)"
ssh "$HOST" '
set -e
TPL=/etc/nginx/uci.conf.template
if ! grep -qF "load_module /usr/lib/nginx/modules/ngx_http_ubus_module.so;" "$TPL"; then
  sed -i "/^worker_processes/i\\tload_module /usr/lib/nginx/modules/ngx_http_ubus_module.so;" "$TPL"
  echo "   added load_module line"
else
  echo "   load_module already present"
fi
/usr/bin/nginx-util init_lan >/dev/null 2>&1 || true
grep -qF "load_module" /var/lib/nginx/uci.conf && echo "   uci.conf regenerated with load_module"
'

echo ">> [7/8] add /lua-test vhost (content_by_lua proof)"
# Write the vhost to a local temp file via a plain (unquoted) heredoc: it
# expands $LUA_TEST_CERT / $LUA_TEST_KEY, and the Lua double-quotes stay
# literal (a heredoc body isn't parsed by bash, so nesting them inside an
# ssh "..." string — which bit us before — is avoided entirely).
VHOST_TMP="$(mktemp)"
cat > "$VHOST_TMP" <<LUAEOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${LUA_TEST_HOST};
    ssl_certificate     $LUA_TEST_CERT;
    ssl_certificate_key $LUA_TEST_KEY;
    location /lua-test {
        content_by_lua_block {
            local ffi = require "ffi"
            ffi.cdef[[size_t strlen(const char*);]]
            local core = require "resty.core"
            ngx.header["Content-Type"] = "text/plain"
            ngx.say("ngx_lua OK; ffi strlen(ubus)="..tostring(ffi.C.strlen("ubus")).."; resty.core="..tostring(core ~= nil))
        }
    }
    location / { return 200 "lua-test vhost"; }
}
LUAEOF
ssh "$HOST" "cat > /etc/nginx/conf.d/lua-test.conf" < "$VHOST_TMP"
rm -f "$VHOST_TMP"
echo "   wrote /etc/nginx/conf.d/lua-test.conf"

echo ">> [8/8] persist ubus socket symlink in /etc/rc.local"
ssh "$HOST" '
# Merge (idempotent): keep existing rc.local body, ensure our 2 lines are present.
cat > /etc/rc.local <<"RCEOF"
#!/bin/sh
# ubus module expects /var/run/ubus/ubus.sock; ubusd actually makes /var/run/ubus.sock
mkdir -p /var/run/ubus
ln -sf /var/run/ubus.sock /var/run/ubus/ubus.sock
exit 0
RCEOF
chmod +x /etc/rc.local
mkdir -p /var/run/ubus
ln -sf /var/run/ubus.sock /var/run/ubus/ubus.sock
'

echo ">> start + smoke test"
ssh "$HOST" '
set -e
/usr/sbin/nginx -t 2>&1 | grep -v deprecat | tail -2
/etc/init.d/nginx start
sleep 2
/usr/sbin/nginx -v 2>&1 | head -1
echo -n "   GET  /         -> "; curl -s  -o /dev/null -w "%{http_code}\n"             http://127.0.0.1/
echo -n "   HTTPS /       -> "; curl -sk -o /dev/null -w "%{http_code} (http/%{http_version})\n" https://127.0.0.1/
echo -n "   POST /ubus    -> "; curl -sk -o /dev/null -w "%{http_code}\n" -X POST -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"list\",\"params\":[]}" https://127.0.0.1/ubus
echo -n "   GET /lua-test -> "; curl -sk -H "Host: ${LUA_TEST_HOST}" https://127.0.0.1/lua-test; echo
'
echo ">> done. (rollback: $HERE/deploy/rollback.sh $HOST)"
