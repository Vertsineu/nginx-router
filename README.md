# nginx-router

**nginx 1.31.6** (aarch64 / musl) with:
- the **OpenWrt `ubus` dynamic module**, and
- **OpenResty Lua** — `lua-nginx-module` + `LuaJIT 2.1` (statically linked) +
  `lua-resty-core`/`lua-resty-lrucache` (pure Lua, shipped to the router)

for an OpenWrt (musl) aarch64 router.

This is a **recipe**, not a prebuilt binary. It pins every upstream to an
exact version/commit (`versions.lock`) and a single `build.sh` rebuilds the
same artifacts:

```
dist/nginx                        # ~9.5 MB, NEEDED: libc.so only
dist/ngx_http_ubus_module.so      # 23 KB, NEEDED: libubus/libubox/libblobmsg_json/libjson-c/libc
dist/resty/                       # lua-resty-core + lrucache (pure Lua)
```

Why this split:
- **pcre2 / openssl / zlib / LuaJIT are statically linked into `nginx`** → the
  binary is self-contained; deploying it touches *no* router shared libs.
- **ubus is a dynamic module** that dlopens the router's *existing*
  `libubus.so.20210630` / `libubox.so.20210516` / `libblobmsg_json.so.20210516`
  / `libjson-c.so.5`. Those `.so` files are vendored in `vendor/` so the
  build links against the exact ABI the router runs — no `libubus` package
  reinstall, no glibc/musl mismatch.
- **resty.core is pure Lua** and version-locked to the exact ngx_lua version
  (see *The traps*, #10). It's deployed as a file tree, not compiled in.

---

## Build (one command)

```sh
docker build -f Dockerfile -t nginx-router .
docker run --rm --name nginx-router nginx-router
docker cp nginx-router:/work/dist/nginx               ./dist/nginx
docker cp nginx-router:/work/dist/ngx_http_ubus_module.so ./dist/
docker cp nginx-router:/work/dist/resty             ./dist/resty
```

`build.sh` runs all stages and ends with a **qemu smoke test** that actually
starts the cross-built binary, then curls `GET /` (expect 200), `POST /ubus`
(expect 200), and `GET /lua` (expect `qemu-lua OK; … resty.core=true`) —
proving LuaJIT + lua-nginx-module + resty.core all run.

Bare-metal (Debian x86_64) without docker: install the same prereqs the
Dockerfile does, then `./build/build.sh`.

## Reproducibility

`versions.lock` pins every upstream (tarball SHA256 + git commit) and the
build timestamp, so the build is deterministic **within a checkout**: two
from-scratch builds of the same tree produce a byte-identical `nginx`
(verified: same md5, same size). The levers that make this true:

- **`SOURCE_DATE_EPOCH`** — OpenSSL's `crypto/buildinf.h` bakes
  `built on: <time>` into the binary; pinning this env var freezes it.
- **`BUILD_ROOT`** — all dep install prefixes (zlib/pcre2/openssl/LuaJIT)
  live under one fixed root, so the `OPENSSLDIR`/`ENGINESDIR`/`MODULESDIR`
  strings OpenSSL bakes into `.rodata` are stable. Defaults to `<checkout>/src/out`.

**Across checkouts** (e.g. `git clone` into a different directory) the only
byte difference is that `OPENSSLDIR` path string — the binary is still
functionally identical (same `NEEDED`, same behavior, ubus module
byte-identical, resty tree identical). To make *that* byte-identical too,
build from the same directory:

```sh
BUILD_ROOT=/opt/nginx-build ./build/build.sh
```

Every artifact's `NEEDED` is stable and small: `nginx` → `libc.so` only;
`ngx_http_ubus_module.so` → the router's 4 `.so` + `libc.so`.

## Deploy

```sh
./deploy/deploy.sh <ssh-host>      # e.g. ./deploy/deploy.sh router
```

It: backs up the old binary → uploads `nginx` + the ubus module + the **resty
Lua tree** → injects `load_module` into `/etc/nginx/uci.conf.template` →
regenerates the live conf via `nginx-util init_lan` → adds the two unversioned
`.so` symlinks → drops a `/lua-test` vhost (proof `content_by_lua` runs) →
persists the ubus socket symlink in `/etc/rc.local` → restarts and smoke-tests
HTTP / HTTPS / `/ubus` / `/lua-test`.

## Rollback

```sh
./deploy/rollback.sh <ssh-host> [backup-binary]
```

Restores the stock OpenWrt nginx (its ubus is compiled in, so it drops the
`load_module` line, our `.so`, the `/lua-test` vhost, and the resty tree).

---

## The traps (why build.sh is the way it is)

These all cost real debugging time; they're the whole point of pinning.

1. **musl, not glibc.** The router is musl. Use the `musl.cc` aarch64 cross
   toolchain (`aarch64-linux-musl-gcc`), *not* `aarch64-linux-gnu` (glibc).

2. **nginx's `./configure` *executes* test binaries.** On an x86 host that
   needs `qemu-user-static` + `binfmt-support`. musl's loader is `libc.so`
   itself, so build a tiny rootfs and `export QEMU_LD_PREFIX=$ROOTFS` —
   otherwise every test fails with `Could not open /lib/ld-musl-aarch64.so.1`.

3. **zlib's `configure` ignores the `CC=` *argument*.** Pass it as an
   **environment variable**: `CC=$CROSS/bin/...-gcc ./configure ...`.
   (The classic silent x86-vs-aarch64 bug.)

4. **Static pcre2.** pcre2 builds both `.a` and `.so`; move the `.so` family
   out of `lib/` so nginx links the `.a` and `NEEDED` stays just `libc.so`.

5. **`-Werror` vs. old OpenWrt headers.** GCC 11 promotes signedness warnings
   in `libubox`/the ubus module to errors. Turn them off *surgically*:
   `-Wno-error=pointer-sign -Wno-error=sign-compare -Wno-error=return-type
   -Wno-error=unused-variable -Wno-error=pointer-arith`.

6. **json-c's `json.h` is a CMake template.** Fill `@JSON_H_JSON_PATCH@` /
   `@JSON_H_JSON_POINTER@` by hand and synthesize a minimal `json_config.h`
   (define `JSON_C_HAVE_INTTYPES_H` so `json_inttypes.h` doesn't clash with
   musl's `inttypes.h`).

7. **The ubus module needs the router's `.so`, unversioned.** Its `NEEDED`
   entries are `libubus.so` / `libjson-c.so` (no version) but the router ships
   `libubus.so.20210630` / `libjson-c.so.5`. Create the two symlinks (deploy.sh
   step 2). Linking is done against the vendored `.so` so the ABI matches.

8. **Path conventions.** Build with `--prefix=/usr --pid-path=/var/run/nginx.pid
   --error-log-path=stderr --modules-path=/usr/lib/nginx/modules
   --conf-path=/etc/nginx/nginx.conf` to match the stock OpenWrt `init.d/nginx`,
   so `reload` (not `restart`) keeps working.

9. **ubus socket path (pre-existing, not ours).** `luci.locations` points the
   module at `/var/run/ubus/ubus.sock` but `ubusd` actually creates
   `/var/run/ubus.sock`. `deploy.sh` bridges it with a symlink in
   `/etc/rc.local`. (The stock 1.19.6 build had this quirk too.)

10. **`resty.core` is version-locked to the exact ngx_lua build.** In
    `lua-nginx-module ≥ v0.10.16`, `ngx_http_lua_init_vm` does an unconditional
    `require("resty.core")`; if it fails the module returns `NGX_DECLINED`, and
    `ngx_http_lua_init` (postconfiguration) turns that into `NGX_ERROR` → the
    **master dies right after a `failed to load the 'resty.core'` alert**. The
    check itself is exact, not `>=`:

    ```lua
    -- resty/core/base.lua
    if ngx.config.ngx_lua_version ~= 10031 then
        error("ngx_http_lua_module 0.10.31 required but got " .. ver)
    end
    ```

    `ngx_lua_version` encodes major*100000 + minor*1000 + patch, so
    **ngx_lua 0.10.31 = 10031**, which needs **lua-resty-core v0.1.34rc3**
    (v0.1.33rc2 wants 10030, master wants 10032). If you bump ngx_lua, bump
    resty-core to the matching tag — mismatch = the master-crash trap.

11. **LuaJIT cross-compile is two-stage.** Its Makefile builds a *host*
    `buildvm` (with `HOST_CC=gcc`) that runs dynasm and emits target-arch C,
    then compiles that with `CROSS=aarch64-linux-musl-`. `BUILDMODE=static`
    yields one `libluajit-5.1.a` we link into nginx. Forgetting `CROSS` gives
    an x86 LuaJIT silently.

---

## Layout

```
versions.lock          # every upstream pinned (shell-sourceable)
build/build.sh         # the reproducible pipeline (zlib, pcre2, openssl,
                       #   LuaJIT, ubus, nginx, resty tree, qemu smoke test)
Dockerfile             # one-command build environment
vendor/*.so            # router's libubus/libubox/libblobmsg_json/libjson-c (ABI-locked)
deploy/deploy.sh       # put the build on the router
deploy/rollback.sh     # restore stock nginx
.gitignore             # src/ + dist/ are build I/O, not committed
```
