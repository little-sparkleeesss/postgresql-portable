#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/cache}"
PG_FTP_BASE="https://ftp.postgresql.org/pub/source"

# -- usage ------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 <version> [--full] [--locales=LIST] [--no-download]
          [--cache-dir DIR] [--without-container] [--skip-deps] [--yes]

Modes:
  (default)   client tools      -> output/<version>
  --full      client + server   -> output/<version>-full

Versions:
  18.4        a release, named exactly as upstream names it
  18          the newest 18.x, read from the download directory's index
  19beta1     a beta or release candidate, which upstream does not name <major>.x
              and therefore has to be given in full

The output directory is named after the version as *asked for*, not as resolved:
"18" always lands in output/18, which is the point -- a CI job can hardcode the
path while the release inside it follows upstream. Everything else (the tarball,
the extracted tree, the version compiled into the bundle) is the concrete
release, and the run says which one that was.

Which program belongs to which set follows the upstream documentation's split
between "PostgreSQL Client Applications" and "PostgreSQL Server Applications";
both lists live at the top of bundle.sh.

--full builds the complete server payload: the extension modules, the share/
data trees and the Python / Perl / Tcl runtimes that PL/Python, PL/Perl and
PL/Tcl need, with every server-side feature enabled. Every bundle is
self-contained, with its own dynamic linker and shared libraries. The client
build leaves the server-only features off, which is what keeps it small.

There is no server-only mode. It would drop 19 client programs and nothing
else -- not a single shared library -- for 2.8 MiB, and it could not even
deliver on its own premise: pg_upgrade calls psql, pg_dump, pg_dumpall and
pg_restore, so it would have to ship those anyway. Use --full.

Neither half is crippled by the split: the one helper a client tool reaches
across the line for is shipped with it. A client bundle therefore carries
pg_waldump, which pg_verifybackup calls.

Locales:
  --locales=LIST       glibc locale data to carry besides C.UTF-8, which every
                       bundle already has: comma separated names
                       (zh_CN.UTF-8,en_US.UTF-8) or the word "all". Needs --full.
                       This is what lets initdb --locale=zh_CN.UTF-8 work on a
                       host that has no locales of its own. Up to about 3 MB
                       each, roughly 230 MB for "all". Carrying any of them
                       makes the launcher set LOCPATH, which switches off the
                       host's locale-archive lookup -- read the README first if
                       the target host keeps its locales there.

Host build:
  --without-container  Compile on this machine instead of in a container. Needs
                       the same toolchain the Containerfile installs; what is
                       missing is probed for and installed through apt or dnf
                       before the build starts.
  --skip-deps          Never install anything -- only report what is missing and
                       build with whatever the host already has.
  --yes                Do not ask before installing packages. Without it the
                       package list is shown and confirmed first, and the build
                       stops when there is no terminal to ask on (so scripts
                       and CI want --yes).

Examples:
  $0 18.4                 client bundle          -> output/18.4
  $0 18                   newest 18.x            -> output/18
  $0 18.4 --full          client + server bundle -> output/18.4-full
  $0 19beta1 --full       build PG 19 beta 1 (all features enabled)
  $0 18.4 --full --locales=zh_CN.UTF-8,en_US.UTF-8   carry two locales
  $0 18.4 --full --locales=all                       carry every locale
  $0 18.4 --no-download   skip download, use existing cache
  $0 /path/to/pg-src      build from local source tree
  $0 18.4 --without-container   build on this host, installing what is missing
  CACHE_DIR=/tmp/pg $0 18.4   use custom cache directory

EOF
    exit 1
}

# -- argument parsing -------------------------------------------------
SKIP_DOWNLOAD=false
BUILD_MODE="client"
VERSION=""
WITHOUT_CONTAINER=false
SKIP_DEPS=false
ASSUME_YES=false
LOCALES=""
LOCALES_GIVEN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            # Not a mode, and not left to the generic "Unknown option" either:
            # say why, so a note or a script that asks for it gets an answer.
            echo "ERROR: --server is not a mode. Use --full: it is the same" >&2
            echo "       bundle with the client tools included, 2.8 MiB larger." >&2
            exit 1
            ;;
        --full)
            BUILD_MODE="full"
            shift
            ;;
        --no-download)
            SKIP_DOWNLOAD=true
            shift
            ;;
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --locales)
            LOCALES="$2"
            LOCALES_GIVEN=true
            shift 2
            ;;
        --locales=*)
            LOCALES="${1#*=}"
            LOCALES_GIVEN=true
            shift
            ;;
        --without-container)
            WITHOUT_CONTAINER=true
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    echo "ERROR: version argument is required"
    usage
fi

# -- validate --locales -----------------------------------------------
# Each name ends up as a directory inside the bundle, and the container writes
# to the bundle through a bind mount, so a name carrying a slash or ".." would
# put files into the caller's own output tree. Check it here rather than trust
# the shell quirk of the moment; bundle.sh checks it again because the image's
# entrypoint can be run directly, without this script.
validate_locales() {
    local list="$1" name
    [[ -n "${list}" ]] || return 0
    if [[ "${list}" = "all" ]]; then return 0; fi
    if [[ ",${list}," = *",all,"* ]]; then
        echo "ERROR: --locales=all cannot be combined with named locales." >&2
        exit 1
    fi
    local -a names
    IFS=',' read -ra names <<<"${list}"
    for name in "${names[@]}"; do
        # The allowed-character test alone would still pass "." and ".." and a
        # leading "-", so those are named separately.
        case "${name}" in
            ""|.|..|-*|.*)
                echo "ERROR: --locales: '${name}' is not a usable locale name." >&2
                exit 1
                ;;
        esac
        if [[ ! "${name}" =~ ^[A-Za-z0-9_@.-]+$ ]]; then
            echo "ERROR: --locales: '${name}' contains characters that cannot" >&2
            echo "       appear in a locale name (allowed: A-Za-z0-9 _ @ . -)." >&2
            exit 1
        fi
    done
}

if [[ "${LOCALES_GIVEN}" = true ]]; then
    if [[ -z "${LOCALES}" ]]; then
        echo "ERROR: --locales needs a value, e.g. --locales=zh_CN.UTF-8" >&2
        echo "       or --locales=all." >&2
        exit 1
    fi
    validate_locales "${LOCALES}"
    if [[ "${BUILD_MODE}" = "client" ]]; then
        echo "ERROR: --locales needs --full. The locale data lives in the server" >&2
        echo "       payload, and a client build also has PostgreSQL's own message" >&2
        echo "       catalogues compiled out, so there would be nothing to read it." >&2
        exit 1
    fi
fi

# Whether the source has to be fetched over the network decides if curl counts
# as a build dependency below; both are known from the arguments alone.
NEEDS_DOWNLOAD=true
if [[ "${SKIP_DOWNLOAD}" = true ]] || [[ "${VERSION}" =~ ^(/|\./) && -d "${VERSION}" ]]; then
    NEEDS_DOWNLOAD=false
fi

# =====================================================================
# Host build: dependency provisioning (--without-container)
# =====================================================================
#
# A host build needs the toolchain and the -dev packages the Containerfile
# installs, but naming them literally is what rots: distributions rename, split
# and merge packages between releases. Fedora 42 provides pkgconfig(zlib) from
# zlib-ng-compat-devel rather than zlib-devel, Debian ships no perl.pc at all,
# and Debian's pam headers move between libpam0g-dev and libpam-dev. So a name
# in the table below is a hint, never the definition.
#
# Each row instead says how to *probe* for the capability, and only a
# capability that is actually absent is installed. How to get it is then left
# to the package manager:
#
#   dnf  the row names a "provide" -- pkgconfig(foo), a header path, a binary
#        path -- and dnf resolves it to whatever binary package provides it
#        today. Nothing is pinned, so an upstream rename is invisible here.
#   apt  has no local file-provides index to search, so the row lists candidate
#        names and they are tried against the package index in order. When
#        every candidate is gone, the index is searched for "<stem>*-dev" and
#        the match closest to the first candidate is taken -- which is how a
#        split or renamed dev package still gets found.
#
# Columns: id | modes | probe | dnf provides | apt candidates
#
#   modes  all      - every build
#          server   - server payload only (--full)
#          download - only when the source has to be fetched
#          locales  - only when --locales named something other than "all"
#          locales-all - only with --locales=all
#          A row is used when any of its modes is active. A client build
#          therefore never pulls in LLVM or the interpreter runtimes.
#
#          The two locale modes are separate because the capability is not the
#          same one: a machine with one langpack can serve a named locale but
#          cannot serve "all", and the package that carries everything is not
#          the package that carries one language.
#
#   probe  cmd:  command in PATH (comma separated alternatives)
#          hdr:  header file under the usual include roots
#          lib:  pkg-config names, with the headers as fallback
#          fn:   a shell function named probe_<name>
#
#   specs  Space separated alternatives; the first one that resolves is used.
#          A "+" joins what one alternative needs *together*, for the cases
#          where a distribution has split one upstream dependency into several
#          packages: Fedora's perl needs Opcode, ExtUtils::Embed and
#          ExtUtils::ParseXS from three different packages before plperl can be
#          built, while Debian has all three in perl itself.
#
read -r -d '' HOST_DEPS <<'EOF' || true
# id        | modes       | probe                                  | dnf provides                                                           | apt candidates
cc          | all         | cmd:cc                                 | /usr/bin/cc                                                            | build-essential gcc
meson       | all         | cmd:meson                              | /usr/bin/meson                                                         | meson
ninja       | all         | cmd:ninja                              | /usr/bin/ninja                                                         | ninja-build
pkgconf     | all         | cmd:pkg-config                         | /usr/bin/pkg-config                                                    | pkgconf pkg-config
bison       | all         | cmd:bison                              | /usr/bin/bison                                                         | bison
flex        | all         | cmd:flex                               | /usr/bin/flex                                                          | flex
perl        | all         | cmd:perl                               | /usr/bin/perl                                                          | perl
binutils    | all         | cmd:ldd                                | /usr/bin/ldd                                                           | binutils
patchelf    | all         | cmd:patchelf                           | /usr/bin/patchelf                                                      | patchelf
file        | all         | cmd:file                               | /usr/bin/file                                                          | file
curl        | download    | cmd:curl                               | /usr/bin/curl                                                          | curl
readline    | all         | lib:readline:readline/readline.h       | pkgconfig(readline)                                                    | libreadline-dev
openssl     | all         | lib:openssl:openssl/ssl.h              | pkgconfig(openssl)                                                     | libssl-dev
krb5        | all         | lib:krb5-gssapi:gssapi/gssapi.h        | pkgconfig(krb5-gssapi)                                                 | libkrb5-dev
ldap        | all         | lib:ldap:ldap.h                        | pkgconfig(ldap)                                                        | libldap2-dev libldap-dev
pam         | all         | hdr:security/pam_appl.h                | /usr/include/security/pam_appl.h                                       | libpam0g-dev libpam-dev
zlib        | all         | lib:zlib:zlib.h                        | pkgconfig(zlib)                                                        | zlib1g-dev
lz4         | all         | lib:liblz4:lz4.h                       | pkgconfig(liblz4)                                                      | liblz4-dev
zstd        | all         | lib:libzstd:zstd.h                     | pkgconfig(libzstd)                                                     | libzstd-dev
libcurl     | all         | lib:libcurl:curl/curl.h                | pkgconfig(libcurl)                                                     | libcurl4-openssl-dev libcurl4-gnutls-dev
xml2        | all         | lib:libxml-2.0:libxml2/libxml/parser.h | pkgconfig(libxml-2.0)                                                  | libxml2-dev
icu         | server      | lib:icu-uc,icu-i18n:unicode/utypes.h   | pkgconfig(icu-uc)                                                      | libicu-dev
xslt        | server      | lib:libxslt:libxslt/xslt.h             | pkgconfig(libxslt)                                                     | libxslt1-dev
llvm        | server      | cmd:llvm-config                        | /usr/bin/llvm-config                                                   | llvm-dev
clang       | server      | cmd:clang                              | /usr/bin/clang                                                         | clang
systemd     | server      | lib:libsystemd:systemd/sd-daemon.h     | pkgconfig(libsystemd)                                                  | libsystemd-dev
selinux     | server      | lib:libselinux:selinux/selinux.h       | pkgconfig(libselinux)                                                  | libselinux1-dev
uuid        | server      | lib:uuid:uuid/uuid.h                   | pkgconfig(uuid)                                                        | uuid-dev libuuid1-dev
numa        | server      | lib:numa:numa.h                        | pkgconfig(numa)                                                        | libnuma-dev
uring       | server      | lib:liburing:liburing.h                | pkgconfig(liburing)                                                    | liburing-dev
sdt         | server      | hdr:sys/sdt.h                          | /usr/include/sys/sdt.h                                                 | systemtap-sdt-dev
gettext     | server      | cmd:msgfmt                             | /usr/bin/msgfmt                                                        | gettext
perl-build  | all         | fn:perl_build_mods                     | perl(FindBin)+perl(File::Basename)+perl(Getopt::Long)+perl(List::Util) | perl
perl-dev    | server      | fn:perl_dev                            | */CORE/perl.h                                                          | libperl-dev
perl-mods   | server      | fn:perl_mods                           | perl(Opcode)+perl(ExtUtils::Embed)+perl(ExtUtils::ParseXS)             | perl
python-dev  | server      | fn:python_dev                          | pkgconfig(python3-embed)                                               | python3-dev
tcl-dev     | server      | fn:tcl_dev                             | pkgconfig(tcl)                                                         | tcl-dev
tclsh       | server      | cmd:tclsh,tclsh8.6,tclsh8.7            | /usr/bin/tclsh                                                         | tcl
locales     | locales     | fn:locale_data                         | /usr/lib/locale/locale-archive                                         | locales locales-all
locales-all | locales-all | fn:locale_all                          | /usr/lib/locale/locale-archive                                         | locales-all
EOF

# -- capability probes ------------------------------------------------
# Every probe returns 0 when the host can already do this, and is written so
# that a missing *tool* makes its dependents report missing as well -- no
# compiler means no way to satisfy the library probes either.

probe_cmd() {   # cmd:a,b -> any of those commands in PATH
    local n
    for n in ${1//,/ }; do
        if command -v "${n}" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

probe_hdr() {   # hdr:a/b.h,c/d.h -> first hit under the include roots
    # The trailing slash matters: /usr/include has none, the glob entries do.
    local p root
    for p in ${1//,/ }; do
        for root in /usr/include /usr/local/include /usr/include/*/; do
            if [[ -f "${root}/${p}" ]]; then return 0; fi
        done
    done
    return 1
}

probe_lib() {   # lib:pc1,pc2:hdr1,hdr2
    # pkg-config answers the question meson will ask, but a distribution that
    # simply has no .pc file for this library (Debian's libperl-dev) would look
    # broken through it, so the headers still count as a yes.
    local pcs="${1%%:*}" hdrs="${1#*:}" pc all_found=0
    if command -v pkg-config >/dev/null 2>&1; then
        for pc in ${pcs//,/ }; do
            pkg-config --exists "${pc}" 2>/dev/null || all_found=1
        done
        if [[ "${all_found}" -eq 0 ]]; then return 0; fi
    fi
    probe_hdr "${hdrs}"
}

probe_perl_build_mods() {
    # PostgreSQL's own build scripts (gen_node_support.pl, gen_keywordlist.pl,
    # genbki.pl, ...) run before anything is compiled, in every mode, and they
    # are what needs these. Distributions that split core perl into one package
    # per module -- Fedora -- otherwise fail the build with "Can't locate
    # FindBin.pm in @INC" several minutes in.
    command -v perl >/dev/null 2>&1 || return 1
    perl -MFindBin -MFile::Basename -MGetopt::Long -MList::Util -e '' 2>/dev/null
}

probe_perl_dev() {
    # The same three things meson wants before it will build plperl: a perl
    # built with a shared library, its headers, and a linkable libperl -- the
    # last one is what the distribution's perl dev package adds, and without it
    # linking plperl fails even though perl.h is there.
    command -v perl >/dev/null 2>&1 || return 1
    command -v cc >/dev/null 2>&1 || return 1
    local core useshrplib libdirs
    core="$(perl -MConfig -e 'print $Config{archlibexp}')/CORE"
    useshrplib="$(perl -MConfig -e 'print $Config{useshrplib}')"
    libdirs="$(perl -MConfig -e 'print join " ", map { "-L$_" } split / /, $Config{libpth}')"
    if [[ "${useshrplib}" != true ]]; then return 1; fi
    if [[ ! -f "${core}/perl.h" ]]; then return 1; fi
    # shellcheck disable=SC2086  # libdirs are separate arguments
    printf '#include <EXTERN.h>\n#include <perl.h>\nint main(void) { return 0; }\n' \
        | cc -x c - -I"${core}" ${libdirs} -lperl -o /dev/null 2>/dev/null
}

probe_perl_mods() {
    # meson runs exactly this before it considers plperl buildable.
    command -v perl >/dev/null 2>&1 || return 1
    perl -MConfig -MOpcode -MExtUtils::Embed -MExtUtils::ParseXS -e '' 2>/dev/null
}

probe_python_dev() {
    # Python.h and libpython lie in versioned paths, so ask python3 where they
    # are instead of guessing them.
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - 2>/dev/null <<'PY'
import os, sys, sysconfig
inc = sysconfig.get_paths()["include"]
if not os.path.exists(os.path.join(inc, "Python.h")):
    sys.exit(1)
libdir = sysconfig.get_config_var("LIBDIR") or ""
ldver = sysconfig.get_config_var("LDVERSION") or ""
if not os.path.exists(os.path.join(libdir, "libpython%s.so" % ldver)):
    sys.exit(1)
PY
}

probe_tcl_dev() {
    # meson takes Tcl from pkg-config, older setups from tclConfig.sh.
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists tcl 2>/dev/null; then
        return 0
    fi
    local d
    for d in /usr/lib /usr/lib64 /usr/local/lib /usr/lib/*-linux-gnu*; do
        if compgen -G "${d}/tclConfig.sh" >/dev/null; then return 0; fi
        if compgen -G "${d}/tcl[0-9]*/tclConfig.sh" >/dev/null; then return 0; fi
    done
    return 1
}

probe_locale_data() {
    # "Can this machine produce a named locale other than C.utf8?" Either a
    # prebuilt directory (Debian's locales-all, Fedora's glibc-langpack-*) or
    # the source definitions localedef needs (Debian's locales package).
    # An existing /usr/share/i18n/locales proves nothing -- Fedora ships the
    # directory empty and keeps its data in langpacks -- so it has to have
    # something in it, and the same goes for the locale directory scan.
    local d
    for d in /usr/lib/locale/*/; do
        [[ -d "${d}" ]] || continue
        case "${d}" in
            */C.utf8/|*/C.UTF-8/) continue ;;
        esac
        return 0
    done
    compgen -G '/usr/share/i18n/locales/*' >/dev/null 2>&1
}

probe_locale_all() {
    # The distribution's "every locale" package. On Fedora and RHEL that is
    # glibc-all-langpacks, which appears as the single locale-archive file; on
    # Debian it is locales-all, which appears as several hundred directories.
    # The count below is a heuristic and not a test -- nothing marks a locale
    # set as complete -- so it is set far above what one langpack provides, to
    # make a host that has a single language still get the package installed.
    if [[ -e /usr/lib/locale/locale-archive ]]; then return 0; fi
    local n
    n="$(find /usr/lib/locale -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    [[ "${n}" -ge 50 ]]
}

dep_probe() {   # probe spec -> 0 when the capability is present
    local spec="$1"
    case "${spec}" in
        cmd:*) probe_cmd "${spec#cmd:}" ;;
        hdr:*) probe_hdr "${spec#hdr:}" ;;
        lib:*) probe_lib "${spec#lib:}" ;;
        fn:*)  "probe_${spec#fn:}" ;;
        *)     echo "ERROR: bad probe spec '${spec}'" >&2; return 1 ;;
    esac
}

# -- package manager --------------------------------------------------

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

# Number of leading characters two names share; the apt fallback below picks the
# index entry that resembles the candidate name most closely.
common_prefix_len() {
    local a="$1" b="$2" i=0
    while [[ "${a:$i:1}" = "${b:$i:1}" && -n "${a:$i:1}" ]]; do i=$((i + 1)); done
    printf '%s' "${i}"
}

# "libldap2-dev" -> "libldap": drop the -dev suffix and the soname digit, the
# part a distribution keeps when it renames the package.
apt_stem() {
    local s="${1%% *}"
    s="${s%-dev}"
    s="${s%%[0-9]*}"
    printf '%s' "${s}"
}

DNF_CMD=""
DNF_HAS_REPOQUERY=false

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo dnf
    else
        echo ""
    fi
}

dnf_resolve_one() {   # provide spec -> package name providing it (empty if none)
    "${DNF_CMD}" -q repoquery --whatprovides "$1" --qf '%{name}\n' 2>/dev/null \
        | sort -u | head -n 1
}

apt_index_present() {
    compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null 2>&1
}

# The best index entry for a name that is gone: the one sharing the longest
# prefix with it, which is how libldap2-dev's replacement libldap-dev wins over
# libldap-ocaml-dev.
apt_search_dev() {   # stem, reference name -> best match, empty if none
    local stem="$1" ref="$2" name best="" best_len=-1 len
    while read -r name; do
        if [[ -z "${name}" ]]; then continue; fi
        len="$(common_prefix_len "${name}" "${ref}")"
        if [[ "${len}" -gt "${best_len}" ]] ||
           { [[ "${len}" -eq "${best_len}" ]] && [[ "${#name}" -lt "${#best}" ]]; }; then
            best="${name}"
            best_len="${len}"
        fi
    done < <(apt-cache search --names-only "^${stem}.*-dev$" 2>/dev/null | awk '{print $1}')
    if [[ -n "${best}" ]]; then printf '%s' "${best}"; fi
}

# Resolve one alternative to the packages it needs, all of them. Empty output
# means "this alternative cannot be satisfied here".
apt_group() {   # name[+name...] -> package names
    local group="$1" name out=""
    for name in ${group//+/ }; do
        if ! apt-cache show "${name}" >/dev/null 2>&1; then return 0; fi
        out="${out}${out:+ }${name}"
    done
    printf '%s' "${out}"
}

dnf_resolve() {   # alternative[+alternative...] -> package names, empty if none
    local groups="$1" group spec pkg out
    for group in ${groups}; do
        out=""
        for spec in ${group//+/ }; do
            pkg="$(dnf_resolve_one "${spec}" || true)"
            if [[ -z "${pkg}" ]]; then out=""; break; fi
            out="${out}${out:+ }${pkg}"
        done
        if [[ -n "${out}" ]]; then printf '%s' "${out}"; return 0; fi
    done
}

apt_resolve() {   # candidate alternatives -> package names, empty if nothing usable
    local groups="$1" group found first stem
    for group in ${groups}; do
        found="$(apt_group "${group}")"
        if [[ -n "${found}" ]]; then printf '%s' "${found}"; return 0; fi
    done
    # Every candidate is gone from the index: look for what carries the first
    # one's stem now.
    first="${groups%% *}"
    first="${first%%+*}"
    stem="$(apt_stem "${first}")"
    [[ -n "${stem}" ]] || return 0
    apt_search_dev "${stem}" "${first}"
}

# -- dependency check -------------------------------------------------

provision_host_deps() {
    local family
    family="$(detect_pkg_manager)"
    if [[ -z "${family}" ]]; then
        echo "ERROR: --without-container needs apt-get, dnf or yum to install build" >&2
        echo "       dependencies; none of them is in PATH." >&2
        exit 1
    fi
    if [[ "${family}" = dnf ]]; then
        if command -v dnf >/dev/null 2>&1; then DNF_CMD=dnf; else DNF_CMD=yum; fi
    fi

    # " all server download ", with either of the last two left out.
    local active_modes=" all "
    if [[ "${BUILD_MODE}" != client ]]; then
        active_modes="${active_modes}server "
    fi
    if [[ "${NEEDS_DOWNLOAD}" = true ]]; then
        active_modes="${active_modes}download "
    fi
    if [[ -n "${LOCALES}" ]]; then
        if [[ "${LOCALES}" = "all" ]]; then
            active_modes="${active_modes}locales-all "
        else
            active_modes="${active_modes}locales "
        fi
    fi

    echo "=== Host build: checking build dependencies (${family}) ==="

    local missing=() resolved=() unresolvable=() still_missing=()
    local line id modes probe dnfspecs aptnames m entry pkg
    local seen="" plan="" SUDO="" reply="" cmdline=""
    while IFS= read -r line; do
        # Skip the column header and blank lines. Written with if/case rather
        # than && / ||: a shortcut whose last command fails becomes the status
        # of this loop body, and set -e would end the script over a skipped row.
        if [[ "${line}" =~ ^[[:space:]]*(#|$) ]]; then continue; fi
        IFS='|' read -r id modes probe dnfspecs aptnames <<<"${line}"
        id="$(trim "${id}")"
        modes="$(trim "${modes}")"
        probe="$(trim "${probe}")"
        dnfspecs="$(trim "${dnfspecs}")"
        aptnames="$(trim "${aptnames}")"

        row_active=false
        for m in ${modes//,/ }; do
            case "${active_modes}" in
                *" ${m} "*) row_active=true ;;
            esac
        done
        if [[ "${row_active}" = false ]]; then continue; fi

        if ! dep_probe "${probe}"; then
            missing+=("${id}|${probe}|${dnfspecs}|${aptnames}")
        fi
    done <<<"${HOST_DEPS}"

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All build dependencies are already present."
        return 0
    fi

    if [[ "${SKIP_DEPS}" = true ]]; then
        echo ""
        echo "Missing (and --skip-deps says not to install anything):"
        for entry in "${missing[@]}"; do
            IFS='|' read -r id probe dnfspecs aptnames <<<"${entry}"
            printf '  %-11s %s\n' "${id}" "${probe}"
        done
        echo "meson will fail if a requested feature needs one of them."
        return 0
    fi

    # Installing needs root; refuse early and clearly rather than reporting a
    # pile of unresolvable packages because the update below could not run.
    if [[ "${EUID}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "ERROR: --without-container has to install build dependencies, which" >&2
            echo "       needs root, and sudo is not available. Install these yourself" >&2
            echo "       and re-run with --skip-deps:" >&2
            for entry in "${missing[@]}"; do
                IFS='|' read -r id probe dnfspecs aptnames <<<"${entry}"
                printf '         %-11s %s\n' "${id}" "${probe}" >&2
            done
            exit 1
        fi
    fi

    # apt looks every name up in its package index, and a host that never ran
    # apt-get update has none -- every candidate would look unknown and nothing
    # would resolve.
    if [[ "${family}" = apt ]] && ! apt_index_present; then
        echo "apt package index is empty, running apt-get update first..."
        # shellcheck disable=SC2086
        ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get update
    fi

    # repoquery answers the provides questions below. It is built into dnf5 but
    # a plugin in older dnf, hence the check -- and hence it happens here rather
    # than up front, so that a host which is already complete never talks to the
    # network at all.
    if [[ "${family}" = dnf ]] && "${DNF_CMD}" repoquery --help >/dev/null 2>&1; then
        DNF_HAS_REPOQUERY=true
    fi

    # -- what to install for each of them -----------------------------
    for entry in "${missing[@]}"; do
        IFS='|' read -r id probe dnfspecs aptnames <<<"${entry}"
        pkgs=""
        if [[ "${family}" = apt ]]; then
            pkgs="$(apt_resolve "${aptnames}")"
        elif [[ "${DNF_HAS_REPOQUERY}" = true ]]; then
            pkgs="$(dnf_resolve "${dnfspecs}")"
        else
            # Without repoquery the alternatives cannot be tried beforehand;
            # dnf resolves provides itself at install time, so pass the first
            # alternative on -- a wrong one now shows up as a failed install.
            pkgs="${dnfspecs%% *}"
            pkgs="${pkgs//+/ }"
        fi
        if [[ -z "${pkgs}" ]]; then
            unresolvable+=("${id}")
            printf '  %-11s no package found for: %s\n' "${id}" "${dnfspecs}"
            continue
        fi
        printf '  %-11s %s   (for %s)\n' "${id}" "${pkgs}" "${probe}"
        for pkg in ${pkgs}; do
            if [[ "${seen}" != *" ${pkg} "* ]]; then
                seen="${seen} ${pkg} "
                resolved+=("${pkg}")
                plan="${plan} ${pkg}"
            fi
        done
    done

    if [[ ${#unresolvable[@]} -gt 0 ]]; then
        echo ""
        echo "No package on this distribution is known for: ${unresolvable[*]}"
    fi

    if [[ ${#resolved[@]} -eq 0 ]]; then
        echo ""
        echo "WARNING: nothing could be installed for the missing dependencies above."
        echo "         The build will fail unless meson finds them anyway."
        return 0
    fi

    # -- install ------------------------------------------------------
    if [[ "${family}" = apt ]]; then
        cmdline="${SUDO:+${SUDO} }apt-get install -y${plan}"
    else
        cmdline="${SUDO:+${SUDO} }${DNF_CMD} install -y${plan}"
    fi

    echo ""
    echo "Install with:"
    echo "  ${cmdline}"
    if [[ "${ASSUME_YES}" = true ]]; then
        :
    elif [[ -t 0 && -t 1 ]]; then
        read -r -p "Proceed? [y/N] " reply || true
        if [[ ! "${reply}" =~ ^[Yy] ]]; then
            echo "Not installing; the build will run with what the host already has."
            return 0
        fi
    else
        echo "Not a terminal -- re-run with --yes to install, or --skip-deps to skip." >&2
        exit 1
    fi

    echo ""
    echo "=== Installing build dependencies ==="
    if [[ "${family}" = apt ]]; then
        # shellcheck disable=SC2086
        ${SUDO} env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y ${plan}
    else
        # shellcheck disable=SC2086
        ${SUDO} "${DNF_CMD}" install -y ${plan}
    fi

    # -- verify -------------------------------------------------------
    echo ""
    echo "=== Re-checking ==="
    for entry in "${missing[@]}"; do
        IFS='|' read -r id probe dnfspecs aptnames <<<"${entry}"
        dep_probe "${probe}" || still_missing+=("${id}")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        echo "WARNING: still missing: ${still_missing[*]}" >&2
        echo "         meson will fail if a requested feature needs one of them." >&2
    else
        echo "All build dependencies are present."
    fi
}

if [[ "${WITHOUT_CONTAINER}" = true ]]; then
    provision_host_deps
fi

# =====================================================================
# Major-only version: "18" means the newest 18.x
# =====================================================================
#
# The answer comes from the download directory's own index -- the listing the
# tarball is fetched from -- rather than from anywhere else, so what it names
# can actually be downloaded. Two things about that index shape the code
# below. It is not dense -- numbers get skipped when a release is withdrawn
# (the FTP has a v18.6 and no v18.5) -- so the newest is the highest one
# present, never "the previous plus one". And it lists betas and release
# candidates under names that are not <major>.<digits> (v19beta1, v18rc2), which
# is what the [0-9]+ after the dot is for: asking for 18 must not answer with
# 18rc2, and asking for 19 must not answer with 19beta1.
#
# Sort with -V, not the default: "18.9" sorts above "18.10" lexically.

resolve_major_version() {   # <major> -> a release version on stdout
    local major="$1" version listing
    if [[ "${SKIP_DOWNLOAD}" = true ]]; then
        # --no-download keeps the network out of it, so the answer has to come
        # from what is already here: the highest 18.x tarball in the cache.
        version="$(
            find "${CACHE_DIR}" -maxdepth 1 -name "postgresql-${major}.*.tar.bz2" \
                -printf '%f\n' 2>/dev/null \
                | sed -nE "s/^postgresql-(${major}\.[0-9]+)\.tar\.bz2$/\1/p" \
                | sort -V | tail -n 1
        )" || true
        if [[ -z "${version}" ]]; then
            echo "ERROR: '${major}' cannot be resolved without the network, and" >&2
            echo "       --no-download rules it out. ${CACHE_DIR} holds no" >&2
            echo "       postgresql-${major}.<minor>.tar.bz2 tarball. Name the" >&2
            echo "       release in full (e.g. ${major}.0), or drop --no-download." >&2
            exit 1
        fi
    else
        # Keep "the index could not be read" apart from "the index has no such
        # release": they need different fixes, and reporting the second when the
        # first happened sends the reader looking for a version that is there.
        if ! listing="$(curl -fsSL --max-time 60 "${PG_FTP_BASE}/" 2>/dev/null)"; then
            echo "ERROR: could not read the release index at ${PG_FTP_BASE}/" >&2
            echo "       (network or proxy problem). Name the release in full," >&2
            echo "       e.g. ${major}.0, to build without the lookup." >&2
            exit 1
        fi
        version="$(
            printf '%s\n' "${listing}" \
                | sed -nE "s/.*href=\"v(${major}\.[0-9]+)\/.*/\1/p" \
                | sort -V | tail -n 1
        )" || true
        if [[ -z "${version}" ]]; then
            echo "ERROR: no released ${major}.x under ${PG_FTP_BASE}/" >&2
            echo "       Beta and release-candidate directories are not named" >&2
            echo "       ${major}.x; pass one in full if that is what you want," >&2
            echo "       e.g. ${major}beta1." >&2
            exit 1
        fi
    fi
    printf '%s' "${version}"
}

# What was asked for names the output directory; what it resolves to names
# everything that gets downloaded. The two are the same unless the request was
# a bare major, which is exactly when a caller wants the path to stay put.
REQ_VERSION="${VERSION}"

if [[ "${VERSION}" =~ ^[0-9]+$ ]]; then
    RESOLVED="$(resolve_major_version "${VERSION}")"
    # Say which question was answered. Offline it is "the newest one here", which
    # is not the same claim as "the newest one there", and printing the second
    # when the first was meant would read as an endorsement of a stale release.
    if [[ "${SKIP_DOWNLOAD}" = true ]]; then
        echo "Version '${VERSION}' names a major release: using the newest in the cache, ${RESOLVED}"
        echo "  (--no-download: a newer ${VERSION}.x may exist upstream)"
    else
        echo "Version '${VERSION}' names a major release: using the newest ${VERSION}.x, ${RESOLVED}"
    fi
    VERSION="${RESOLVED}"
fi

# -- determine source directory ---------------------------------------
# If VERSION is a local path (starts with / or ./)
if [[ "${VERSION}" =~ ^(/|\./) && -d "${VERSION}" ]]; then
    SRC_DIR="${VERSION}"
    echo "Using local source: ${SRC_DIR}"
else
    mkdir -p "${CACHE_DIR}"

    TARBALL="postgresql-${VERSION}.tar.bz2"
    TARBALL_URL="${PG_FTP_BASE}/v${VERSION}/${TARBALL}"
    SHA256_URL="${TARBALL_URL}.sha256"
    SRC_DIR="${CACHE_DIR}/postgresql-${VERSION}"

    # -- download -----------------------------------------------------
    if [[ "${SKIP_DOWNLOAD}" = true ]]; then
        if [[ ! -f "${CACHE_DIR}/${TARBALL}" ]]; then
            echo "ERROR: --no-download set but tarball not found: ${CACHE_DIR}/${TARBALL}"
            exit 1
        fi
        echo "Skipping download, using cached: ${CACHE_DIR}/${TARBALL}"
    else
        if [[ -f "${CACHE_DIR}/${TARBALL}" ]]; then
            echo "Tarball already cached: ${CACHE_DIR}/${TARBALL}"
        else
            echo "Downloading: ${TARBALL_URL}"
            curl -fSL --progress-bar -o "${CACHE_DIR}/${TARBALL}" "${TARBALL_URL}"
            echo "Download complete: ${CACHE_DIR}/${TARBALL}"
        fi

        # -- verify sha256 --------------------------------------------
        echo "Downloading SHA256: ${SHA256_URL}"
        curl -fSL --progress-bar -o "${CACHE_DIR}/${TARBALL}.sha256" "${SHA256_URL}"

        EXPECTED=$(awk '{print $1}' "${CACHE_DIR}/${TARBALL}.sha256")
        ACTUAL=$(sha256sum "${CACHE_DIR}/${TARBALL}" | awk '{print $1}')
        if [[ "${EXPECTED}" != "${ACTUAL}" ]]; then
            echo "ERROR: SHA256 mismatch!"
            echo "  Expected: ${EXPECTED}"
            echo "  Got:      ${ACTUAL}"
            rm -f "${CACHE_DIR}/${TARBALL}" "${CACHE_DIR}/${TARBALL}.sha256"
            exit 1
        fi
        echo "SHA256 verified OK"
    fi

    # -- extract ------------------------------------------------------
    if [[ -d "${SRC_DIR}" ]]; then
        echo "Source already extracted: ${SRC_DIR}"
    else
        echo "Extracting: ${CACHE_DIR}/${TARBALL}"
        tar -xjf "${CACHE_DIR}/${TARBALL}" -C "${CACHE_DIR}"
        echo "Extraction complete: ${SRC_DIR}"
    fi
fi

# -- container runtime ------------------------------------------------
# Only needed for the default, containerised path. Rootless podman is the
# preferred runtime. Docker is a fallback; note that its daemon normally runs as
# root, so only use it where that is acceptable.
RUNTIME=""
if [[ "${WITHOUT_CONTAINER}" = false ]]; then
    if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
        RUNTIME="${CONTAINER_RUNTIME}"
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
        echo "NOTE: podman not found, falling back to docker (daemon usually runs as root)."
    else
        echo "ERROR: neither podman nor docker found in PATH" >&2
        exit 1
    fi
    command -v "${RUNTIME}" >/dev/null 2>&1 || {
        echo "ERROR: CONTAINER_RUNTIME=${RUNTIME} not found in PATH" >&2
        exit 1
    }

    # The :Z suffix asks for an SELinux relabel; that is a podman feature.
    if [[ "${RUNTIME}" = "podman" ]]; then
        SRC_MOUNT_OPTS=":ro,Z"
        OUT_MOUNT_OPTS=":Z"
    else
        SRC_MOUNT_OPTS=":ro"
        OUT_MOUNT_OPTS=""
    fi
fi

# -- build ------------------------------------------------------------
case "${BUILD_MODE}" in
    client) OUT_SUFFIX="";      MODE_DESC="client tools only" ;;
    full)   OUT_SUFFIX="-full"; MODE_DESC="client + server tools" ;;
esac
OUT_DIR="${SCRIPT_DIR}/output/${REQ_VERSION}${OUT_SUFFIX}"

if [[ "${WITHOUT_CONTAINER}" = true ]]; then
    echo ""
    echo "=== Running build on the host ==="
    echo "Source: ${SRC_DIR}"
    echo "Output: ${OUT_DIR}"
    echo "Version: ${VERSION}"
    echo "Mode: ${BUILD_MODE} (${MODE_DESC})"

    mkdir -p "${OUT_DIR}"

    # bundle.sh works out of its own /tmp scratch dirs and takes the mount
    # points the container would have provided from the environment.
    # PG_HOST_BUILD tells it that a dependency meson cannot find is this file's
    # HOST_DEPS table rather than the Containerfile.
    SRC="${SRC_DIR}" OUT="${OUT_DIR}" PG_VERSION="${VERSION}" BUILD_MODE="${BUILD_MODE}" \
        LOCALES="${LOCALES}" \
        PG_HOST_BUILD=1 bash "${SCRIPT_DIR}/bundle.sh"
else
    echo "=== Building image (${RUNTIME}) ==="
    # -f is required: podman finds Containerfile on its own, docker does not.
    "${RUNTIME}" build -f "${SCRIPT_DIR}/Containerfile" -t pg18-builder "${SCRIPT_DIR}"

    mkdir -p "${OUT_DIR}"

    echo ""
    echo "=== Running build container ==="
    echo "Runtime: ${RUNTIME}"
    echo "Source: ${SRC_DIR}"
    echo "Output: ${OUT_DIR}"
    echo "Version: ${VERSION}"
    echo "Mode: ${BUILD_MODE} (${MODE_DESC})"

    # Run as the invoking user so the bundle is not left owned by root.
    "${RUNTIME}" run --rm \
        --user "$(id -u):$(id -g)" \
        -e "HOME=/tmp" \
        -e "PG_VERSION=${VERSION}" \
        -e "BUILD_MODE=${BUILD_MODE}" \
        -e "LOCALES=${LOCALES}" \
        -v "${SRC_DIR}:/src${SRC_MOUNT_OPTS}" \
        -v "${OUT_DIR}:/out${OUT_MOUNT_OPTS}" \
        pg18-builder
fi

echo ""
echo "=== Done ==="
# The directory is named for the request, so say what actually went into it --
# otherwise "output/18/" is the only thing a log records about the release.
if [[ "${REQ_VERSION}" != "${VERSION}" ]]; then
    echo "'${REQ_VERSION}' resolved to PostgreSQL ${VERSION}"
fi
echo "Result: ${OUT_DIR}/"
ls -la "${OUT_DIR}/"
echo ""
case "${BUILD_MODE}" in
    client)
        echo "Run with: ${OUT_DIR}/bin/psql"
        echo "(the bundle also carries pg_waldump, which pg_verifybackup calls)"
        ;;
    full)
        echo "Initialize a data directory with:"
        echo "  ${OUT_DIR}/bin/initdb -D /path/to/pgdata --locale=C.UTF-8 -U postgres"
        if [[ -n "${LOCALES}" ]]; then
            echo "(this bundle also carries: ${LOCALES} -- any of those can be"
            echo " passed to initdb --locale instead)"
        fi
        echo "Start it with:"
        echo "  ${OUT_DIR}/bin/pg_ctl -D /path/to/pgdata -l /tmp/pg.log -o \"-p 5433 -k /tmp\" start"
        echo "Connect with:"
        echo "  ${OUT_DIR}/bin/psql -h /tmp -p 5433 -U postgres"
        ;;
esac
