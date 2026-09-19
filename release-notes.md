Cross-compiled drop-in replacement for the stock OpenWrt `nginx-ssl 1.19.6`,
built for **ImmortalWrt 21.02.6 / aarch64_cortex-a53 / musl**.

## What's inside
- **nginx 1.31.6** — pcre2 / openssl / zlib / **LuaJIT 2.1** statically linked
  in (the binary's only NEEDED entry is `libc.so`), so it is self-contained.
- **ubus_interpreter dynamic module** — linked against the router's
  libubus/libubox/libblobmsg-json/libjson-c, exposing OpenWrt ubus over HTTP.
- **lua-resty-core + lua-resty-lrucache** under `/usr/local/share/lua/5.1`.
- 7 conffiles + the stock `/etc/init.d/nginx` (starts via nginx-util).

## Install
```sh
opkg install --force-overwrite nginx-ssl_1.31.6-lua_aarch64_cortex-a53.ipk
/etc/init.d/nginx start
```
The postinst idempotently injects `load_module` into
`/etc/nginx/uci.conf.template` (main context, before `worker_processes`) and
creates the unversioned `.so` symlinks + the ubus socket bridge.

## Verified on router
- `nginx -v` → 1.31.6
- `/cgi-bin/luci/` → LuCI login page (HTTP 403, unauthenticated)
- `POST /ubus/` with `{"jsonrpc":"2.0","id":1,"method":"list"}` → full service list
- `/lua-test` (Host: lua.*) → `ngx_lua on router OK; ffi strlen=9`
- opkg deps all `install ok`, no orphans

## Reproduce
`./build/build.sh && ./build/make-ipk.sh` — the assembler re-pulls conffiles
from the running router, so build the ipk on the box that already has the
desired `/etc/nginx/*` layout.
