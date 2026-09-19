# nginx-router

Reproducible cross-build of **nginx 1.31.6** (aarch64 / musl) plus the
**OpenWrt `ubus` dynamic module**, for an OpenWrt (musl) aarch64 router.

This is a **recipe**, not a prebuilt binary. It pins every upstream to an
exact version/commit (`versions.lock`) and a single `build.sh` rebuilds the
same two artifacts:

```
dist/nginx                        # 8.5 MB, NEEDED: libc.so only
dist/ngx_http_ubus_module.so      # 23 KB, NEEDED: libubus/libubox/libblobmsg_json/libjson-c/libc
```

Why this split:
- **pcre2 / openssl / zlib are statically linked into `nginx`** → the binary
  is self-contained; deploying it touches *no* router shared libs.
- **ubus is a dynamic module** that dlopens the router's *existing*
  `libubus.so.20210630` / `libubox.so.20210516` / `libblobmsg_json.so.20210516`
  / `libjson-c.so.5`. Those `.so` files are vendored in `vendor/` so the
  build links against the exact ABI the router runs — no `libubus` package
  reinstall, no glibc/musl mismatch.

---

## Build (one command)

```sh
docker build -f Dockerfile -t nginx-router .
docker run --rm --name nginx-router nginx-router
docker cp nginx-router:/work/dist/nginx               ./dist/nginx
docker cp nginx-router:/work/dist/ngx_http_ubus_module.so ./dist/
```

`build.sh` runs all 8 stages and ends with a **qemu smoke test** that actually
starts the cross-built binary, curls `GET /` (expect 200) and `POST /ubus`.

Bare-metal (Debian x86_64) without docker: install the same prereqs the
Dockerfile does, then `./build/build.sh`.

## Deploy

```sh
./deploy/deploy.sh <ssh-host>      # e.g. ./deploy/deploy.sh router
```

It: backs up the old binary → uploads `nginx` + the module → injects
`load_module` into `/etc/nginx/uci.conf.template` → regenerates the live conf
via `nginx-util init_lan` → adds the two unversioned `.so` symlinks → persists
the ubus socket symlink in `/etc/rc.local` → restarts and smoke-tests.

## Rollback

```sh
./deploy/rollback.sh <ssh-host> [backup-binary]
```

Restores the stock OpenWrt nginx (its ubus is compiled in, so it just drops the
`load_module` line and our `.so`).

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

---

## Layout

```
versions.lock          # every upstream pinned (shell-sourceable)
build/build.sh         # the 8-stage reproducible pipeline
Dockerfile             # one-command build environment
vendor/*.so            # router's libubus/libubox/libblobmsg_json/libjson-c (ABI-locked)
deploy/deploy.sh       # put the build on the router
deploy/rollback.sh     # restore stock nginx
.gitignore             # src/ + dist/ are build I/O, not committed
```
