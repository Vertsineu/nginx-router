# ============================================================================
# nginx-router — reproducible cross-build of nginx 1.31.6 (aarch64/musl)
#              + OpenWrt ubus dynamic module
# ----------------------------------------------------------------------------
# A *recipe* repo: it does NOT commit the 8.5MB binary. You build it with
# docker (or a bare Debian x86_64 host) and `docker cp` the artifacts out.
#
#   docker build -f Dockerfile -t nginx-router .
#   docker run --rm nginx-router              # builds into /work/dist
#   # or pull artifacts straight out:
#   docker run --rm --name nr nginx-router
#   docker cp nr:/work/dist/nginx            ./nginx
#   docker cp nr:/work/dist/ngx_http_ubus_module.so ./ngx_http_ubus_module.so
#
# Then deploy to the router with ./deploy/deploy.sh (see below).
# ============================================================================
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    JOBS=4

# --- build prereqs -----------------------------------------------------------
#  * binutils-aarch64-linux-gnu : host-side readelf/strip sanity
#  * qemu-user + binfmt-support : nginx's ./configure EXECUTES aarch64 test
#                                 binaries; binfmt routes them to qemu.
#  * autoconf/automake/libtool  : pcre2 ships configure.ac (autogen.sh)
#  * python3                    : deterministic rewrite of the ubus config
#  * git curl ca-certificates   : fetch pinned upstreams
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils tar \
        autoconf automake libtool \
        binutils binutils-aarch64-linux-gnu \
        qemu-user qemu-user-static binfmt-support \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . /work

# binfmt registers qemu-aarch64 at build time; build.sh exports QEMU_LD_PREFIX.
CMD ["/work/build/build.sh"]
