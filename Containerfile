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
    # Used at image-build time by the recipe setup layer, which is where a
    # toolchain that apt does not have gets fetched from, and by a recipe's own
    # build, which may reach the network like any other build. Taken
    # unconditionally: 1.3 MB with its library, and a build image without a
    # curl in it is a nuisance to work in.
    curl \
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
    # Full-mode extras (server features, PL languages, ICU, XML, etc.).
    # llvm-dev and clang are deliberately absent: they are the only way to
    # build llvmjit.so, and it is not built -- see the note in bundle.sh. Not
    # installing them keeps libLLVM and libz3 out of the image by default (127
    # MB for a feature nothing uses); a recipe that needs libclang asks for it
    # in its own EXT_APT, which is the recipe's business and not this list's.
    libicu-dev \
    libxml2-dev \
    libxslt1-dev \
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


# -- The image's own packages -------------------------------------------
# PostgreSQL's build dependencies, and what the layers below use to build it.
# Once the image is built, nothing installs from a repository again: these
# package lists are emptied at the end of this list and never refilled.
#
# A recipe's build dependencies are not added to this list. A recipe declares
# them -- EXT_APT for packages, ext_setup() for what apt cannot supply --
# build.sh collects them across every --extension, and the two layers at the
# bottom of this file install them. Adding a recipe means writing one file; it
# does not mean editing this one.

# -- What the recipes asked for -----------------------------------------
# The packages the recipes named arrive here as PG_APT_EXTRA: still this file,
# but no longer edited by hand. build.sh collects EXT_APT across every
# --extension and passes the union along as a build argument.
#
# It sits near the end, after everything the image needs for itself, so that a
# different set of --extension rebuilds this layer and the setup layer below it
# and nothing above them. It comes before the setup layer rather than after it
# so that a setup script can use a package a recipe named.
#
# A package a recipe names is trusted the way build-essential is trusted -- by
# the archive's own signatures, which is not the standard EXT_SHA256 holds a
# source tarball to, and is the standard the rest of this image is held to. It
# is also the one declaration that does not pin bytes: a name resolves against
# whatever the archive holds the day the image is built.
ARG PG_APT_EXTRA=""
RUN set -eux; \
    if [ -n "${PG_APT_EXTRA}" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ${PG_APT_EXTRA}; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# -- What the recipes asked for: setup commands -------------------------
# A recipe whose build needs something apt does not have writes the commands
# that install it, as a function called ext_setup(). build.sh lifts the body
# out of the recipe and drops it in this context as pg-portable-setup/<name>.sh,
# and the layer below runs them -- in the image's own filesystem, as root, with
# the network, while the image is being built. It is the one place a recipe's
# code runs as root; everywhere else the recipe runs as the invoking user, in
# the built image, where a mistake costs the bundle and not the machine.
#
# What a setup script must leave behind is a toolchain the *build* can find,
# and the build is not the process that ran it: it runs as the invoking user
# rather than as root, with HOME=/tmp, and it is not a login shell.
#
#   - Binaries on PATH. /usr/local/bin is on it; a toolchain that installs
#     elsewhere needs a symlink or a PATH entry (below).
#
#   - Environment, when there is no other way to say where something is. A
#     profile.d snippet does nothing for a shell that is not a login shell, so
#     a setup script appends KEY=value lines to /etc/pg-portable.env instead,
#     and bundle.sh sources that file before it probes for anything or builds
#     anything.
#
#     It has to be applied that early because the first thing that looks a
#     dependency up by name is the capability probe -- EXT_DEPS=(cmd:cargo) --
#     which runs before any recipe code does. A PATH set inside ext_build()
#     would be a PATH set after the check that needed it.
#
# Nothing is installed unless a recipe asked, so a build naming only C recipes
# runs an empty layer and carries no toolchain at all.

# One script per recipe that declared ext_setup(). COPY of an empty directory
# is an empty directory, and a glob with nothing to match stays literal, which
# is what the -e test below is for: a build with no --extension runs this and
# does nothing.
COPY pg-portable-setup/ /tmp/pg-portable-setup/

RUN set -eux; \
    touch /etc/pg-portable.env; \
    for f in /tmp/pg-portable-setup/*.sh; do \
        [ -e "$f" ] || continue; \
        echo "=== $f"; \
        bash "$f"; \
    done; \
    rm -rf /tmp/pg-portable-setup


COPY bundle.sh /bundle.sh
RUN chmod +x /bundle.sh

ENTRYPOINT ["/bundle.sh"]
