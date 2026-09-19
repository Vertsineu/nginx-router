Cross-compiled drop-in replacement for the stock OpenWrt `nginx-ssl 1.19.6`,
built for **ImmortalWrt 21.02.6 / aarch64_cortex-a53 / musl**.

Two packages:

- **nginx-ssl 1.31.6-lua** — nginx 1.31.6 with OpenResty Lua (LuaJIT 2.1)
  statically linked in. Binary's only NEEDED entry is `libc.so`. Ships the
  lua-resty-core + lrucache tree under `/usr/share/lua/5.1/resty/` and the
  dynamic `ubus_interpreter` module.
- **lua-resty-jwt 0.1.2-3** — `resty.jwt`/`evp`/`hmac`/`string` under
  `/usr/share/lua/5.1/resty/` plus a `cjson.so` symlink at
  `/usr/lib/lua/5.1/cjson.so` so `require "cjson"` resolves via the default
  cpath.

### No `lua_package_path` needed
LuaJIT is compiled with `PREFIX=/usr` (the distro-blessed way, per
`luaconf.h`), which bakes the default `require()` search path to
`/usr/share/lua/5.1` (lua) and `/usr/lib/lua/5.1` (cpath). resty and cjson both
live there, so ngx_lua finds them with zero config. Verified: a minimal
`content_by_lua_block { require "resty.core"; require "resty.jwt" }` with no
`lua_package_*` directives loads both cleanly.

### Install
```sh
opkg install --force-overwrite lua-resty-jwt_0.1.2-3_aarch64_cortex-a53.ipk
opkg install --force-overwrite nginx-ssl_1.31.6-lua_aarch64_cortex-a53.ipk
/etc/init.d/nginx start
```
nginx-ssl's postinst idempotently injects `load_module` for the ubus module
into `/etc/nginx/uci.conf.template` (main context, before `worker_processes`)
and creates the unversioned `.so` symlinks + the ubus socket bridge.

### Verified on router
- `nginx -v` → 1.31.6, NEEDED → libc.so (musl)
- `/cgi-bin/luci/` → LuCI login page (HTTP 403)
- `POST /ubus/` → full service list
- JWT sign/verify (HS256) via default paths → `verified=true`

### Reproduce
`./build/build.sh` (docker) then `./build/make-ipk.sh` — the assembler re-pulls
conffiles + init from the running router, so build on a box that already has
the desired `/etc/nginx/*` layout.
