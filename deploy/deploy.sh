#!/usr/bin/env bash
# ============================================================================
# deploy.sh — put the freshly-built nginx + ubus module on the OpenWrt router
# ----------------------------------------------------------------------------
# Assumes you already have ./dist/nginx and ./dist/ngx_http_ubus_module.so
# (run build.sh, or docker build + docker cp — see README).
#
# Usage:
#   ./deploy/deploy.sh <ssh-host>          # e.g. ./deploy/deploy.sh router
#
# Steps (idempotent, backs up the old binary each time):
#   1. stop nginx, back up /usr/sbin/nginx
#   2. unversioned .so symlinks the module's NEEDED wants
#   3. upload nginx -> /usr/sbin/nginx
#   4. upload module -> /usr/lib/nginx/modules/ngx_http_ubus_module.so
#   5. inject `load_module` into /etc/nginx/uci.conf.template, regenerate
#   6. persist the ubus socket symlink in /etc/rc.local
#   7. start nginx + smoke test (HTTP / HTTPS / /ubus)
#
# Rollback: ./deploy/rollback.sh <ssh-host>
# ============================================================================
set -euo pipefail

HOST="${1:?usage: deploy.sh <ssh-host>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$HERE/dist"

NGINX="$DIST/nginx"
MODULE="$DIST/ngx_http_ubus_module.so"
MODULE_PATH="/usr/lib/nginx/modules/ngx_http_ubus_module.so"

[ -x "$NGINX" ]  || { echo "need $NGINX (run build.sh / docker build first)"; exit 1; }
[ -f "$MODULE" ] || { echo "need $MODULE"; exit 1; }

echo ">> deploying to $HOST"

ssh "$HOST" '
set -e
echo ">> [1/6] stop nginx + back up old binary"
NGINX_BAK="/usr/sbin/nginx.$(date +%Y%m%d%H%M%S)"
/etc/init.d/nginx stop || true
cp -a /usr/sbin/nginx "$NGINX_BAK"
echo "   old binary saved to $NGINX_BAK"
echo ">> [2/6] unversioned .so symlinks (module NEEDED)"
mkdir -p /usr/lib/nginx/modules
[ -e /lib/libubus.so ]       || ln -s /lib/libubus.so.20210630 /lib/libubus.so
[ -e /usr/lib/libjson-c.so ] || ln -s /usr/lib/libjson-c.so.5  /usr/lib/libjson-c.so
'

echo ">> [3/6] upload nginx binary"
ssh "$HOST" 'cat > /usr/sbin/nginx.new && chmod 755 /usr/sbin/nginx.new' < "$NGINX"
ssh "$HOST" 'mv -f /usr/sbin/nginx.new /usr/sbin/nginx'

echo ">> [4/6] upload ubus module"
ssh "$HOST" "cat > $MODULE_PATH && chmod 755 $MODULE_PATH" < "$MODULE"

echo ">> [5/6] inject load_module into uci.conf.template (idempotent)"
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

echo ">> [6/6] persist ubus socket symlink in /etc/rc.local"
ssh "$HOST" '
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
/etc/init.d/nginx start
sleep 2
/usr/sbin/nginx -v 2>&1 | head -1
echo -n "   GET  /     -> "; curl -s  -o /dev/null -w "%{http_code}\n"           http://127.0.0.1/
echo -n "   HTTPS /    -> "; curl -sk -o /dev/null -w "%{http_code} (http/%{http_version})\n" https://127.0.0.1/
echo -n "   POST /ubus -> "; curl -sk -o /dev/null -w "%{http_code}\n" -X POST -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"list\",\"params\":[]}" https://127.0.0.1/ubus
'
echo ">> done. (rollback: $HERE/deploy/rollback.sh $HOST)"
