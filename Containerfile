FROM docker.io/library/debian:bookworm-slim

# Use TUNA mirror for faster installs in China
RUN sed -i 's|http://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    meson \
    ninja-build \
    pkgconf \
    patchelf \
    file \
    ca-certificates \
    # PostgreSQL core build deps
    libreadline-dev \
    libssl-dev \
    libkrb5-dev \
    libldap2-dev \
    libpam0g-dev \
    zlib1g-dev \
    liblz4-dev \
    libzstd-dev \
    libcurl4-openssl-dev \
    bison \
    flex \
    perl \
    python3 \
    # for ldd, strip, etc
    binutils \
    # Full-mode extras (server features, PL languages, ICU, XML, LLVM, etc.)
    libicu-dev \
    libxml2-dev \
    libxslt1-dev \
    llvm-dev \
    clang \
    libsystemd-dev \
    libselinux1-dev \
    uuid-dev \
    libperl-dev \
    python3-dev \
    tcl-dev \
    gettext \
    # Server features that meson would otherwise silently disable for lack of
    # a -dev package (numa-aware shared memory, io_uring AIO, dtrace probes).
    libnuma-dev \
    liburing-dev \
    systemtap-sdt-dev \
    # tcl-dev only pulls the headers and tclConfig.sh; the tclsh interpreter
    # comes from tcl8.6 and is what bundle.sh uses to locate the Tcl script
    # library (/usr/share/tcltk/tcl8.6, shipped by libtcl8.6).
    tcl8.6 \
    # Prebuilt glibc locale data, for --locales. The base image ships only
    # /usr/lib/locale/C.utf8, which is not enough to run
    # initdb --locale=zh_CN.UTF-8 on a host that has no locales of its own.
    # locales-all carries every locale as a directory under /usr/lib/locale,
    # which is the shape bundle.sh copies from; the much smaller `locales`
    # package carries definitions for localedef instead, and is what a host
    # build gets, since it does not need the whole set up front. Costs ~222 MB
    # in this image and nothing in the bundles, except for the locales that
    # --locales actually asks for.
    locales-all \
    && rm -rf /var/lib/apt/lists/*

COPY bundle.sh /bundle.sh
RUN chmod +x /bundle.sh

ENTRYPOINT ["/bundle.sh"]
