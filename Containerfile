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
    && rm -rf /var/lib/apt/lists/*

COPY bundle.sh /bundle.sh
RUN chmod +x /bundle.sh

ENTRYPOINT ["/bundle.sh"]
