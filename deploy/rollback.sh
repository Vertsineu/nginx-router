#!/usr/bin/env bash
# ============================================================================
# rollback.sh — restore the stock OpenWrt nginx that was in place before deploy
# ----------------------------------------------------------------------------
# Usage:
#   ./rollback.sh <ssh-host> [backup-binary]
#   e.g.  ./rollback.sh router
#         ./rollback.sh router /tmp/nginx.bak.1789790688   # explicit
#
# If you don't pass a backup, it auto-detects the newest /usr/sbin/nginx.* or
# /tmp/nginx.bak.* on the host.
#
# Restores:
#   * /usr/sbin/nginx           <- backup
#   * uci.conf.template         <- drop the load_module line (module was ours)
#   * removes /usr/lib/nginx/modules/ngx_http_ubus_module.so
#   * keeps the .so symlinks + rc.local (harmless, and needed if you re-deploy)
#
# NOTE: the stock 1.19.6 had ubus STATICALLY compiled in, so dropping the
# load_module line returns it to its original behavior.
# ============================================================================
set -euo pipefail

HOST="${1:?usage: rollback.sh <ssh-host> [backup-binary]}"
BACKUP="${2:-}"

echo ">> rolling back $HOST"
ssh "$HOST" "
set -e
# 1. find the backup
if [ -n '$BACKUP' ]; then
  BAK='$BACKUP'
else
  BAK=\$(ls -t /usr/sbin/nginx.* /tmp/nginx.bak.* 2>/dev/null | head -1)
fi
[ -n \"\$BAK\" ] || { echo 'no backup binary found'; exit 1; }
echo \">> using backup: \$BAK ( \$(\"\$BAK\" -v 2>&1 | head -1) )\"

# 2. stop, swap binary
/etc/init.d/nginx stop || true
cp -a \"\$BAK\" /usr/sbin/nginx
chmod 755 /usr/sbin/nginx

# 3. drop our load_module line from the template (idempotent)
TPL=/etc/nginx/uci.conf.template
if grep -qF 'load_module /usr/lib/nginx/modules/ngx_http_ubus_module.so;' \"\$TPL\"; then
  sed -i '/load_module \/usr\/lib\/nginx\/modules\/ngx_http_ubus_module.so;/d' \"\$TPL\"
  echo '>> removed load_module from template'
fi

# 4. remove our module (stock build has ubus compiled in)
rm -f /usr/lib/nginx/modules/ngx_http_ubus_module.so

# 5. regenerate live conf + start
/usr/bin/nginx-util init_lan >/dev/null 2>&1 || true
/etc/init.d/nginx start
sleep 2
/usr/sbin/nginx -v 2>&1 | head -1
"
echo ">> rolled back."
