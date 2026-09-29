#!/bin/bash
set -euo pipefail

SRC="${SRC:-/src}"
OUT="${OUT:-/out}"
PG_VERSION="${PG_VERSION:-unknown}"
BUILD_MODE="${BUILD_MODE:-client}"
LOCALES="${LOCALES:-}"
# Extensions to build from source, newline separated: one directory per
# extension, each holding the recipe (a shell file, see extensions/README.md)
# and the source tarball that recipe names. build.sh does the fetching -- the
# host is where the cache and the checksum live, and where the PostgreSQL
# tarball is fetched too -- so nothing here reaches the network. It hands over
# the real paths on a host build and generated mount points inside the
# container, so this script sees one shape either way.
EXT_SPECS="${EXT_SPECS:-}"
# Locales actually copied into the bundle, as opposed to the ones asked for.
# The launcher's behaviour is decided by this list and not by LOCALES: the
# request can name a locale the build could not find, and a client build never
# copies any, yet neither case should produce a launcher that points LOCPATH at
# a directory which is not there.
bundled_locales=()
# The extensions the recipes actually brought, by the name their control file
# gives -- which is what CREATE EXTENSION takes, and not always the recipe's own
# name. Filled in by build_extensions, reported at the end of the build.
ext_installed=()
PREFIX="/tmp/pg-install"
BUILDDIR="/tmp/pgsrc"
BUNDLE="${OUT}"

# -- Tool sets ----------------------------------------------------------
# The split between client and server programs is the one the upstream
# documentation draws between "PostgreSQL Client Applications" and "PostgreSQL
# Server Applications" (doc/src/sgml/reference.sgml). oid2name and vacuumlo are
# contrib frontends and sit outside that split; both are libpq clients, so they
# count as client tools.
CLIENT_TOOLS=(
    clusterdb createdb createuser dropdb dropuser
    ecpg oid2name
    pg_amcheck pg_basebackup pgbench pg_combinebackup pg_config
    pg_dump pg_dumpall pg_isready pg_receivewal pg_recvlogical
    pg_restore pg_verifybackup
    psql reindexdb vacuumdb vacuumlo
)
SERVER_TOOLS=(
    initdb
    pg_archivecleanup pg_checksums pg_controldata pg_createsubscriber
    pg_ctl pg_resetwal pg_rewind
    pg_test_fsync pg_test_timing pg_upgrade pg_waldump pg_walsummary
    postgres
)

# A tool that calls a helper program in its own directory is useless without it,
# even when the helper belongs to the other set, so the client half ships the
# one helper its own tools call: pg_verifybackup runs pg_waldump, a server
# program. Every other sibling lookup stays inside one set: initdb, pg_ctl and
# pg_rewind call postgres, pg_ctl also calls initdb, pg_createsubscriber calls
# pg_ctl and pg_resetwal, and pg_dumpall calls pg_dump. pg_upgrade calls
# pg_dumpall, pg_dump, pg_restore and psql, but those are client tools the full
# bundle ships anyway, so nothing has to be added for it.
CLIENT_HELPERS=(pg_waldump)

case "${BUILD_MODE}" in
    client)
        TOOLS=("${CLIENT_TOOLS[@]}" "${CLIENT_HELPERS[@]}")
        MODE_DESC="client tools, plus the helpers they call"
        ;;
    full)
        TOOLS=("${CLIENT_TOOLS[@]}" "${SERVER_TOOLS[@]}")
        MODE_DESC="client + server tools"
        ;;
    *)
        echo "ERROR: BUILD_MODE must be client or full (got '${BUILD_MODE}')" >&2
        exit 1
        ;;
esac

# WITH_SERVER drives the server payload (extension modules, share/ data trees,
# interpreter runtimes) and the feature set: a bundle that ships the server gets
# every server-side feature, the client build leaves them all off.
WITH_SERVER=false
if [[ "${BUILD_MODE}" = "full" ]]; then WITH_SERVER=true; fi

# The image's entrypoint is bundle.sh, so LOCALES can arrive without build.sh
# having seen it. build.sh refuses this combination too; here it is the copy
# that would otherwise write locale data into a bundle that has no server to
# read it.
if [[ -n "${LOCALES}" && "${WITH_SERVER}" = false ]]; then
    echo "ERROR: LOCALES is set but this is a client build. The locale data" >&2
    echo "       belongs to the server payload; build with BUILD_MODE=full." >&2
    exit 1
fi

ext_specs=()
if [[ -n "${EXT_SPECS}" ]]; then
    while IFS= read -r ext_line; do
        [[ -n "${ext_line}" ]] || continue
        ext_specs+=("${ext_line}")
    done <<<"${EXT_SPECS}"
fi

# Same reasoning as the LOCALES guard above: the image entrypoint can be run
# without build.sh, so this copy has to refuse the combination on its own.
if [[ ${#ext_specs[@]} -gt 0 && "${WITH_SERVER}" = false ]]; then
    echo "ERROR: EXT_SPECS is set but this is a client build. An extension is" >&2
    echo "       server payload: its module goes to lib/postgresql/ and its" >&2
    echo "       .control and .sql to share/postgresql/extension/, and a client" >&2
    echo "       bundle has neither. Build with BUILD_MODE=full." >&2
    exit 1
fi

echo "=== Building PostgreSQL ${PG_VERSION} portable bundle (${BUILD_MODE}: ${MODE_DESC}) ==="

# -- SONAME links, rebuilt from what the files say -----------------------
# Every *.so.<version> in lib/ gets the *.so.<soname> link named after it, read
# out of the file rather than remembered from a list.
#
# This is a function called at two points rather than a step that runs once,
# and the reason is ordering:
#
#   * It has to have run before the dependency walk, because the walk decides
#     what to copy by asking what the bundle already has. libpq is the one that
#     bites: the install prefix supplies libpq.so.5.18 and the .so.5 link is
#     made here, so a walk that ran first concludes libpq.so.5 is missing and
#     copies Debian's on top of the one this build just compiled. It is only
#     luck that the later link pass then points .so.5 back at the right file --
#     the wrong library was briefly in the bundle and the walk's answer was
#     wrong.
#   * It has to run again afterwards, or a library the walk copied in has no
#     link of its own.
#
# readelf rather than "patchelf --print-soname": the soname is one field of the
# dynamic section, and taking it from binutils means the links still get built
# on a host that has no patchelf.
rebuild_soname_links() {
    local f soname
    shopt -s nullglob
    for f in "${BUNDLE}/lib/"*.so.*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue
        soname="$(readelf -d -- "${f}" 2>/dev/null \
            | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p' | head -n 1)"
        [[ -n "${soname}" ]] || continue
        [[ "${soname}" = "$(basename "${f}")" ]] && continue
        ln -sf "$(basename "${f}")" "${BUNDLE}/lib/${soname}"
    done
    shopt -u nullglob
}

# -- One build per output directory -------------------------------------
# The bundle is emptied and refilled, so two builds aimed at the same output
# directory race: the second wipes what the first has already written, both
# carry on, and what is left is a half-written bundle whose symptoms -- a
# wrapper with no .real beside it, a library that never arrived -- read like a
# broken build rather than like two. That is not hypothetical; it is how this
# check came to be written.
#
# The lock file lives inside the bundle rather than beside it because that is
# the only path the two sides share: /out is a bind mount, so a process in
# another container -- or on the host, under --without-container -- contends on
# the same inode. It is taken before the compile, so a second build fails in
# the first second instead of fifteen minutes in.
#
# flock is not everywhere, so a lock directory stands in for it. That one does
# go stale when a build is killed outright, which is why the pid goes inside.
# fd 9 rather than {var}>: the latter needs bash 4.1, and this script only
# promises 4.x.
OUT_LOCK_MODE=""
if command -v flock >/dev/null 2>&1; then
    OUT_LOCK_MODE="flock"
    exec 9>"${BUNDLE}/.pg-portable.lock"
    if ! flock -n 9; then
        echo "ERROR: another build is already writing ${BUNDLE}." >&2
        echo "       It holds the lock on ${BUNDLE}/.pg-portable.lock." >&2
        echo "       Wait for it to finish, or stop it, before starting another." >&2
        exit 1
    fi
else
    OUT_LOCK_MODE="dir"
    if ! mkdir "${BUNDLE}/.pg-portable.lock.d" 2>/dev/null; then
        echo "ERROR: another build is already writing ${BUNDLE}." >&2
        if [[ -f "${BUNDLE}/.pg-portable.lock.d/pid" ]]; then
            echo "       It recorded pid $(cat "${BUNDLE}/.pg-portable.lock.d/pid")." >&2
        fi
        echo "       If nothing is building, that lock is stale: remove" >&2
        echo "       ${BUNDLE}/.pg-portable.lock.d and try again." >&2
        exit 1
    fi
    printf '%s\n' "$$" > "${BUNDLE}/.pg-portable.lock.d/pid"
fi

# Remove the lock when this build is done with it, however it ends. The
# directory form has to; the file form only keeps things tidy -- the kernel
# drops an flock when the process dies regardless.
drop_out_lock() {
    if [[ "${OUT_LOCK_MODE}" = "flock" ]]; then
        rm -f "${BUNDLE}/.pg-portable.lock"
    else
        rm -rf "${BUNDLE}/.pg-portable.lock.d"
    fi
}
trap drop_out_lock EXIT

# -- Explain a meson failure (host builds) ------------------------------
# meson stops at the first thing it cannot find. In a container build the fix
# for that is a package in the Containerfile; on a host build (build.sh sets
# PG_HOST_BUILD) it is a row in build.sh's HOST_DEPS table -- a connection
# nothing in meson's own message makes. Dependencies a newer PostgreSQL release
# introduces arrive here first, so say which file to open.
report_missing_dep() {
    [[ "${PG_HOST_BUILD:-0}" = "1" ]] || return 0
    local log="${BUILDDIR}/build/meson-logs/meson-log.txt" why=""
    # The last ERROR line is the fatal one. Its shape varies -- "Dependency
    # \"icu-uc\" not found, tried pkgconfig" from meson, "Problem encountered:
    # dependency lookup for gssapi failed" from PostgreSQL's own checks -- so
    # quote it as it comes rather than pattern-matching a name out of it.
    if [[ -f "${log}" ]]; then
        why="$(grep -E 'ERROR:' "${log}" 2>/dev/null | tail -n 1 || true)"
    fi
    {
        echo ""
        echo "=== Host build: meson setup failed ==="
        if [[ -n "${why}" ]]; then
            echo "  ${why}"
            echo ""
        fi
        echo "In a container build a missing dependency is a package in the"
        echo "Containerfile. In a host build it is a row in build.sh's HOST_DEPS"
        echo "table -- add one for the item above (the comment above the table"
        echo "documents the columns and what a probe can be), or install it by hand"
        echo "and re-run with --skip-deps. A dependency introduced by a newer"
        echo "PostgreSQL release lands here first, and the Containerfile needs the"
        echo "matching package for container builds."
        echo ""
        echo "meson's log: ${log}"
    } >&2
}

# -- Build --------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" = "1" && -f "${PREFIX}/bin/psql" ]]; then
    echo "=== SKIP_BUILD=1, using existing install at ${PREFIX} ==="
else
    echo "=== Step 1: Copy source and build ==="
    cp -r "${SRC}" "${BUILDDIR}"
    cd "${BUILDDIR}"
    rm -rf build

    # Common options for both modes
    COMMON_OPTS=(
        --prefix="${PREFIX}"
        --libdir=lib
        -Drpath=false
        -Dssl=openssl
        -Dgssapi=enabled
        -Dldap=enabled
        -Dreadline=enabled
        -Dzstd=enabled
        -Dlz4=enabled
        -Dzlib=enabled
        -Dlibcurl=auto
        -Dpam=auto
        -Dlibxml=auto
        -Ddocs=disabled
        -Ddocs_pdf=disabled
        -Dbonjour=disabled
        -Dbsd_auth=disabled
        -Dcassert=false
        --buildtype=release
        --strip
    )

    # The mode decides which features are asked for. Both modes end in the same
    # meson call, so a failure has exactly one place where it is explained.
    MODE_OPTS=()
    if [[ "${WITH_SERVER}" = true ]]; then
        echo "=== Mode: ${BUILD_MODE} (${MODE_DESC}), all server-side features enabled ==="
        MODE_OPTS=(
            -Dnls=enabled
            -Dplperl=enabled
            -Dplpython=enabled
            -Dpltcl=enabled
            -Ddtrace=auto
            -Dllvm=enabled
            -Dselinux=enabled
            -Dsystemd=enabled
            -Dicu=enabled
            -Dlibxslt=enabled
            -Duuid=e2fs
        )
    else
        echo "=== Mode: client (client tools only, server-only features disabled) ==="
        MODE_OPTS=(
            -Dnls=disabled
            -Dplperl=disabled
            -Dplpython=disabled
            -Dpltcl=disabled
            -Ddtrace=disabled
            -Dllvm=disabled
            -Dselinux=disabled
            -Dsystemd=disabled
            -Dicu=disabled
            -Dlibxslt=disabled
            -Dlibnuma=disabled
            -Dliburing=disabled
            -Duuid=none
        )
    fi

    if ! meson setup build "${COMMON_OPTS[@]}" "${MODE_OPTS[@]}"; then
        report_missing_dep
        exit 1
    fi

echo "=== Step 2: Compile ==="
meson compile -C build

echo "=== Step 3: Install ==="
meson install -C build

fi  # end of SKIP_BUILD check

# -- Resolve the compiled-in install paths -----------------------------
# These come out of the generated header rather than being hardcoded, so that
# changing PREFIX cannot silently make the copy steps below grab nothing.
# Note the layout depends on PREFIX not containing "pgsql"/"postgres": only
# then does meson append the "postgresql" component (share/postgresql,
# lib/postgresql) that the relocation logic expects.
PG_PATHS_H="$(find "${BUILDDIR}/build" -name pg_config_paths.h -print -quit 2>/dev/null || true)"
if [[ -z "${PG_PATHS_H}" ]]; then
    echo "ERROR: pg_config_paths.h not found under ${BUILDDIR}/build" >&2
    exit 1
fi
pg_path() { sed -n "s:^#define $1 \"\(.*\)\":\1:p" "${PG_PATHS_H}" | head -1; }

PG_BINDIR="$(pg_path PGBINDIR)"
PG_SHAREDIR="$(pg_path PGSHAREDIR)"
PG_PKGLIBDIR="$(pg_path PKGLIBDIR)"
PG_LOCALEDIR="$(pg_path LOCALEDIR)"

for v in PG_BINDIR PG_SHAREDIR PG_PKGLIBDIR PG_LOCALEDIR; do
    if [[ -z "${!v}" ]]; then
        echo "ERROR: could not resolve $v from ${PG_PATHS_H}" >&2
        exit 1
    fi
done

# Guard the invariant that makes the whole bundle relocatable: PostgreSQL
# rewrites "$PREFIX/share/postgresql" relative to the executable's directory,
# which only lands on <bundle>/share/postgresql if the installed layout really
# has the "postgresql" component. A prefix containing pgsql/postgres drops it.
case "$(basename "${PG_SHAREDIR}")" in
    postgresql) ;;
    *)
        echo "ERROR: PGSHAREDIR is ${PG_SHAREDIR}, expected a .../share/postgresql path." >&2
        echo "       PREFIX must not contain 'pgsql' or 'postgres'." >&2
        exit 1
        ;;
esac

echo "=== Compiled-in paths ==="
echo "  bindir:   ${PG_BINDIR}"
echo "  sharedir: ${PG_SHAREDIR}"
echo "  pkglibdir:${PG_PKGLIBDIR}"
echo "  localedir:${PG_LOCALEDIR}"

echo "=== Installed binaries ==="
ls -la "${PREFIX}/bin/"

# -- Extensions, built from source (--extension) ------------------------
# An extension is compiled the way the server itself is: from source, against
# the prefix just installed, in this same image. That is the point of building
# it here rather than absorbing a package someone else built -- what comes out
# is linked against the same libc and the same OpenSSL as the binaries beside
# it, so Steps 11b and 11c take it in with no machinery of their own and
# nothing about its provenance to verify.
#
# A recipe is a shell file holding what you would type on a host: where the
# source comes from, what it needs, and the commands to build it. It is
# *sourced* rather than executed, so ext_build() sees this shell's variables
# and functions, and this script decides when it runs.
#
# Where it runs is load-bearing: after the install above and before Step 4, so
# that Step 11b's `cp -r ${PG_PKGLIBDIR}/*` and Step 11c's rpath patch and ldd
# pass take the new module in with everything else. Installing into ${BUNDLE}
# directly would bypass all three, plus the SONAME rebuild in Step 10 and the
# assertion in Step 12b.
recipe_has_cmd() {   # cmd:a,b -> any of those commands in PATH
    local n
    for n in ${1//,/ }; do
        command -v "${n}" >/dev/null 2>&1 && return 0
    done
    return 1
}

recipe_has_hdr() {   # hdr:a/b.h,c/d.h -> first hit under the include roots
    local p root
    for p in ${1//,/ }; do
        for root in /usr/include /usr/local/include /usr/include/*/; do
            [[ -f "${root}/${p}" ]] && return 0
        done
    done
    return 1
}

recipe_has_lib() {   # lib:pc1,pc2:hdr1,hdr2
    # pkg-config answers the question meson would ask, but a library that ships
    # no .pc file still counts when its headers are there.
    local pcs="${1%%:*}" hdrs="${1#*:}" pc found=0
    if command -v pkg-config >/dev/null 2>&1; then
        for pc in ${pcs//,/ }; do
            pkg-config --exists "${pc}" 2>/dev/null || found=1
        done
        [[ "${found}" -eq 0 ]] && return 0
    fi
    recipe_has_hdr "${hdrs}"
}

# The same three probes build.sh asks the host with, and a trimmed copy on
# purpose: fn: exists there for the core's own quirks (Fedora ships some of
# perl's modules in packages of their own) and is not something a recipe needs.
# The two scripts cannot share the code because they run in different places --
# build.sh on the host, this one in the image -- and neither can ask the other.
recipe_dep_present() {   # <spec>
    case "${1}" in
        cmd:*) recipe_has_cmd "${1#cmd:}" ;;
        hdr:*) recipe_has_hdr "${1#hdr:}" ;;
        lib:*) recipe_has_lib "${1#lib:}" ;;
    esac
}

build_extensions() {
    local dir recipe name tarball got strip marker before after
    local ext_src f n dep
    local -a found=() ext_added=()
    local -A ctl_before=()

    echo "=== Step 3b: Build extensions (from source) ==="

    for dir in "${ext_specs[@]}"; do
        dir="${dir%/}"

        # One recipe per directory, because that is what build.sh puts there.
        # Two would leave no way to tell which was meant.
        found=()
        for f in "${dir}"/*.sh; do
            [[ -e "${f}" ]] || continue
            found+=("${f}")
        done
        if [[ ${#found[@]} -ne 1 ]]; then
            echo "ERROR: ${dir} holds ${#found[@]} recipes (*.sh), expected one." >&2
            echo "       The directory is assembled by build.sh, which puts a" >&2
            echo "       recipe and the source it names in it." >&2
            exit 1
        fi
        recipe="${found[0]}"
        name="$(basename "${recipe}" .sh)"

        # The unsets are not tidiness: a recipe that forgot EXT_DEPS would
        # otherwise inherit the previous recipe's, and quietly probe for the
        # wrong thing.
        unset EXT_DESC EXT_URL EXT_SHA256 EXT_DEPS EXT_STRIP
        unset -f ext_build
        # shellcheck source=/dev/null
        source "${recipe}"

        if [[ -z "${EXT_URL:-}" || -z "${EXT_SHA256:-}" ]]; then
            echo "ERROR: ${name}: the recipe declares no EXT_URL / EXT_SHA256." >&2
            echo "       build.sh fetches the source from EXT_URL and pins it by" >&2
            echo "       EXT_SHA256; the contract is in extensions/README.md." >&2
            exit 1
        fi
        if [[ ! "${EXT_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo "ERROR: ${name}: EXT_SHA256 is not a sha256 sum: ${EXT_SHA256}" >&2
            exit 1
        fi
        if ! declare -F ext_build >/dev/null; then
            echo "ERROR: ${name}: the recipe defines no ext_build() function." >&2
            echo "       That function holds the build commands -- see" >&2
            echo "       extensions/README.md." >&2
            exit 1
        fi

        # Dependencies before the unpack: one that is missing is a package the
        # image or the host should have, which is a different fix from anything
        # the recipe's own build system would report further down.
        for dep in ${EXT_DEPS[@]+"${EXT_DEPS[@]}"}; do
            case "${dep}" in
                cmd:*|hdr:*|lib:*) ;;
                *)
                    echo "ERROR: ${name}: '${dep}' is not a dependency spec." >&2
                    echo "       A recipe declares cmd:..., hdr:... or lib:...." >&2
                    exit 1
                    ;;
            esac
            if ! recipe_dep_present "${dep}"; then
                echo "ERROR: ${name} needs ${dep}, and it is not here." >&2
                if [[ "${PG_HOST_BUILD:-0}" = "1" ]]; then
                    echo "       Install the package that provides it on this host" >&2
                    echo "       and re-run. A host build does not install a" >&2
                    echo "       recipe's dependencies for it: the package name is" >&2
                    echo "       the distribution's business, and build.sh's table" >&2
                    echo "       of them covers the core and nothing else." >&2
                else
                    echo "       Add it to the Containerfile: that apt list is" >&2
                    echo "       where a recipe's build dependencies belong, and" >&2
                    echo "       nothing is installed while this image runs." >&2
                fi
                exit 1
            fi
        done

        tarball="${dir}/src.tar.gz"
        if [[ ! -f "${tarball}" ]]; then
            echo "ERROR: ${name}: no src.tar.gz beside the recipe in ${dir}." >&2
            echo "       build.sh fetches what EXT_URL names and puts it there," >&2
            echo "       so its being missing means the fetch did not happen." >&2
            exit 1
        fi
        # Verified here as well as on the host, and this is the copy that gets
        # unpacked: a cache entry left over from a different version would
        # otherwise be built under this recipe's name, silently.
        got="$(sha256sum "${tarball}" | awk '{print $1}')"
        if [[ "${got}" != "${EXT_SHA256,,}" ]]; then
            echo "ERROR: ${name}: the source does not match the recipe's EXT_SHA256." >&2
            echo "       expected ${EXT_SHA256,,}" >&2
            echo "       got      ${got}" >&2
            echo "       Remove the cached tarball for this recipe and re-run." >&2
            exit 1
        fi

        ext_src="$(mktemp -d "${TMPDIR:-/tmp}/pg-ext-${name}.XXXXXX")"
        strip="${EXT_STRIP:-1}"
        if ! tar -xf "${tarball}" -C "${ext_src}" --strip-components="${strip}"; then
            echo "ERROR: ${name}: could not unpack $(basename "${tarball}")" >&2
            exit 1
        fi
        # A tarball whose top level is not the single directory EXT_STRIP
        # assumes leaves an empty tree rather than an error, and the recipe's
        # build then fails somewhere inside its own tooling with nothing
        # pointing back here.
        if [[ -z "$(ls -A "${ext_src}")" ]]; then
            echo "ERROR: ${name}: nothing was left after unpacking with" >&2
            echo "       EXT_STRIP=${strip}; the tarball's top level is not what" >&2
            echo "       that assumes." >&2
            exit 1
        fi

        echo ""
        echo "--- ${name}: ${EXT_DESC:-extension} ---"
        echo "  from ${EXT_URL}"
        echo "  against ${PREFIX}"

        # What the recipe is given, and all it needs to know: pg_config is the
        # prefix just built, so PGXS installs into it and nowhere else.
        PG_MAJOR="${PG_VERSION%%[!0-9]*}"
        JOBS="$(nproc 2>/dev/null || echo 2)"
        export PREFIX PG_VERSION PG_MAJOR JOBS
        export PG_CONFIG="${PREFIX}/bin/pg_config"
        export EXT_NAME="${name}" EXT_SRC="${ext_src}"

        ctl_before=()
        for f in "${PREFIX}"/share/postgresql/extension/*.control; do
            [[ -e "${f}" ]] || continue
            ctl_before["$(basename "${f}" .control)"]=1
        done

        marker="${ext_src}/.pg-portable-built"
        touch "${marker}"
        before="$(find "${PREFIX}" -type f 2>/dev/null | wc -l)"

        # Run in a shell of its own with errexit on, not in a subshell here.
        # A subshell in a tested position -- which is where a status has to be
        # caught -- does not honour set -e for what runs inside it, not even
        # with an explicit `set -e` in it (measured, not assumed). A recipe
        # written as three plain commands would then carry on past the one that
        # failed and report the status of the last, which is how a broken build
        # comes out looking green. A new bash process gets errexit that works.
        # The recipe is sourced again inside it, which is the one thing a
        # recipe's top level may not rely on being run only once.
        if ! bash -euo pipefail -c 'source "$1"; cd "$2"; ext_build' \
                _ "${recipe}" "${ext_src}"; then
            echo "" >&2
            echo "ERROR: ${name}: ext_build failed; its output is above." >&2
            # Where the tree it failed in still is depends on which half ran the
            # build, and saying "left in place so that it can be looked at"
            # unconditionally was wrong for the container half: the container is
            # removed when it exits, so the path named there is one no host can
            # read. Say what is true for the build that actually ran.
            if [[ "${PG_HOST_BUILD:-0}" = "1" ]]; then
                echo "       The source tree it ran in is ${ext_src}, left in place" >&2
                echo "       so that it can be looked at, and so is the prefix it was" >&2
                echo "       building against, ${PREFIX}: SKIP_BUILD=1 re-runs bundle.sh" >&2
                echo "       against that prefix, which is how to iterate on a recipe" >&2
                echo "       without compiling PostgreSQL again." >&2
            else
                echo "       The source tree it ran in was ${ext_src}, which is inside" >&2
                echo "       the build container: the container is removed when the build" >&2
                echo "       exits, so that path is not one this machine can read. To" >&2
                echo "       iterate on a recipe with the tree in hand, run the build with" >&2
                echo "       --without-container -- there the tree and the prefix both" >&2
                echo "       survive, and SKIP_BUILD=1 re-runs against the prefix that" >&2
                echo "       build installed." >&2
            fi
            exit 1
        fi

        # An install that ignored PG_CONFIG wrote somewhere under /usr instead,
        # returned 0, and left the bundle without the extension -- the one
        # failure here that is otherwise not noticed until the target machine.
        # Either sign counts: more files than before, or something under the
        # prefix rewritten in place, which is what installing over an earlier
        # build's copy looks like.
        after="$(find "${PREFIX}" -type f 2>/dev/null | wc -l)"
        if [[ "${after}" -le "${before}" ]] &&
           [[ -z "$(find "${PREFIX}" -newer "${marker}" -print -quit 2>/dev/null)" ]]; then
            echo "ERROR: ${name}: ext_build returned 0 but nothing under" >&2
            echo "       ${PREFIX} changed. The usual cause is a build that did" >&2
            echo "       not pick up PG_CONFIG and installed into /usr/local." >&2
            exit 1
        fi

        # Which extensions the recipe brought, read off the control files it
        # wrote: that is the name CREATE EXTENSION wants, and a recipe's own
        # name need not be it. Written-now counts
        # as much as new, because installing a recipe over a prefix that already
        # has it -- which is what SKIP_BUILD=1 does while a recipe is being
        # worked on -- adds no file and still put every one of them there.
        ext_added=()
        for f in "${PREFIX}"/share/postgresql/extension/*.control; do
            [[ -e "${f}" ]] || continue
            n="$(basename "${f}" .control)"
            if [[ -z "${ctl_before[${n}]:-}" ]] || [[ "${f}" -nt "${marker}" ]]; then
                ext_added+=("${n}")
            fi
        done
        if [[ ${#ext_added[@]} -gt 0 ]]; then
            ext_installed+=("${ext_added[@]}")
            printf '  installed: %s\n' "${ext_added[*]}"
        else
            printf '  installed: no .control file, so nothing for CREATE EXTENSION\n'
        fi

        rm -rf "${ext_src}"
    done

    if [[ ${#ext_installed[@]} -gt 0 ]]; then
        echo ""
        printf '  extensions available: %s\n' "${ext_installed[*]}"
    fi
}

if [[ ${#ext_specs[@]} -gt 0 ]]; then
    build_extensions
fi

# -- Bundle -------------------------------------------------------------
echo "=== Step 4: Prepare bundle ==="
# BUNDLE is a bind mount inside the container, so removing the directory itself
# fails with EBUSY and would abort the script under set -e. Empty it instead.
# (Also removes any .real/.real.real left over from an earlier build.)
if [[ ! -d "${BUNDLE}" ]]; then
    echo "ERROR: bundle directory ${BUNDLE} does not exist (is /out mounted?)" >&2
    exit 1
fi
# The lock taken above lives in here and has to survive the empty-out, or the
# build would drop the very thing that keeps a second one out.
find "${BUNDLE}" -mindepth 1 -maxdepth 1 \
    ! -name '.pg-portable.lock' ! -name '.pg-portable.lock.d' \
    -exec rm -rf -- {} +
mkdir -p "${BUNDLE}/bin" "${BUNDLE}/lib"

# glibc itself, the dynamic loader, and the NSS modules glibc dlopen()s by bare
# soname. These must never be touched by patchelf.
NO_PATCH_RE='^(ld-linux.*|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|libresolv\.so\.2|librt\.so\.1|libnss_[a-z0-9]*\.so\.2)$'

# Which of the two dynamic path tags a file carries. The distinction is not
# cosmetic: the loader searches DT_RPATH *before* --library-path and
# LD_LIBRARY_PATH, and DT_RUNPATH *after* both. So a stale or foreign
# DT_RUNPATH is harmless here -- the launcher's --library-path outranks it --
# while a DT_RPATH is a portability hole: the object would resolve that library
# from the machine it was linked on, and succeed, instead of failing loudly.
#
# Read with readelf rather than "patchelf --print-rpath": that reports the
# *effective* rpath without saying which tag it came from, so it cannot tell
# the harmless case from the fatal one, and it does not exist on a host that
# has no patchelf. Both names are matched with their parentheses -- "RPATH" is
# not a substring of "RUNPATH", but anchoring removes the doubt.
rpath_tag() {   # <file> -> RPATH | RUNPATH | (empty)
    readelf -d -- "$1" 2>/dev/null \
        | awk '/\(RPATH\)/{print "RPATH"; exit} /\(RUNPATH\)/{print "RUNPATH"; exit}'
}

patch_rpath() {
    local f="$1" rpath="$2" b
    [[ -f "${f}" ]] || return 0
    b="$(basename "${f}")"
    [[ "${b}" =~ ${NO_PATCH_RE} ]] && return 0
    file -b -- "${f}" | grep -qE '^ELF' || return 0
    # No "--" separator, and this is load-bearing. patchelf 0.14.3 -- what
    # Debian bookworm ships, and so what this build image has -- has no case
    # for a bare "--" in its argument loop; it falls through to the catch-all
    # that collects file names, so the invocation means "patch the two files
    # -- and <f>", and the loop throws on the first one before the real file is
    # ever opened. Between that and 2>/dev/null, this function did nothing at
    # all for as long as the separator was there. Every caller passes an
    # absolute ${BUNDLE}/... path, so no argument can begin with "-" and the
    # separator buys nothing anyway.
    # --set-rpath alone is enough: it replaces the value, and it demotes a
    # DT_RPATH to DT_RUNPATH as a side effect, which is the half that matters.
    patchelf --set-rpath "${rpath}" "${f}" >/dev/null 2>&1 || true
    # Never trust the write. Failing here means patchelf is missing or refused,
    # and the difference between "no rpath" and "a stale DT_RPATH" is the
    # difference between a bundle that works anywhere and one that silently
    # picks up libraries from the machine it was built on.
    if [[ "$(rpath_tag "${f}")" = "RPATH" ]]; then
        echo "ERROR: DT_RPATH survived on ${f#"${BUNDLE}"/}: patchelf is missing" >&2
        echo "       or failed. DT_RPATH is searched before --library-path, so" >&2
        echo "       that object would resolve libraries from outside the bundle." >&2
        exit 1
    fi
}

# Libraries loaded by dlopen() never show up in ldd output, so they get their
# own collection pass keyed on "is it already in the bundle?" rather than on a
# name blacklist -- a name blacklist would also drop unrelated libraries that
# happen to share a prefix.
declare -A new_deps

add_deps() {
    local f line libpath libname
    for f in "$@"; do
        [[ -f "${f}" ]] || continue
        while read -r line; do
            if [[ "${line}" =~ =\>[[:space:]]+(.+)[[:space:]]+\( ]]; then
                libpath="${BASH_REMATCH[1]}"
                libname="$(basename "${libpath}")"
                [[ -f "${libpath}" ]] || continue
                [[ -f "${BUNDLE}/lib/${libname}" ]] && continue
                [[ -n "${new_deps[${libname}]:-}" ]] && continue
                new_deps["${libname}"]="${libpath}"
            fi
        done < <(ldd "${f}" 2>/dev/null)
    done
}

# Drop symlinks that cannot work inside the bundle. A dangling link is dead
# weight; an absolute link points outside the bundle by definition and would
# only resolve on a machine that happens to have that path. The assertion in
# Step 12b then verifies that none are left.
prune_links() {
    local root="$1" f
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        echo "  pruned unusable symlink: ${f#"${BUNDLE}"/}"
        rm -f -- "${f}"
    done < <(find "${root}" \( -xtype l -o -type l -lname '/*' \) 2>/dev/null)
}

# Copies everything add_deps() collected, and records what it copied in
# last_added so that a follow-up pass can walk into those files in turn.
declare -a last_added
flush_deps() {
    local libname
    last_added=()
    [[ ${#new_deps[@]} -gt 0 ]] || return 0
    for libname in "${!new_deps[@]}"; do
        cp -L -- "${new_deps[${libname}]}" "${BUNDLE}/lib/${libname}"
        patch_rpath "${BUNDLE}/lib/${libname}" '$ORIGIN'
        echo "  + ${libname}"
        last_added+=("${BUNDLE}/lib/${libname}")
    done
    new_deps=()
}

# ldd only ever reports the direct NEEDED entries of the files it is given, so
# walking a dependency graph takes one round per level: libpq needs libssl,
# libgssapi_krb5 and libldap, libgssapi_krb5 needs libkrb5, which needs
# libk5crypto and libkeyutils, and so on. Each round feeds the libraries it just
# copied back in, until a round adds nothing.
flush_deps_closure() {
    local -a round=("$@")
    while [[ ${#round[@]} -gt 0 ]]; do
        add_deps "${round[@]}"
        flush_deps
        round=("${last_added[@]}")
    done
}

echo "=== Step 5: Copy binaries (${MODE_DESC}) ==="
# The build always compiles the whole tree; the mode picks what is shipped. A
# name that is absent here means either the tool list drifted from upstream or
# this PostgreSQL version does not have that program at all, so fail loudly
# rather than quietly producing a bundle with a hole in it.
for tool in "${TOOLS[@]}"; do
    if [[ ! -f "${PREFIX}/bin/${tool}" ]]; then
        echo "ERROR: ${PREFIX}/bin/${tool} was not built." >&2
        echo "       If this PostgreSQL version has no such program, update the" >&2
        echo "       tool lists at the top of bundle.sh." >&2
        exit 1
    fi
    cp "${PREFIX}/bin/${tool}" "${BUNDLE}/bin/"
done
printf '  %d tools: %s\n' "${#TOOLS[@]}" "${TOOLS[*]}"

echo "=== Step 6: Collect shared library deps of bin/* (via ldd) ==="
add_deps "${BUNDLE}/bin/"*

echo "=== Step 7: Copy libraries ==="
flush_deps

echo "=== Step 8a: Copy libpq/libecpg/libpgtypes from install prefix ==="
# Not found by ldd because the build used -Drpath=false. Copy only the real
# files; the SONAME symlinks are rebuilt in Step 10.
prefix_libs=()
for pfx in libpq libecpg libpgtypes; do
    for f in "${PREFIX}/lib/${pfx}".so.*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue
        cp -L -- "${f}" "${BUNDLE}/lib/"
        prefix_libs+=("${BUNDLE}/lib/$(basename "${f}")")
        echo "  $(basename "${f}")"
    done
done

# Their own dependencies are invisible to the bin/* pass above, because the one
# pass that could resolve them (ldd following the freshly copied file) only
# happens here. This is not optional detail: psql, pg_dump and every other libpq
# client fails to start without the chain behind libpq (libssl, libgssapi_krb5,
# libldap, and their own dependencies). A bundle that ships the server binaries
# collected that chain by accident -- `postgres` links libssl, libgssapi_krb5
# and libldap directly -- which is exactly what hides the gap in every mode that
# includes it.
if [[ ${#prefix_libs[@]} -gt 0 ]]; then
    echo "  dependencies of those, collected level by level:"
    flush_deps_closure "${prefix_libs[@]}"
fi

echo "=== Step 8b: Copy the dynamic loader ==="
# Ask the binary itself which interpreter it uses; that is more reliable than
# guessing an ld-linux name for the architecture.
LD_LINUX="$(patchelf --print-interpreter "${PREFIX}/bin/psql" 2>/dev/null || true)"
if [[ -z "${LD_LINUX}" || ! -f "${LD_LINUX}" ]]; then
    LD_LINUX="$(find /lib /lib64 /usr/lib /usr/lib64 -maxdepth 3 -name 'ld-linux*.so*' -type f 2>/dev/null | head -1)"
fi
if [[ -z "${LD_LINUX}" || ! -f "${LD_LINUX}" ]]; then
    echo "ERROR: could not locate the dynamic loader" >&2
    exit 1
fi
LD_LINUX_NAME="$(basename "${LD_LINUX}")"
cp -L -- "${LD_LINUX}" "${BUNDLE}/lib/${LD_LINUX_NAME}"
echo "  ${LD_LINUX_NAME} (from ${LD_LINUX})"

echo "=== Step 8c: Copy glibc NSS modules (dlopen'd, invisible to ldd) ==="
# libc calls dlopen("libnss_<service>.so.2") using the bare soname, so a copy
# in lib/ is found through --library-path. Without these, the bundled glibc
# ends up loading the *host's* NSS modules, which fails on GLIBC_PRIVATE
# version mismatches -- and initdb needs getpwuid() to name the superuser.
shopt -s nullglob
for f in /lib/*/libnss_*.so.2 /usr/lib/*/libnss_*.so.2; do
    nss_name="$(basename "${f}")"
    [[ -f "${BUNDLE}/lib/${nss_name}" ]] && continue
    cp -L -- "${f}" "${BUNDLE}/lib/"
    echo "  ${nss_name}"
done
shopt -u nullglob

echo "=== Step 9: Patch RPATH on bin/* and lib/* ==="
for f in "${BUNDLE}/bin/"* "${BUNDLE}/lib/"*; do
    [[ -f "${f}" ]] || continue
    b="$(basename "${f}")"
    if [[ "${b}" =~ ${NO_PATCH_RE} ]]; then
        echo "  skipped (glibc/loader/nss): ${b}"
        continue
    fi
    file -b -- "${f}" | grep -qE '^ELF' || continue
    patch_rpath "${f}" '$ORIGIN/../lib'
done

# -- Server payload ---------------------------------------------------
# This block is numbered 11b-11d although it runs before Step 10: the modules
# it copies are patched and their libraries collected here, so the SONAME links
# (Step 10) have to be rebuilt after them, and the wrappers (Step 11) last.
if [[ "${WITH_SERVER}" = true ]]; then
    echo "=== Step 11b: Copy server modules and share data ==="

    if [[ -d "${PG_PKGLIBDIR}" ]]; then
        mkdir -p "${BUNDLE}/lib/postgresql"
        cp -r "${PG_PKGLIBDIR}/"* "${BUNDLE}/lib/postgresql/"
        echo "  $(find "${BUNDLE}/lib/postgresql" -type f | wc -l) files from ${PG_PKGLIBDIR}"
    else
        echo "ERROR: ${PG_PKGLIBDIR} missing" >&2
        exit 1
    fi

    if [[ -d "${PG_SHAREDIR}" ]]; then
        mkdir -p "${BUNDLE}/share"
        cp -r "${PG_SHAREDIR}" "${BUNDLE}/share/"
        echo "  share/postgresql/ ($(find "${BUNDLE}/share/postgresql" -type f | wc -l) files)"
    else
        echo "ERROR: ${PG_SHAREDIR} missing" >&2
        exit 1
    fi

    # NLS message catalogues. meson installs these straight into
    # <prefix>/share/locale, without the "postgresql" component.
    if [[ -d "${PG_LOCALEDIR}" ]]; then
        mkdir -p "${BUNDLE}/share"
        cp -r "${PG_LOCALEDIR}" "${BUNDLE}/share/"
        echo "  share/locale/ ($(find "${BUNDLE}/share/locale" -type f | wc -l) files)"
    else
        echo "  WARNING: ${PG_LOCALEDIR} missing, messages stay English-only"
    fi

    # The glibc locale *data* for C.UTF-8, which is not the same thing as the
    # NLS catalogues above. C.UTF-8 is not compiled into glibc: it is read from
    # a data directory, and initdb refuses to run with "invalid locale name" when
    # it cannot be found. Debian, Ubuntu and Rocky all ship
    # /usr/lib/locale/C.utf8, so initdb works there and the dependency stays
    # invisible -- but a bare host has nothing. The launchers point LOCPATH at
    # this copy when the host has none of its own (see the wrapper template).
    if [[ -d /usr/lib/locale/C.utf8 ]]; then
        mkdir -p "${BUNDLE}/lib/locale"
        cp -r /usr/lib/locale/C.utf8 "${BUNDLE}/lib/locale/"
        echo "  lib/locale/C.utf8 ($(find "${BUNDLE}/lib/locale/C.utf8" -type f | wc -l) files)"
    else
        echo "  WARNING: /usr/lib/locale/C.utf8 missing from the build image;" >&2
        echo "           initdb --locale=C.UTF-8 will need host locale data" >&2
    fi

    # -- Extra locales (--locales) -------------------------------------
    # Everything above is what a bundle carries by default. LOCALES names the
    # rest, and each one has to be resolved before it can be copied: glibc
    # folds a codeset to lower case and drops its punctuation
    # (_nl_normalize_codeset), so "zh_CN.UTF-8" is the directory "zh_CN.utf8"
    # and "ISO-8859-15" is "iso885915". A name that is already folded matches
    # as it is; the folding is for the ones that are not.
    normalize_locale_name() {   # <name> -> folded form on stdout
        local n="$1" lang="${1%%.*}" codeset="${1#*.}"
        [[ "${codeset}" = "${n}" ]] && { printf '%s' "${n}"; return 0; }
        codeset="$(printf '%s' "${codeset}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
        printf '%s.%s' "${lang}" "${codeset}"
    }

    lift_locale() {   # <requested> -> source directory on stdout, empty if none
        local want="$1" d base
        for d in /usr/lib/locale/*/; do
            [[ -d "${d}" ]] || continue
            base="$(basename "${d}")"
            if [[ "${base}" = "${want}" ]]; then printf '%s' "${d%/}"; return 0; fi
        done
        want="$(normalize_locale_name "${want}")"
        for d in /usr/lib/locale/*/; do
            [[ -d "${d}" ]] || continue
            base="$(basename "${d}")"
            if [[ "$(normalize_locale_name "${base}")" = "${want}" ]]; then
                printf '%s' "${d%/}"
                return 0
            fi
        done
        return 0
    }

    if [[ -n "${LOCALES}" ]]; then
        echo "=== Step 11b2: Bundle extra locales (${LOCALES}) ==="

        # The names arrive from the command line and end up as directories under
        # a bind-mounted /out. build.sh vets them too; this is the copy that has
        # to be safe on its own, because the image entrypoint can be run without
        # build.sh. A name that is empty, "all" is handled separately, or
        # carries a separator or a leading dot is refused outright.
        for want in ${LOCALES//,/ }; do
            case "${want}" in
                ""|.|..|-*|.*|*/*)
                    echo "ERROR: refusing locale name '${want}'" >&2
                    exit 1
                    ;;
            esac
        done

        if [[ "${LOCALES}" = "all" ]]; then
            # Copy every locale the build image has. The set therefore follows
            # the image rather than a list written down here, and a bundle built
            # on Debian will not carry quite the same set as one built on Rocky.
            # Symbolic links are kept: unlike a single named locale below, the
            # whole set is present, so the links between its members resolve.
            shopt -s nullglob
            for d in /usr/lib/locale/*/; do
                base="$(basename "${d}")"
                [[ "${base}" = "locale-archive" ]] && continue
                [[ "${base}" = "C.utf8" ]] && continue   # already copied above
                cp -r --preserve=mode,links "${d%/}" "${BUNDLE}/lib/locale/"
                bundled_locales+=("${base}")
            done
            shopt -u nullglob
            echo "  ${#bundled_locales[@]} locales, $(du -sh "${BUNDLE}/lib/locale" | cut -f1) total"
        else
            for want in ${LOCALES//,/ }; do
                base="$(normalize_locale_name "${want}")"
                src="$(lift_locale "${want}")"
                if [[ -z "${src}" ]]; then
                    # Nothing prebuilt to copy. Compile it instead, which is what
                    # Debian's `locales` package is for: it ships the definitions
                    # under /usr/share/i18n, and localedef turns one into exactly
                    # the directory layout the copy above would have produced --
                    # with no cross-locale links, since it writes every category.
                    # Fedora has no definitions at all (its data arrives prebuilt
                    # in glibc-langpack-*), so there the copy is the only route.
                    lang="${want%%.*}"
                    charset="${want#*.}"
                    [[ "${charset}" = "${want}" ]] && charset="UTF-8"
                    if [[ ! -f "/usr/share/i18n/locales/${lang}" ]]; then
                        echo "ERROR: locale '${want}' can be neither copied nor" >&2
                        echo "       compiled here." >&2
                        echo "       Not under /usr/lib/locale, by that name or its" >&2
                        echo "       folded form, and the definitions localedef" >&2
                        echo "       needs (/usr/share/i18n/locales/${lang}) are absent." >&2
                        echo "       A build image gets both from locales-all; a host" >&2
                        echo "       build needs locales or locales-all installed." >&2
                        exit 1
                    fi
                    # localedef writes into the archive unless the output path
                    # contains a slash, and refuses to create the directory, hence
                    # the mkdir. -c because it exits non-zero on warnings, which
                    # set -e would otherwise turn into a failed build.
                    rm -rf "${BUNDLE}/lib/locale/${base}"
                    mkdir -p "${BUNDLE}/lib/locale/${base}"
                    if ! localedef -c -i "${lang}" -f "${charset}" \
                            "${BUNDLE}/lib/locale/${base}" >/dev/null 2>&1; then
                        echo "ERROR: localedef failed for '${want}'" >&2
                        echo "       (locale ${lang}, charmap ${charset})" >&2
                        exit 1
                    fi
                    bundled_locales+=("${base}")
                    printf '  lib/locale/%s (%s, compiled)\n' "${base}" \
                        "$(du -sh "${BUNDLE}/lib/locale/${base}" | cut -f1)"
                    continue
                fi
                base="$(basename "${src}")"
                # -L on purpose, and it is not a preference. A locale directory
                # is largely symlinks into *other* locales: Debian's
                # locales-all gives zh_CN.utf8 eight links out of twelve
                # categories, pointing at yue_HK, bo_CN, ug_CN, aa_DJ.utf8 and
                # cmn_TW, and its en_US.utf8 is 12 KB of real files that become
                # 2.9 MB once resolved. Copying the links verbatim would leave a
                # directory of dangling links, which the self-containment check
                # below rejects -- and resolving them costs from about 0.4 MB to
                # 3 MB a locale, depending on how much of it was shared.
                rm -rf "${BUNDLE}/lib/locale/${base}"
                cp -rL --preserve=mode "${src}" "${BUNDLE}/lib/locale/"
                bundled_locales+=("${base}")
                printf '  lib/locale/%s (%s)\n' "${base}" \
                    "$(du -sh "${BUNDLE}/lib/locale/${base}" | cut -f1)"
            done
        fi

        # A locale that lost a category file is not a partial locale: setlocale()
        # fails outright. Check now, while the message can still name the locale,
        # rather than leaving it to be discovered as "invalid locale name" on the
        # machine the bundle was built for.
        for base in "${bundled_locales[@]}"; do
            for cat in LC_CTYPE LC_COLLATE LC_NUMERIC LC_TIME LC_MONETARY \
                       LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE \
                       LC_MEASUREMENT LC_IDENTIFICATION; do
                if [[ ! -e "${BUNDLE}/lib/locale/${base}/${cat}" ]]; then
                    echo "ERROR: lib/locale/${base} came out without ${cat};" >&2
                    echo "       refusing to ship a locale that cannot load." >&2
                    exit 1
                fi
            done
        done
        echo "  checked: every bundled locale has all 12 categories"
    fi

    echo "=== Step 11c: Patch server modules and collect their deps ==="
    shopt -s nullglob
    for ext in "${BUNDLE}/lib/postgresql/"*.so; do
        patch_rpath "${ext}" '$ORIGIN/..'
    done
    shopt -u nullglob
    add_deps "${BUNDLE}/lib/postgresql/"*.so
    flush_deps

    # -- Interpreter runtimes for PL/Python, PL/Perl and PL/Tcl --------
    # The shared libraries alone are not enough: Py_Initialize() reads the
    # standard library, Perl resolves modules through @INC, and Tcl sources
    # init.tcl from tcl_library. Worse, /proc/self/exe points at the *loader*
    # (we exec the binary through ld-linux), so CPython and Tcl cannot derive
    # their own prefix and MUST be told via the environment.
    echo "=== Step 11d: Bundle interpreter runtimes ==="

    PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    PY_STDLIB="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
    # CPython looks for its standard library under
    # <prefix>/<platlibdir>/python<X.Y>, and that directory name is compiled
    # into the interpreter: "lib" on Debian, "lib64" on Fedora and RHEL. The
    # bundle keeps the host's name so that the bundled interpreter finds the
    # bundled tree -- a Fedora-built bundle under lib/ would come up with no
    # encodings module at all.
    PY_LIBDIR="$(python3 -c 'import sys; print(sys.platlibdir)')"
    case "${PY_LIBDIR}" in
        lib|lib64) ;;
        *)
            echo "ERROR: python platlibdir is '${PY_LIBDIR}', expected lib or lib64" >&2
            exit 1
            ;;
    esac
    mkdir -p "${BUNDLE}/${PY_LIBDIR}"
    cp -r "${PY_STDLIB}" "${BUNDLE}/${PY_LIBDIR}/python${PY_VER}"
    echo "  ${PY_LIBDIR}/python${PY_VER} <- ${PY_STDLIB}"

    # Perl's @INC contains entries that cannot be derived from Config (Debian
    # ships /usr/share/perl/5.36.0 while privlib says /usr/share/perl/5.36), so
    # ask perl itself. Mirror each entry at the same absolute path under
    # lib/perl/ and put the mirrored paths on PERL5LIB in the same order --
    # PERL5LIB is prepended to @INC, so the bundled copies win.
    # Only the *relative* part of each path is recorded. The wrapper rebuilds
    # PERL5LIB from its own prefix at run time; baking absolute paths here
    # would freeze them to /out, the build container's mount point.
    PERL_INC_SUFFIXES=()
    declare -A perl_seen=()
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        [[ -n "${perl_seen[${d}]:-}" ]] && continue
        perl_seen["${d}"]=1
        dest="${BUNDLE}/lib/perl${d}"
        # Copy the *contents* of the directory, not the directory itself. An
        # @INC entry can be the parent of one that came before it -- Fedora
        # lists /usr/share/perl5/vendor_perl and then /usr/share/perl5 -- and a
        # plain "cp -r src dest" against the directory the earlier entry already
        # created would nest the whole tree one level down, leaving strict.pm
        # and every other core module out of the bundle.
        mkdir -p "${dest}" "$(dirname "${dest}")"
        # -L: several of these entries are symlinks into a sibling versioned
        # directory (Debian ships /usr/share/perl/5.36 -> 5.36.0, but @INC only
        # names 5.36). Copying the link verbatim would leave it dangling and
        # silently drop every module underneath it.
        cp -aL "${d}/." "${dest}/"
        PERL_INC_SUFFIXES+=("${d#/}")
        # Note the explicit per-line newline: "print join("\n", ...)" would
        # leave the last entry unterminated, and "while read" discards a final
        # line that has no newline -- silently dropping privlib.
    done < <(perl -e 'print map { "$_\n" } grep { m{^/} && -d $_ } @INC')
    if [[ ${#PERL_INC_SUFFIXES[@]} -eq 0 ]]; then
        echo "ERROR: could not determine perl @INC directories" >&2
        exit 1
    fi
    PERL_INC_LIST="${PERL_INC_SUFFIXES[*]}"
    echo "  perl (${#PERL_INC_SUFFIXES[@]} @INC dirs)"

    TCLSH="$(command -v tclsh8.6 || command -v tclsh || true)"
    TCL_LIB=""
    if [[ -n "${TCLSH}" ]]; then
        TCL_LIB="$(echo 'puts $tcl_library' | "${TCLSH}" 2>/dev/null || true)"
    fi
    if [[ -z "${TCL_LIB}" || ! -d "${TCL_LIB}" ]]; then
        TCL_LIB="$(find /usr/share/tcltk -maxdepth 1 -mindepth 1 -type d -name 'tcl8.*' 2>/dev/null | head -1)"
    fi
    if [[ -z "${TCL_LIB}" || ! -d "${TCL_LIB}" ]]; then
        echo "ERROR: could not locate the Tcl script library" >&2
        exit 1
    fi
    # The directory's last component must stay "tcl8.<x>": Tcl appends
    # alternative paths derived from that component.
    TCL_VER="$(basename "${TCL_LIB}")"
    cp -r "${TCL_LIB}" "${BUNDLE}/lib/${TCL_VER}"
    echo "  ${TCL_VER} <- ${TCL_LIB}"

    prune_links "${BUNDLE}/${PY_LIBDIR}/python${PY_VER}"
    prune_links "${BUNDLE}/lib/perl"
    prune_links "${BUNDLE}/lib/${TCL_VER}"

    # The .so files inside these trees link against libssl, libcrypt, ... and
    # are outside every earlier scan.
    echo "  collecting dependencies of bundled interpreter modules"
    add_deps $(find "${BUNDLE}/${PY_LIBDIR}/python${PY_VER}" "${BUNDLE}/lib/perl" "${BUNDLE}/lib/${TCL_VER}" \
        -type f -name '*.so*' 2>/dev/null)
    flush_deps

fi

echo "=== Step 10: Rebuild SONAME symlinks ==="
rebuild_soname_links

echo "=== Step 11: Create launcher wrappers ==="
# bash >= 5.2 expands "&" in the *replacement* of ${var//pat/rep} to the text
# that matched the pattern. The PL environment block below contains shell
# conditionals, so without this the generated wrappers would be corrupted.
shopt -u patsub_replacement 2>/dev/null || true

# The wrapper must never write to stdout: find_other_exec() runs "<prog> -V"
# and compares stdout for *equality*, so a stray line makes initdb/pg_ctl
# report a version mismatch.
WRAPPER_TMPL="$(cat <<'WRAPOF'
#!/bin/sh
# pg-portable launcher -- generated by bundle.sh, do not edit.
self=$0
case $self in
    */*) ;;
    *) self=$(command -v -- "$self" 2>/dev/null || printf '%s' "$self") ;;
esac
if command -v readlink >/dev/null 2>&1; then
    _rp=$(readlink -f -- "$self" 2>/dev/null) || _rp=
    [ -n "$_rp" ] && self=$_rp
fi
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P) || exit 127
BASENAME=${self##*/}
PREFIX_DIR=${SELF_DIR%/*}
LIB_DIR=$PREFIX_DIR/lib
LD_LINUX=$LIB_DIR/@LD_LINUX_NAME@
REAL_BIN=$SELF_DIR/$BASENAME.real

[ -x "$LD_LINUX" ] || { echo "$BASENAME: missing bundled loader $LD_LINUX" >&2; exit 127; }
[ -x "$REAL_BIN" ] || { echo "$BASENAME: missing $REAL_BIN" >&2; exit 127; }

@LOCPATH_BLOCK@

@PL_ENV_BLOCK@

# --inhibit-cache: resolve only through the bundle plus the loader's own
# defaults, so a missing library fails loudly instead of silently picking up
# a host copy. --library-path outranks both the cache and DT_RUNPATH.
exec "$LD_LINUX" --inhibit-cache --library-path "$LIB_DIR" "$REAL_BIN" "$@"
WRAPOF
)"

# A mistyped placeholder is not an error anywhere else -- the substitution just
# does nothing and the launchers come out without that block, which shows up on
# the target machine as "invalid locale name" long after the build said it was
# fine. Cheap to check here.
case "${WRAPPER_TMPL}" in
    *@LOCPATH_BLOCK@*) ;;
    *)
        echo "ERROR: the launcher template has no @LOCPATH_BLOCK@ placeholder" >&2
        exit 1
        ;;
esac

PL_ENV_BLOCK=""
if [[ "${WITH_SERVER}" = true ]]; then
    # Only the server binary hosts PL/Python, PL/Perl and PL/Tcl, so only its
    # wrapper gets these. Everything else stays free of them, which keeps a
    # host interpreter started via  \!  or COPY PROGRAM  from inheriting a
    # PYTHONHOME that points into the bundle.
    # PYTHONHOME names the prefix containing @PY_LIBDIR@/python@PY_VER@ -- not
    # the standard library directory itself. Pointing it at the stdlib makes
    # CPython fail to find encodings and abort during Py_Initialize().
    # Deliberately written with "if" rather than "&&": see the note about
    # patsub_replacement above.
    PL_ENV_BLOCK="$(cat <<PLENV
# The interpreter runtimes live inside the bundle. CPython and Tcl cannot
# discover the prefix on their own here: /proc/self/exe points at the bundled
# loader, not at this program.
if [ -d "\$PREFIX_DIR/@PY_LIBDIR@/python@PY_VER@" ]; then PYTHONHOME=\$PREFIX_DIR; export PYTHONHOME; fi
if [ -d "\$LIB_DIR/perl" ]; then
    PERL5LIB=
    for _inc in @PERL_INC@; do
        PERL5LIB="\${PERL5LIB:+\$PERL5LIB:}\$LIB_DIR/perl/\$_inc"
    done
    export PERL5LIB
fi
if [ -d "\$LIB_DIR/@TCL_VER@" ]; then TCL_LIBRARY=\$LIB_DIR/@TCL_VER@; export TCL_LIBRARY; fi
PLENV
)"
    PL_ENV_BLOCK="${PL_ENV_BLOCK//@PY_LIBDIR@/${PY_LIBDIR}}"
    PL_ENV_BLOCK="${PL_ENV_BLOCK//@PY_VER@/${PY_VER}}"
    PL_ENV_BLOCK="${PL_ENV_BLOCK//@PERL_INC@/${PERL_INC_LIST}}"
    PL_ENV_BLOCK="${PL_ENV_BLOCK//@TCL_VER@/${TCL_VER}}"
fi

# Which LOCPATH rule goes into the launchers. Both variants live here as
# quoted heredocs so that $LIB_DIR is left for the launcher to expand; an
# unquoted one would bake in this build's path, exactly the mistake the
# PL_ENV_BLOCK above has to escape around.
if [[ ${#bundled_locales[@]} -gt 0 ]]; then
    LOCPATH_BLOCK="$(cat <<'LOCPATHOF'
# This bundle carries locales of its own, so it takes the locale path: the
# locales asked for at build time have to resolve on a host that has none.
# LOCPATH adds to the search rather than replacing it -- glibc still looks in
# its own directory, which is why /usr/lib/locale is named below -- but it does
# switch off the locale-archive entirely (glibc consults the archive only when
# locale_path is NULL), so a host that keeps its locales in one loses the ones
# that are only there. Everything named here is found first.
if [ -d "$LIB_DIR/locale" ]; then
    LOCPATH=$LIB_DIR/locale:/usr/lib/locale
    export LOCPATH
fi
LOCPATHOF
)"
else
    LOCPATH_BLOCK="$(cat <<'LOCPATHOF'
# C.UTF-8 is locale *data*, not part of libc, and initdb aborts with "invalid
# locale name" when it cannot read it. Point glibc at the bundle's copy only
# when the host has none: a host that does keeps its own, and with it the
# locale-archive lookup that setting LOCPATH would switch off.
if [ ! -d /usr/lib/locale/C.utf8 ] && [ -d "$LIB_DIR/locale/C.utf8" ]; then
    LOCPATH=$LIB_DIR/locale
    export LOCPATH
fi
LOCPATHOF
)"
fi

for bin in "${BUNDLE}/bin/"*; do
    [[ -f "${bin}" ]] || continue
    bname="$(basename "${bin}")"
    file -b -- "${bin}" | grep -qE '^ELF.*executable' || continue

    block=""
    if [[ "${bname}" = "postgres" ]]; then
        block="${PL_ENV_BLOCK}"
    fi

    wrapper="${WRAPPER_TMPL//@LD_LINUX_NAME@/${LD_LINUX_NAME}}"
    wrapper="${wrapper//@PL_ENV_BLOCK@/${block}}"
    wrapper="${wrapper//@LOCPATH_BLOCK@/${LOCPATH_BLOCK}}"

    mv "${bin}" "${bin}.real"
    printf '%s\n' "${wrapper}" > "${bin}"
    chmod +x "${bin}"
    echo "  wrapper: ${bname}"
done

echo "=== Step 12b: Every DT_NEEDED must resolve inside the bundle ==="
# A symlink that does not resolve here -- or that points outside the bundle --
# would break on a machine that lacks the corresponding host path. Both kinds
# have bitten this bundle before: a dangling link is how the Perl privlib tree
# silently disappeared.
broken_links="$(find "${BUNDLE}" -xtype l 2>/dev/null || true)"
abs_links="$(find "${BUNDLE}" -type l -lname '/*' 2>/dev/null || true)"
if [[ -n "${broken_links}" || -n "${abs_links}" ]]; then
    echo "ERROR: unusable symlinks in the bundle:" >&2
    printf '%s\n' "${broken_links}" "${abs_links}" | sed '/^$/d' | head -20 >&2
    exit 1
fi
echo "  all symlinks resolve inside the bundle"

missing=0
rpath_hits=()
while IFS= read -r -d '' f; do
    file -b -- "${f}" | grep -qE '^ELF' || continue
    # A DT_RPATH has no business being in here, and the check rides along with
    # this loop rather than getting one of its own so that "is it ELF" is asked
    # once per file instead of twice. patch_rpath verifies every file it
    # touches; this verifies every file there is, including ones no pass ever
    # patched. Today's bundle has none, so it costs a readelf per ELF and buys
    # the invariant outright.
    if [[ "$(rpath_tag "${f}")" = "RPATH" ]]; then
        rpath_hits+=("${f#"${BUNDLE}"/}")
    fi
    # readelf, not "patchelf --print-needed": that call carried the same "--"
    # separator that made patch_rpath a no-op, and patchelf collects a bare
    # "--" as a file name too, so this assertion threw before it read anything
    # and has been passing vacuously. readelf takes no separator and needs no
    # patchelf, which also makes this work on a host build without it.
    while read -r so; do
        [[ -n "${so}" ]] || continue
        if [[ ! -e "${BUNDLE}/lib/${so}" ]]; then
            echo "  MISSING: ${so}  (needed by ${f#"${BUNDLE}"/})"
            missing=1
        fi
    done < <(readelf -d -- "${f}" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done < <(find "${BUNDLE}" -type f -print0)
if [[ ${#rpath_hits[@]} -gt 0 ]]; then
    echo "ERROR: DT_RPATH found in the bundle:" >&2
    printf '  %s\n' "${rpath_hits[@]}" | head -20 >&2
    echo "       DT_RPATH is searched before --library-path, so these objects" >&2
    echo "       would resolve their libraries from the machine they were" >&2
    echo "       linked on rather than from the bundle." >&2
    exit 1
fi
echo "  no object carries a DT_RPATH"
if [[ "${missing}" != "0" ]]; then
    echo "ERROR: unresolved DT_NEEDED entries -- the bundle is not self-contained" >&2
    exit 1
fi
echo "  all DT_NEEDED entries resolve inside the bundle"

echo "=== Step 12: Verify ==="
echo ""
echo "--- mode: ${BUILD_MODE} (${MODE_DESC}) ---"
echo ""
echo "--- bin/ ---"
ls -la "${BUNDLE}/bin/"
echo ""
echo "--- lib/ (count: $(ls -1 "${BUNDLE}/lib/" | wc -l)) ---"
ls -la "${BUNDLE}/lib/"
echo ""
echo "--- Testing psql --version ---"
if [[ -x "${BUNDLE}/bin/psql" ]]; then
    "${BUNDLE}/bin/psql" --version 2>&1 || true
else
    echo "  (not in this bundle: ${MODE_DESC})"
fi
if [[ "${WITH_SERVER}" = true ]]; then
    echo "--- Testing postgres --version ---"
    if [[ -x "${BUNDLE}/bin/postgres" ]]; then
        "${BUNDLE}/bin/postgres" --version 2>&1 || true
    fi
    echo "--- share/ ---"
    ls "${BUNDLE}/share/" 2>/dev/null || echo "  (none)"
    echo "--- lib/postgresql/ (first 10) ---"
    ls "${BUNDLE}/lib/postgresql/" 2>/dev/null | head -10 || echo "  (none)"
fi

echo ""
echo "=== Build complete! ==="
echo "Output: ${BUNDLE}"
cd "${BUNDLE}/.."
du -sh "$(basename "${BUNDLE}")"
