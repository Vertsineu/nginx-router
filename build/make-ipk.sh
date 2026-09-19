#!/usr/bin/env bash
#
# build/make-ipk.sh — assemble and package the OpenWrt .ipk from dist/ artifacts.
#
# This ImmortalWrt 21.02.6 (aarch64_cortex-a53) build expects the .ipk to be a
# gzip-compressed *tar* containing three `./`-prefixed members:
#     ./debian-binary
#     ./data.tar.gz
#     ./control.tar.gz
# ...NOT a GNU `ar` archive. (Verified against the stock `ca-bundle` ipk:
# its magic bytes are 1f 8b 08 00 = gzip, and `tar -tzf` lists the three
# members.) An `ar`-built ipk is rejected with "Malformed package file".
#
# Inputs:
#   dist/nginx                          cross-built nginx binary
#   dist/ngx_http_ubus_module.so        dynamic ubus_interpreter module
#   dist/resty/                         lua-resty-core + lua-resty-lrucache
#   ROUTER (ssh alias, default: router)  source of /etc/nginx/* conffiles +
#                                        /etc/init.d/nginx
#
# Output:
#   dist/nginx-ssl_1.31.6-lua_aarch64_cortex-a53.ipk
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.31.6-lua"
ARCH="aarch64_cortex-a53"
PKGNAME="nginx-ssl"
OUT="$(pwd)/dist/${PKGNAME}_${VERSION}_${ARCH}.ipk"
STAGE="$(pwd)/build/.ipkstage"
ROUTER="${ROUTER:-router}"

for f in dist/nginx dist/ngx_http_ubus_module.so dist/resty; do
  [ -e "$f" ] || { echo "missing $f — run build.sh first" >&2; exit 1; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE/data/etc/nginx" "$STAGE/data/etc/init.d" \
         "$STAGE/data/usr/sbin" "$STAGE/data/usr/lib/nginx/modules" \
         "$STAGE/data/usr/share/lua/5.1" "$STAGE/control"

# --- control: the hand-written manifest + lifecycle scripts -----------------
cp ipk/control/* "$STAGE/control/"
chmod 755 "$STAGE/control/"{preinst,postinst,prerm,postrm}

# --- data: binaries + resty tree -------------------------------------------
cp dist/nginx                            "$STAGE/data/usr/sbin/nginx"
cp dist/ngx_http_ubus_module.so          "$STAGE/data/usr/lib/nginx/modules/"
cp -r dist/resty                         "$STAGE/data/usr/share/lua/5.1/resty"
chmod 755 "$STAGE/data/usr/sbin/nginx" \
          "$STAGE/data/usr/lib/nginx/modules/ngx_http_ubus_module.so"

# --- data: conffiles + init script pulled from the running router -----------
# (mime.types, naxsi_core.rules, fastcgi_params, uwsgi_params, koi-*, win-utf,
#  and the stock /etc/init.d/nginx that knows how to start via nginx-util.)
echo "pulling conffiles + init from ${ROUTER}..."
ssh "$ROUTER" 'cat /etc/init.d/nginx' > "$STAGE/data/etc/init.d/nginx"
chmod 755 "$STAGE/data/etc/init.d/nginx"
for cf in mime.types naxsi_core.rules fastcgi_params uwsgi_params \
          koi-utf koi-win win-utf; do
  ssh "$ROUTER" "cat /etc/nginx/$cf" > "$STAGE/data/etc/nginx/$cf"
done

# --- inner control.tar.gz (./ prefixed) -------------------------------------
( cd "$STAGE/control" && tar -czf "$STAGE/control.tar.gz" . )

# --- inner data.tar.gz (./ prefixed) ----------------------------------------
( cd "$STAGE/data"   && tar -czf "$STAGE/data.tar.gz" . )

# --- outer: gzip(tar) of the three members, in stock order ------------------
printf '2.0\n' > "$STAGE/debian-binary"
( cd "$STAGE" && tar -czf "$OUT" ./debian-binary ./data.tar.gz ./control.tar.gz )

echo "built: $OUT"
ls -la "$OUT"
