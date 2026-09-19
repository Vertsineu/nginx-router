#!/usr/bin/env bash
# ============================================================================
# build.sh — cross-build nginx 1.31.6 (aarch64/musl) with:
#   * OpenWrt ubus dynamic module (ngx_http_ubus_module.so)
#   * OpenResty Lua  (LuaJIT 2.1, statically linked + lua-nginx-module)
#   * lua-resty-core + lua-resty-lrucache (pure Lua, deployed to the router)
#
# Produces (in $OUT):
#   nginx                          (static pcre2/openssl/zlib/luajit; NEEDED: libc.so)
#   ngx_http_ubus_module.so        (dynamic, links vendor/*.so)
#   resty/                         (lua-resty-core + lrucache tree)
#
# Target: an OpenWrt musl aarch64 router. Everything is pinned in
# versions.lock so a rebuild yields the same binaries.
#
# Usage (inside the docker container, see Dockerfile):
#   ./build.sh
#
# Or manually on a Debian x86_64 host with the prereqs installed:
#   ./build.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"                # downloads/clones land here (gitignored)
OUT="$ROOT/dist"               # final artifacts (gitignored)
VENDOR="$ROOT/vendor"          # router .so files we dlopen

# --- Load pinned versions ---------------------------------------------------
. "$ROOT/versions.lock"

JOBS="${JOBS:-4}"
CROSS="$SRC/musl-aarch64/aarch64-linux-musl-cross"
CC="$CROSS/bin/aarch64-linux-musl-gcc"

echo ">> building on $JOBS jobs, toolchain=$CC"
mkdir -p "$SRC" "$OUT"
# Make the cross toolchain's bin/ (aarch64-linux-musl-gcc, -strip, binutils)
# visible to every subshell. OpenSSL's `make` (not just `Configure`) needs it,
# so an inline `PATH=… ./Configure` is not enough — export it once, up top.
export PATH="$CROSS/bin:$PATH"
# All dep install prefixes live under one fixed root so the OpenSSL
# OPENSSLDIR/ENGINESDIR/MODULESDIR strings baked into nginx stay stable.
# Default = local to this checkout; override for byte-identical builds
# across machines:  BUILD_ROOT=/opt/nginx-build ./build/build.sh
BUILD_ROOT="${BUILD_ROOT:-$SRC/out}"
# Pin the OpenSSL build-info timestamp (see versions.lock). OpenSSL's
# util/mkbuildinf.pl does gmtime($ENV{SOURCE_DATE_EPOCH} // time()) and bakes
# that into crypto/buildinf.h, which is statically linked into nginx's .rodata.
# Pinning it makes the final nginx byte-for-byte reproducible.
export SOURCE_DATE_EPOCH
echo ">> SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

# ============================================================================
# 0. Fetch musl.cc aarch64 cross toolchain (fixed URL, hashed)
# ============================================================================
if [ ! -x "$CC" ]; then
  echo ">> [0/7] fetching musl.cc cross toolchain"
  curl -sSL -o "$SRC/musl-aarch64.tar.gz" \
    https://musl.cc/aarch64-linux-musl-cross.tgz
  echo "$MUSL_TOOLCHAIN_SHA256  $SRC/musl-aarch64.tar.gz" | sha256sum -c -
  # musl.cc's tgz unpacks to aarch64-linux-musl-cross/ at top level;
  # nest it under $SRC/musl-aarch64/ so $CROSS resolves.
  mkdir -p "$SRC/musl-aarch64"
  tar xzf "$SRC/musl-aarch64.tar.gz" -C "$SRC/musl-aarch64"
fi

# ============================================================================
# 0b. Minimal musl rootfs + QEMU_LD_PREFIX
# ------------------------------------------------------------------
# nginx's ./configure *executes* compiled test binaries. On an x86 host that
# needs qemu-user + binfmt (installed in Dockerfile / by the host). musl's
# dynamic loader is libc.so itself; build a tiny rootfs and point qemu at it.
# ============================================================================
ROOTFS="$SRC/rootfs"
mkdir -p "$ROOTFS/lib"
cp -L "$CROSS/aarch64-linux-musl/lib/libc.so"          "$ROOTFS/lib/libc.so"
cp -L "$ROOTFS/lib/libc.so"                             "$ROOTFS/lib/ld-musl-aarch64.so.1"
cp -L "$CROSS/aarch64-linux-musl/lib/libgcc_s.so.1"     "$ROOTFS/lib/libgcc_s.so.1" 2>/dev/null || true
mkdir -p "$ROOTFS/tmp"
# binfmt passes this through to the qemu-aarch64 interpreter
export QEMU_LD_PREFIX="$ROOTFS"

# ============================================================================
# 1. Fetch + hash the three tarball deps
# ============================================================================
echo ">> [1/7] fetching nginx/openssl/zlib"
[ -f "$SRC/nginx-$NGINX_VERSION.tar.gz" ] || curl -sSL -o "$SRC/nginx-$NGINX_VERSION.tar.gz" "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
[ -f "$SRC/openssl-$OPENSSL_VERSION.tar.gz" ] || curl -sSL -o "$SRC/openssl-$OPENSSL_VERSION.tar.gz" "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
[ -f "$SRC/zlib-$ZLIB_VERSION.tar.gz" ] || curl -sSL -o "$SRC/zlib-$ZLIB_VERSION.tar.gz" "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz"
# sha256sum -c wants "<hash>␣␣<file>" (space + text-mode flag). printf locks it.
printf '%s  %s\n' "$NGINX_SHA256"   "$SRC/nginx-$NGINX_VERSION.tar.gz"   | sha256sum -c -
printf '%s  %s\n' "$OPENSSL_SHA256" "$SRC/openssl-$OPENSSL_VERSION.tar.gz" | sha256sum -c -
printf '%s  %s\n' "$ZLIB_SHA256"    "$SRC/zlib-$ZLIB_VERSION.tar.gz"      | sha256sum -c -
tar xzf "$SRC/nginx-$NGINX_VERSION.tar.gz"   -C "$SRC"
tar xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$SRC"
tar xzf "$SRC/zlib-$ZLIB_VERSION.tar.gz"      -C "$SRC"

# ============================================================================
# 2. Git-clone the OpenWrt-side deps at pinned commits
# ============================================================================
echo ">> [2/7] cloning pcre2 / ubus / libubox / json-c / ngx-ubus"
clone() { # name url sha
  local n="$1" u="$2" s="$3"
  if [ -d "$SRC/$n/.git" ]; then
    git -C "$SRC/$n" fetch --quiet origin "$s" && git -C "$SRC/$n" checkout --quiet "$s"
  else
    git clone --quiet "$u" "$SRC/$n"
    git -C "$SRC/$n" checkout --quiet "$s"
  fi
}
clone pcre2   "https://github.com/PCRE2Project/pcre2.git"                 "$PCRE2_SHA"
clone ubus-repo "https://git.openwrt.org/project/ubus.git"                "$UBUS_SHA"
clone ubox-repo "https://git.openwrt.org/project/libubox.git"             "$UBOX_SHA"
clone jsonc   "https://github.com/json-c/json-c.git"                      "$JSONC_SHA"
clone ngx-ubus "https://github.com/Ansuel/nginx-ubus-module.git"          "$NGX_UBUS_SHA"
# OpenResty / Lua side
clone lua-nginx-module "https://github.com/openresty/lua-nginx-module.git" "$NGX_LUA_SHA"
clone luajit   "https://github.com/openresty/luajit2.git"                 "$LUAJIT_SHA"
clone resty-core "https://github.com/openresty/lua-resty-core.git"        "$RESTY_CORE_SHA"
clone resty-lrucache "https://github.com/openresty/lua-resty-lrucache.git" "$RESTY_LRU_CACHE_SHA"

# pcre2 ships configure.ac, not configure -> autogen (needs autoconf/automake/libtool)
if [ ! -x "$SRC/pcre2/configure" ]; then
  (cd "$SRC/pcre2" && ./autogen.sh)
fi

# ============================================================================
# 3. Build STATIC zlib  (NOTE: zlib's configure ignores `CC=` arg; use env var)
# ============================================================================
echo ">> [3/7] static zlib"
(
  cd "$SRC/zlib-$ZLIB_VERSION"
  make distclean >/dev/null 2>&1 || true
  CC="$CC" ./configure --prefix="$BUILD_ROOT/zlib" --static
  make -j"$JOBS"
  make install >/dev/null
)

# ============================================================================
# 4. Build STATIC pcre2 (8-bit only, no JIT -> tiny)
# ============================================================================
echo ">> [4/7] static pcre2"
(
  cd "$SRC/pcre2"
  make distclean >/dev/null 2>&1 || true
  CC="$CC" ./configure --prefix="$BUILD_ROOT/pcre2" --host=aarch64-linux-musl \
    --disable-cpp --disable-pcre2-16 --disable-pcre2-32 --enable-pcre2-8 \
    --disable-jit --disable-unicode-properties --disable-newline-eat-semi
  make -j"$JOBS"
  make install >/dev/null
  # Force nginx to link the .a (not the .so) so NEEDED stays just libc.so
  mkdir -p "$BUILD_ROOT/pcre2/lib/.so-bak"
  mv "$BUILD_ROOT/pcre2/lib/"libpcre2-8.so* \
     "$BUILD_ROOT/pcre2/lib/"libpcre2-posix.so* \
     "$BUILD_ROOT/pcre2/lib/"*.la \
     "$BUILD_ROOT/pcre2/lib/.so-bak/" 2>/dev/null || true
)

# ============================================================================
# 5. Build STATIC openssl (musl linux-aarch64, no apps)
# ============================================================================
echo ">> [5/7] static openssl"
(
  cd "$SRC/openssl-$OPENSSL_VERSION"
  make distclean >/dev/null 2>&1 || ./config clean >/dev/null 2>&1 || true
  PATH="$CROSS/bin:$PATH" ./Configure linux-aarch64 \
    --prefix="$BUILD_ROOT/openssl" \
    --openssldir="$BUILD_ROOT/openssl/ssl" \
    --cross-compile-prefix=aarch64-linux-musl- \
    no-shared no-async no-tests no-dso no-apps -static
  make -j"$JOBS" build_libs
  make install_sw >/dev/null
)

# ============================================================================
# 6. Assemble ubus module include tree + inject paths into its config
# ============================================================================
echo ">> [6/7] ubus module headers + config"
UBUSINC="$SRC/ubus-include"
UBUSLIB="$SRC/ubus-libs"
rm -rf "$UBUSINC" "$UBUSLIB"
mkdir -p "$UBUSINC/libubox" "$UBUSINC/json-c" "$UBUSLIB"

# libubus.h + its internal headers (ubusmsg.h etc.) live at repo root
cp "$SRC/ubus-repo/"*.h "$UBUSINC/"
# libubox headers (repo root) -> libubox/ subdir (module does #include <libubox/x.h>)
for h in blob.h blobmsg.h blobmsg_json.h avl.h avl-cmp.h ulog.h uloop.h \
         ustream.h usock.h utils.h list.h vlist.h kvlist.h assert.h \
         safe_list.h runqueue.h udebug.h udebug-priv.h udebug-proto.h json_script.h; do
  [ -f "$SRC/ubox-repo/$h" ] && cp "$SRC/ubox-repo/$h" "$UBUSINC/libubox/$h"
done
# json-c: umbrella json.h is a cmake template; fill its two vars
for h in "$SRC/jsonc/"*.h; do
  base="$(basename "$h")"
  if [ "$base" = "json.h" ]; then
    : # handled below
  else
    cp "$h" "$UBUSINC/json-c/$base"
  fi
done
sed -e 's/@JSON_H_JSON_PATCH@/#include "json_patch.h"/' \
    -e 's/@JSON_H_JSON_POINTER@/#include "json_pointer.h"/' \
    "$SRC/jsonc/json.h.cmakein" > "$UBUSINC/json-c/json.h"
# json_config.h (cmake-generated on a normal build) — synthesize the minimal one
cat > "$UBUSINC/json-c/json_config.h" <<'EOF'
#ifndef JSON_CONFIG_H
#define JSON_CONFIG_H
#define PACKAGE_VERSION "0.15"
#define JSON_C_HAVE_INTTYPES_H 1
#define HAVE_STDARG_PROTOTYPES 1
#endif
EOF

# Pull the router .so files we'll dlopen (vendored) and symlink unversioned
for so in $UBUS_LIBS; do
  cp -L "$VENDOR/$so" "$UBUSLIB/$so"
done
# Module's NEEDED entries are unversioned (libubus.so, libjson-c.so) -> symlinks
ln -sf libubus.so.20210630       "$UBUSLIB/libubus.so"
ln -sf libubox.so.20210516       "$UBUSLIB/libubox.so"
ln -sf libblobmsg_json.so.20210516 "$UBUSLIB/libblobmsg_json.so"
ln -sf libjson-c.so.5            "$UBUSLIB/libjson-c.so"

# Rewrite the ubus module's nginx `config` deterministically (idempotent):
# point -L at our vendored router .so and -I at the assembled header tree.
python3 - "$SRC/ngx-ubus/config" "$UBUSLIB" "$UBUSINC" <<'PY'
import sys,re
p,lib,inc=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(r'^ngx_module_libs=.*$','ngx_module_libs="-L'+lib+' -lubus -lubox -lblobmsg_json -ljson-c -lpthread"',s,flags=re.M)
s=re.sub(r'^ngx_module_incs=.*$','ngx_module_incs="'+inc+' $ngx_addon_dir/src"',s,flags=re.M)
open(p,'w').write(s)
PY

# ============================================================================
# 6b. Cross-build STATIC LuaJIT (aarch64/musl)
# ------------------------------------------------------------------
# LuaJIT's Makefile has native cross-compile support:
#   HOST_CC  = build the host-side "buildvm" (runs on the x86 build box)
#   CROSS=   = prefix for the target CC/AR/STRIP (aarch64-linux-musl-)
# BUILDMODE=static -> a single libluajit-5.1.a we link into nginx.
# ============================================================================
echo ">> [6b/8] static LuaJIT"
LUAJIT_PREFIX="$BUILD_ROOT/luajit"
(
  cd "$SRC/luajit/src"
  make clean >/dev/null 2>&1 || true
  make BUILDMODE=static \
       CROSS=aarch64-linux-musl- \
       HOST_CC="gcc" \
       PREFIX="$LUAJIT_PREFIX" \
       -j"$JOBS"
)
# `make install` lays out headers (include/luajit-2.1) + lib (lib/libluajit-5.1.a)
( cd "$SRC/luajit" && make install PREFIX="$LUAJIT_PREFIX" >/dev/null )
LUAJIT_LIB="$LUAJIT_PREFIX/lib"
LUAJIT_INC="$LUAJIT_PREFIX/include/luajit-2.1"
[ -f "$LUAJIT_LIB/libluajit-5.1.a" ] || { echo "   !! libluajit-5.1.a missing"; exit 1; }
echo "   LuaJIT -> $LUAJIT_LIB/libluajit-5.1.a"

# ============================================================================
# 7. Configure + build nginx (static deps, dynamic ubus module)
# ============================================================================
echo ">> [7/7] nginx $NGINX_VERSION"
PFX="$BUILD_ROOT/nginx"
(
  cd "$SRC/nginx-$NGINX_VERSION"
  make distclean >/dev/null 2>&1 || true
  # lua-nginx-module discovers LuaJIT via these env vars (its `config` adds
  # -I$LUAJIT_INC -L$LUAJIT_LIB -lluajit-5.1 -lm automatically)
  export LUAJIT_LIB="$LUAJIT_LIB"
  export LUAJIT_INC="$LUAJIT_INC"
  ./configure \
    --prefix=/usr \
    --conf-path=/etc/nginx/nginx.conf \
    --modules-path=/usr/lib/nginx/modules \
    --error-log-path=stderr \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/lock/nginx.lock \
    --http-log-path=/var/log/nginx/access.log \
    --with-cc="$CC" \
    --with-cc-opt="-I$BUILD_ROOT/pcre2/include -I$BUILD_ROOT/openssl/include -I$BUILD_ROOT/zlib/include -I$LUAJIT_INC -L$CROSS/aarch64-linux-musl/lib \
      -Wno-error=pointer-sign -Wno-error=sign-compare -Wno-error=return-type \
      -Wno-error=unused-variable -Wno-error=pointer-arith" \
    --with-ld-opt="-L$BUILD_ROOT/pcre2/lib -L$BUILD_ROOT/openssl/lib -L$BUILD_ROOT/zlib/lib -L$LUAJIT_LIB \
      -L$CROSS/aarch64-linux-musl/lib -Wl,-rpath-link,$CROSS/aarch64-linux-musl/lib \
      -Wl,-Bstatic -lpcre2-8 -lssl -lcrypto -lz -lluajit-5.1 -Wl,-Bdynamic -lm" \
    --add-module="$SRC/lua-nginx-module" \
    --add-dynamic-module="$SRC/ngx-ubus" \
    --with-http_ssl_module --with-http_v2_module --with-http_gzip_static_module \
    --with-http_realip_module --with-http_stub_status_module --with-http_dav_module \
    --with-http_addition_module --with-http_sub_module --with-http_gunzip_module \
    --with-http_mp4_module --with-http_random_index_module
  make -j"$JOBS"
)

# --- strip + emit final artifacts -------------------------------------------
"$CROSS/bin/aarch64-linux-musl-strip" -o "$OUT/nginx" "$SRC/nginx-$NGINX_VERSION/objs/nginx"
"$CROSS/bin/aarch64-linux-musl-strip" -o "$OUT/ngx_http_ubus_module.so" "$SRC/nginx-$NGINX_VERSION/objs/ngx_http_ubus_module.so"

# --- assemble the pure-Lua resty tree (resty.core + resty.lrucache) ---------
# Deployed to /usr/local/share/lua/5.1/resty on the router. LuaJIT's default
# lua_package_path already searches there, so no lua_package_path directive is
# needed (verified on both qemu and the real router).
RESTY_OUT="$OUT/resty"
rm -rf "$RESTY_OUT"; mkdir -p "$RESTY_OUT"
cp "$SRC/resty-core/lib/resty/core.lua"       "$RESTY_OUT/"
cp -r "$SRC/resty-core/lib/resty/core"        "$RESTY_OUT/"
cp "$SRC/resty-lrucache/lib/resty/lrucache.lua" "$RESTY_OUT/"
[ -d "$SRC/resty-lrucache/lib/resty/lrucache" ] && cp -r "$SRC/resty-lrucache/lib/resty/lrucache" "$RESTY_OUT/"
find "$RESTY_OUT" -name "*.md" -delete
echo "   resty tree -> $RESTY_OUT ($(find "$RESTY_OUT" -type f | wc -l) files)"

echo
echo ">> DONE. Artifacts in $OUT :"
ls -la "$OUT"
echo
echo "   nginx NEEDED:";  readelf -d "$OUT/nginx" | grep NEEDED
echo "   module NEEDED:"; readelf -d "$OUT/ngx_http_ubus_module.so" | grep NEEDED
echo "   nginx -v:";       "$OUT/nginx" -v 2>&1

# ============================================================================
# 8. Smoke test: actually run the cross-built binary under qemu-user
# ------------------------------------------------------------------
# Verifies it serves HTTP and the ubus module dlopens (against the vendored
# .so), without needing the real router.
# ============================================================================
echo
echo ">> [8/8] smoke test (qemu-aarch64)"
if command -v qemu-aarch64 >/dev/null 2>&1; then
  # Stage a mini runtime under rootfs: loader + vendored .so + module
  mkdir -p "$ROOTFS/lib/nginx/modules" "$ROOTFS/usr/logs" "$ROOTFS/usr/client_body_temp" \
           "$ROOTFS/usr/proxy_temp" "$ROOTFS/usr/fastcgi_temp" "$ROOTFS/usr/uwsgi_temp" \
           "$ROOTFS/usr/scgi_temp" "$ROOTFS/www"
  cp -L "$VENDOR/libubus.so.20210630"        "$ROOTFS/lib/libubus.so.20210630"
  cp -L "$VENDOR/libubox.so.20210516"        "$ROOTFS/lib/libubox.so.20210516"
  cp -L "$VENDOR/libblobmsg_json.so.20210516" "$ROOTFS/lib/libblobmsg_json.so.20210516"
  cp -L "$VENDOR/libjson-c.so.5"             "$ROOTFS/lib/libjson-c.so.5"
  ln -sf libubus.so.20210630        "$ROOTFS/lib/libubus.so"
  ln -sf libubox.so.20210516        "$ROOTFS/lib/libubox.so"
  ln -sf libblobmsg_json.so.20210516 "$ROOTFS/lib/libblobmsg_json.so"
  ln -sf libjson-c.so.5             "$ROOTFS/lib/libjson-c.so"
  cp "$OUT/ngx_http_ubus_module.so" "$ROOTFS/lib/nginx/modules/"
  echo "smoke page" > "$ROOTFS/www/index.html"
  # stage the pure-Lua resty tree where LuaJIT's default package path looks
  mkdir -p "$ROOTFS/usr/local/share/lua/5.1"
  cp -r "$OUT/resty" "$ROOTFS/usr/local/share/lua/5.1/resty"

  SMOKE="$SRC/smoke"; rm -rf "$SMOKE"; mkdir -p "$SMOKE/tmp"
  cat > "$SMOKE/nginx.conf" <<EOF
worker_processes 1;
pid /$SMOKE/smoke.pid;
error_log /$SMOKE/error.log;
load_module /lib/nginx/modules/ngx_http_ubus_module.so;
events { worker_connections 64; }
http {
  client_body_temp_path $SMOKE/tmp/cb;
  proxy_temp_path       $SMOKE/tmp/pr;
  fastcgi_temp_path     $SMOKE/tmp/fc;
  uwsgi_temp_path       $SMOKE/tmp/uw;
  scgi_temp_path        $SMOKE/tmp/sc;
  access_log off;
  server {
    listen 127.0.0.1:8900;
    root /www;
    location / { try_files \$uri \$uri/ =404; }
    location /ubus { ubus_interpreter; ubus_socket_path /var/run/ubus.sock; ubus_noauth on; }
    location /lua {
      content_by_lua_block {
        local ffi = require "ffi"
        ffi.cdef[[size_t strlen(const char*);]]
        local core = require "resty.core"
        ngx.say("qemu-lua OK; strlen=", tostring(ffi.C.strlen("aarch64")), "; resty.core=", tostring(core ~= nil))
      }
    }
  }
}
EOF
  mkdir -p "$ROOTFS/var/run"
  # nginx -t must pass (catches load_module + ubus directives)
  ( cd "$SMOKE" && qemu-aarch64 -L "$ROOTFS" "$OUT/nginx" -t -c "$SMOKE/nginx.conf" ) 2>&1 | grep -v "deprecat"
  # clear a stale qemu nginx from a previous run so port 8900 is free
  pkill -f "qemu-aarch64.*$OUT/nginx" 2>/dev/null || true
  sleep 1
  # start (background) and curl it
  ( cd "$SMOKE" && qemu-aarch64 -L "$ROOTFS" "$OUT/nginx" -c "$SMOKE/nginx.conf" ) >/dev/null 2>&1 &
  smoke_pid=$!
  sleep 2
  # nginx listens on the *guest's* 127.0.0.1:8900; with qemu-user + shared net
  # namespace it is reachable on the host 127.0.0.1:8900
  code_http= code_ubus= body_lua=
  code_http=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8900/ 2>/dev/null || echo 000)
  code_ubus=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
     -d '{"jsonrpc":"2.0","id":1,"method":"list","params":[]}' \
     http://127.0.0.1:8900/ubus 2>/dev/null || echo 000)
  body_lua=$(curl -s http://127.0.0.1:8900/lua 2>/dev/null || echo "")
  kill "$smoke_pid" 2>/dev/null || true
  echo "   GET  /     -> $code_http  (expect 200)"
  echo "   POST /ubus -> $code_ubus  (expect 200; no ubusd here so list may be {})"
  echo "   GET  /lua  -> $body_lua"
  ok="   SMOKE OK"
  [ "$code_http" != "200" ] && ok="   SMOKE: http not 200 (check netns)"
  echo "$body_lua" | grep -q "qemu-lua OK" || ok="   SMOKE: lua not OK"
  echo "$ok"
else
  echo "   (qemu-aarch64 not found — skipping runtime smoke test; -V still works)"
  "$OUT/nginx" -v 2>&1
fi

echo
echo ">> build.sh complete. Artifacts in: $OUT"
