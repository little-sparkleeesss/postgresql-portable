#!/bin/bash
set -euo pipefail

# verify.sh - end-to-end verification of a portable PostgreSQL bundle.
# Needs --full: the payload runs initdb, the server and psql.
#
#   ./verify.sh <bundle-dir> [image ...]
#
# Extensions a bundle built with --extension are not guessed at -- there is
# no way to tell a core control file from an installed one by looking, and
# "CREATE EXTENSION everything" is not an option (sepgsql needs SELinux,
# pg_stat_statements needs shared_preload_libraries). Name them instead:
#
#   VERIFY_EXTENSIONS=myext ./verify.sh <bundle-dir>
#
# The bundle is mounted *read-only* at a path unrelated to where it was built
# (/opt/pg), inside containers whose distribution differs from the build image.
# That proves relocation works and that the bundle is not leaning on the
# libraries of the machine it was built on.
#
# Every PostgreSQL process runs with LD_DEBUG=libs. Any shared library a bundle
# process loads from outside the bundle is reported as a failure, which is the
# only way to actually demonstrate "no external dependencies".

BUNDLE="${1:-}"
if [[ -z "${BUNDLE}" ]]; then
    sed -n '3,23p' "$0"
    exit 1
fi
shift

if [[ ! -d "${BUNDLE}/bin" ]]; then
    echo "ERROR: ${BUNDLE}/bin not found -- pass a bundle directory" >&2
    exit 1
fi
BUNDLE_ABS="$(cd "${BUNDLE}" && pwd)"

# The payload drives initdb, starts the server and talks to it over libpq, so it
# needs the server half plus the client tools it uses -- a --full bundle. A
# client-only bundle cannot run it.
for tool in initdb pg_ctl postgres psql pg_dump pg_restore; do
    if [[ ! -x "${BUNDLE}/bin/${tool}" ]]; then
        echo "ERROR: ${BUNDLE}/bin/${tool} not found -- build with --full." >&2
        exit 1
    fi
done

# Checked here, on the host, because this is the last place that can tell a
# typo from a bundle that simply does not have that extension. Inside the
# container the name would reach a section that skips whatever it cannot find,
# and the run would end with everything green and the extension never
# mentioned -- which is the one outcome worse than a failure.
if [[ -n "${VERIFY_EXTENSIONS:-}" ]]; then
    IFS=',' read -ra _ext_names <<<"${VERIFY_EXTENSIONS}"
    for _name in "${_ext_names[@]}"; do
        [[ -n "${_name}" ]] || continue
        if [[ ! -f "${BUNDLE_ABS}/share/postgresql/extension/${_name}.control" ]]; then
            echo "ERROR: VERIFY_EXTENSIONS names '${_name}', but this bundle has no" >&2
            echo "       share/postgresql/extension/${_name}.control. Either it was" >&2
            echo "       not built with that --extension, or the name is wrong." >&2
            exit 1
        fi
    done
    unset _ext_names _name
fi

# At least one image must have Python/Perl versions *different* from the ones
# bundled; if PL/Python or PL/Perl still work there, they must be using the
# bundled runtimes. rockylinux:9 also has an older glibc than the build image,
# so any reliance on the host's libc shows up as a hard GLIBC_* symbol error.
IMAGES=("$@")
if [[ ${#IMAGES[@]} -eq 0 ]]; then
    IMAGES=(
        "docker.io/library/debian:bookworm-slim"
        "docker.io/library/rockylinux:9"
    )
fi

# -- container runtime ------------------------------------------------
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

if [[ "${RUNTIME}" = "podman" ]]; then
    MOUNT_OPTS=":ro,Z"
else
    MOUNT_OPTS=":ro"
fi

# The scratch directory needs a relabel too, and for the opposite reason: the
# other two mounts are read-only, and this one is the only place the container
# writes. Without :Z on an SELinux host the mount goes through with no error
# and then refuses every write -- "cannot create /work/log.initdb: Permission
# denied" -- which reads like a bundle problem and is not one. The chmod 777
# below covers the ownership half (the container runs as uid 65534, which no
# host account owns under rootless podman); this covers the label half, and
# both are needed.
if [[ "${RUNTIME}" = "podman" ]]; then
    WORK_MOUNT_OPTS=":Z"
else
    WORK_MOUNT_OPTS=""
fi

# -- test payload -----------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}" 2>/dev/null || true' EXIT

cat > "${WORKDIR}/inner.sh" <<'INNER'
#!/bin/sh
# Runs inside the container as an unprivileged user.
set -u

PG=/opt/pg
WORK=/work
PORT=55432

# glibc writes one LD_DEBUG file per process, named <prefix>.<pid>.
export LD_DEBUG=libs
export LD_DEBUG_OUTPUT="${WORK}/ld"
export LC_ALL=C

# initdb creates PGDATA mode 0700 owned by this uid; without relaxing it the
# host cannot remove the scratch directory afterwards.
trap 'chmod -R a+rwX "${WORK}" 2>/dev/null || true' EXIT

FAILURES=0
PASSES=0

ok()  { printf '  PASS  %s\n' "$1"; PASSES=$((PASSES + 1)); }
bad() {
    printf '  FAIL  %s\n' "$1"
    FAILURES=$((FAILURES + 1))
    if [ -s "$2" ]; then
        tail -n 12 "$2" | sed 's/^/        | /'
    fi
}

# run <name> <command...> -- succeeds if the command exits 0
run() {
    name="$1"; shift
    if "$@" >"${WORK}/log.${name}" 2>&1; then
        ok "${name}"
    else
        bad "${name}" "${WORK}/log.${name}"
    fi
}

# expect <name> <needle> <haystack-file> -- succeeds if needle appears
expect() {
    name="$1"; needle="$2"; file="$3"
    if grep -qF -- "${needle}" "${file}" 2>/dev/null; then
        ok "${name}"
    else
        bad "${name}" "${file}"
        printf '        (expected to contain: %s)\n' "${needle}"
    fi
}

# expect_eq <name> <expected> <file> -- succeeds if the file is exactly that
expect_eq() {
    name="$1"; want="$2"; file="$3"
    if [ "$(cat "${file}" 2>/dev/null)" = "${want}" ]; then
        ok "${name}"
    else
        bad "${name}" "${file}"
        printf '        (expected exactly: %s)\n' "${want}"
    fi
}

psql_q() { "${PG}/bin/psql" -h "${WORK}" -p "${PORT}" -U postgres -d postgres -X -q -t -A "$@"; }
psql_c() { "${PG}/bin/psql" -h "${WORK}" -p "${PORT}" -U postgres -d postgres -X -q "$@"; }

# -- 0. toolchain sanity ----------------------------------------------
printf '\n-- version and relocation --\n'
run "psql --version" "${PG}/bin/psql" --version
run "postgres --version" "${PG}/bin/postgres" --version

# -- 1. initdb --------------------------------------------------------
# C.UTF-8 is *not* built into glibc. It is a data directory like any other,
# which is why the bundle ships a copy of it and the launcher points LOCPATH
# at that copy; without the copy this fails with "invalid locale name". The
# test image supplies C.utf8 of its own, so this is not on its own proof that
# the bundled one works -- the bundled-locale check below is.
# Running initdb also exercises getpwuid(), i.e. the bundled glibc's NSS modules.
printf '\n-- initdb --\n'
run "initdb" "${PG}/bin/initdb" -D "${WORK}/data" --locale=C.UTF-8 -U postgres

# -- 1b. bundled locales (--locales) ----------------------------------
# A bundle built with --locales carries locale data for the machine that has
# none. Neither test image has zh_CN or most of the others, so if initdb
# accepts one of these, it can only have come from the bundle. Each directory
# under lib/locale is checked for the full set of categories first: glibc
# fails outright on a locale with a category missing, and a directory holding
# nothing but symlinks into locales that were not copied is the way that
# happens.
if [ -d "${PG}/lib/locale" ]; then
    printf '\n-- bundled locales --\n'
    EXTRA_LOCALE=""
    BUNDLED=0
    for d in "${PG}"/lib/locale/*/; do
        [ -d "$d" ] || continue
        name=${d%/}
        name=${name##*/}
        case "$name" in
            C.utf8|C.UTF-8) continue ;;
        esac
        BUNDLED=$((BUNDLED + 1))
        miss=""
        for cat in LC_CTYPE LC_COLLATE LC_NUMERIC LC_TIME LC_MONETARY \
                   LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE \
                   LC_MEASUREMENT LC_IDENTIFICATION; do
            [ -e "$d$cat" ] || miss="${miss}${miss:+ }${cat}"
        done
        if [ -n "$miss" ]; then
            bad "locale ${name} has every category" /dev/null
            printf '        (missing: %s)\n' "$miss"
        else
            ok "locale ${name} has every category"
        fi
        [ -n "$EXTRA_LOCALE" ] || EXTRA_LOCALE="$name"
    done
    if [ "${BUNDLED}" -eq 0 ]; then
        printf '  (no locales beyond C.UTF-8 in this bundle)\n'
    elif [ -n "$EXTRA_LOCALE" ]; then
        # The directory is already in glibc's folded spelling (zh_CN.utf8), and
        # glibc accepts that spelling as a locale name too, so it can be passed
        # straight through. initdb exits non-zero when the locale cannot be
        # loaded, which on these images means it came from the bundle.
        run "initdb --locale=${EXTRA_LOCALE}" "${PG}/bin/initdb" \
            -D "${WORK}/data-locale" --locale="${EXTRA_LOCALE}" -U postgres
        rm -rf "${WORK}/data-locale"
    fi
fi

# -- 2. start / stop --------------------------------------------------
printf '\n-- start --\n'
run "pg_ctl start" "${PG}/bin/pg_ctl" -D "${WORK}/data" -l "${WORK}/pg.log" \
    -o "-p ${PORT} -k ${WORK}" -w start

if ! psql_q -c 'SELECT 1' >/dev/null 2>&1; then
    printf '\nserver did not come up; see the log above and %s/pg.log\n' "${WORK}"
    tail -n 30 "${WORK}/pg.log" 2>/dev/null | sed 's/^/  | /'
    exit 1
fi

psql_c -c 'SELECT version()' > "${WORK}/version.txt" 2>&1
expect "version string" "PostgreSQL" "${WORK}/version.txt"

# Timezone data is read from share/postgresql, so this only works when the
# compiled-in share directory really did get relocated into the bundle.
psql_q -c "SELECT count(*) FROM pg_timezone_names" > "${WORK}/tz.txt" 2>&1
if [ "$(cat "${WORK}/tz.txt")" -gt 100 ] 2>/dev/null; then
    ok "timezone data (share/ relocation)"
else
    bad "timezone data (share/ relocation)" "${WORK}/tz.txt"
fi

# -- 3. core extensions -----------------------------------------------
printf '\n-- core extensions --\n'
run "CREATE EXTENSION hstore"     psql_c -c 'CREATE EXTENSION hstore'
run "CREATE EXTENSION uuid-ossp"  psql_c -c 'CREATE EXTENSION "uuid-ossp"'
run "CREATE EXTENSION pgcrypto"   psql_c -c 'CREATE EXTENSION pgcrypto'
run "CREATE EXTENSION xml2"       psql_c -c 'CREATE EXTENSION xml2'
run "CREATE EXTENSION pg_trgm"    psql_c -c 'CREATE EXTENSION pg_trgm'
run "CREATE EXTENSION ltree"      psql_c -c 'CREATE EXTENSION ltree'
run "CREATE EXTENSION btree_gist" psql_c -c 'CREATE EXTENSION btree_gist'
run "CREATE EXTENSION unaccent"   psql_c -c 'CREATE EXTENSION unaccent'

psql_q -c "SELECT uuid_generate_v1() IS NOT NULL" > "${WORK}/uuid.txt" 2>&1
expect "uuid-ossp actually runs" "t" "${WORK}/uuid.txt"

# unaccent reads share/postgresql/tsearch_data/unaccent.rules at runtime.
psql_q -c "SELECT unaccent('ecole')" > "${WORK}/unaccent.txt" 2>&1
expect "unaccent rules found in share/" "ecole" "${WORK}/unaccent.txt"

# An ICU collation proves libicudata (the ~30MB ICU data blob) is in the bundle.
run "ICU collation creatable" \
    psql_c -c "CREATE COLLATION de_pb (provider = icu, locale = 'de-u-co-phonebk')"

# NLS catalogues: meson installs them into <prefix>/share/locale directly.
if [ -n "$(find "${PG}/share/locale" -name '*.mo' -print -quit 2>/dev/null)" ]; then
    ok "NLS catalogues bundled (share/locale)"
else
    bad "NLS catalogues bundled (share/locale)" /dev/null
fi

# -- 3b. extensions the bundle built (--extension) --------------------
# The extensions a recipe installed, named from the outside. Two separate
# things get checked, because they fail for unrelated reasons:
#
#   * CREATE EXTENSION runs the extension's own SQL, which is what proves the
#     .control and the script landed in share/postgresql/extension/ and got
#     read from there.
#   * LOAD is what proves the *module* loads. CREATE FUNCTION ... LANGUAGE C
#     only records the library name; the dlopen happens on first call, which
#     for a freshly created extension may never come. LOAD is server-side SQL,
#     so it opens the library in the backend -- where the server's symbols are
#     -- and the external library audit at the end of this script then checks
#     that everything it pulled in came from the bundle and nowhere else.
# The loop variable is deliberately not "name": run() and expect() above are
# POSIX sh functions, so they have no locals, and each one parks its first
# argument in a global "name". A loop that used it too would read back the
# *description* of the last check rather than the extension -- which is how
# "${name}.control" became "CREATE EXTENSION myext.control".
if [ -n "${VERIFY_EXTENSIONS:-}" ]; then
    printf '\n-- extensions named for VERIFY_EXTENSIONS --\n'
    for extname in $(printf '%s' "${VERIFY_EXTENSIONS}" | tr ',' ' '); do
        case "${extname}" in
            ""|.|..|-*|.*|*[!A-Za-z0-9_.-]*)
                printf '  SKIP  %s (not a usable extension name)\n' "${extname}"
                continue
                ;;
        esac
        run "CREATE EXTENSION ${extname}" psql_c -c "CREATE EXTENSION \"${extname}\""

        # module_pathname is how the extension's own SQL names its library, and
        # it is the name LOAD wants too. A pure-SQL extension has none, and
        # then there is nothing to load.
        extmodule=$(sed -n \
            "s/^[[:space:]]*module_pathname[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
            "${PG}/share/postgresql/extension/${extname}.control" 2>/dev/null | head -n 1)
        # The description must stay free of "/": run() writes its output to
        # "${WORK}/log.${name}", so a slash in it names a directory that does
        # not exist and the check fails on the log file rather than on the
        # thing it was checking. Every other caller is slash-free for the same
        # reason.
        if [ -n "${extmodule}" ]; then
            run "LOAD ${extname}" psql_c -c "LOAD '${extmodule}'"
        else
            printf '  ----  %s.control names no module_pathname; nothing to load\n' \
                "${extname}"
        fi
    done
fi

# -- 4. plpgsql -------------------------------------------------------
printf '\n-- plpgsql --\n'
run "CREATE FUNCTION ... LANGUAGE plpgsql" \
    psql_c -c 'CREATE FUNCTION f_plpgsql() RETURNS int AS $$ BEGIN RETURN 42; END $$ LANGUAGE plpgsql'
psql_q -c 'SELECT f_plpgsql()' > "${WORK}/plpgsql.txt" 2>&1
expect "plpgsql call" "42" "${WORK}/plpgsql.txt"

# -- 5. PL/Python, PL/Perl, PL/Tcl ------------------------------------
# These need the interpreter runtimes, not just the shared libraries.
printf '\n-- PL/Python --\n'
if run "CREATE EXTENSION plpython3u" psql_c -c 'CREATE EXTENSION plpython3u'; then
    # sys.prefix must be the bundle root (PYTHONHOME), every existing sys.path
    # entry must live inside it, and an extension module must load from the
    # bundled lib-dynload.
    # Import a module that is linked against libpython rather than statically
    # built into it, so that "an extension module was dlopen'd from the
    # bundle" is actually observable. Debian builds _struct in, ctypes out.
    run "CREATE FUNCTION ... LANGUAGE plpython3u" psql_c -c "CREATE FUNCTION f_py() RETURNS text AS \$\$
import os, sys, glob, ctypes
# The standard library directory is where the running interpreter says it is:
# lib/pythonX.Y on Debian, lib64/pythonX.Y on Fedora and RHEL.
dl = os.path.dirname(os.__file__)
dynload = os.path.join(dl, 'lib-dynload')
outside = [p for p in sys.path if p and os.path.isdir(p)
           and not os.path.realpath(p).startswith('${PG}')]
ext = {n: getattr(m, '__file__', '') for n, m in list(sys.modules.items())
       if getattr(m, '__file__', '').endswith('.so')}
ext_outside = sorted(n for n, f in ext.items() if not f.startswith('${PG}'))
ok = (os.path.realpath(sys.prefix) == '${PG}' and not outside
      and os.path.isdir(dynload) and len(glob.glob(os.path.join(dynload, '*.so'))) > 0
      and len(ext) > 0 and not ext_outside)
return '%s prefix=%s outside=%s dynload=%s ext=%d ext_outside=%s' % (
    'OK' if ok else 'BAD', os.path.realpath(sys.prefix), outside,
    os.path.isdir(dynload), len(ext), ext_outside)
\$\$ LANGUAGE plpython3u"
    psql_q -c 'SELECT f_py()' > "${WORK}/py.txt" 2>&1
    expect "PL/Python runs entirely from the bundle" "OK prefix=${PG} outside=[]" "${WORK}/py.txt"
fi

printf '\n-- PL/Perl --\n'
if run "CREATE EXTENSION plperl" psql_c -c 'CREATE EXTENSION plperl'; then
    # Trusted plperl runs under an opcode mask: require() only returns already
    # loaded modules, and file tests like -d / -e are trapped. So this probe
    # reads %INC for a module plperl's own bootstrap loaded, and checks @INC
    # by string inspection only.
    run "CREATE FUNCTION ... LANGUAGE plperl" psql_c -c "CREATE FUNCTION f_pl() RETURNS text AS \$\$
my (\$sp) = grep { m{/strict\.pm\$} } values %INC;
# How many of perl's system library directories are on @INC is the host's
# business -- Debian has one, Fedora has /usr/share/perl5 and its vendor_perl --
# so report it as a yes/no rather than as a count.
my @priv = grep { index(\$_, '${PG}') == 0 && index(\$_, '/usr/share/perl') >= 0 } @INC;
my \$where = defined \$sp ? \$sp : 'none';
return 'STRICT=' . (defined \$sp && index(\$sp, '${PG}') == 0 ? 'IN_BUNDLE' : \$where)
     . ' PRIVLIB=' . (@priv ? 1 : 0);
\$\$ LANGUAGE plperl"
    psql_q -c 'SELECT f_pl()' > "${WORK}/perl.txt" 2>&1
    expect_eq "PL/Perl resolves its core and pure-Perl modules from the bundle" \
        "STRICT=IN_BUNDLE PRIVLIB=1" "${WORK}/perl.txt"

    # plperlu may require(), so this exercises the real XS-backed parts of perl
    # and the full @INC tree. Note that Debian links every core XS extension
    # statically into libperl (checked: none of the usual candidates register a
    # .so in %INC), so "an XS module was dlopen'd from the bundle" is not
    # something that can be observed here -- what runs is XS compiled into the
    # bundled libperl.so.
    if run "CREATE EXTENSION plperlu" psql_c -c 'CREATE EXTENSION plperlu'; then
        run "CREATE FUNCTION ... LANGUAGE plperlu" psql_c -c "CREATE FUNCTION f_plu() RETURNS text AS \$\$
require List::Util; require Encode;
my \$sum = List::Util::sum(1 .. 10);
my \$enc = length(Encode::encode('UTF-8', chr(0xe9)));
my @bundle_inc = grep { index(\$_, '${PG}') == 0 } @INC;
my \$ok = (\$sum == 55 && \$enc == 2 && @bundle_inc > 0);
return 'RESULT=' . (\$ok ? 'OK' : 'BAD')
     . ' SUM=' . \$sum . ' ENC=' . \$enc . ' BINC=' . scalar(@bundle_inc);
\$\$ LANGUAGE plperlu"
        psql_q -c 'SELECT f_plu()' > "${WORK}/perl_xs.txt" 2>&1
        # RESULT=OK needs XS-backed (List::Util) and encoding (Encode) functions
        # to have run correctly, and the bundle's own @INC trees to be in place.
        # Both modules are there by construction: List::Util is what plperl's own
        # bootstrap uses, so the build needs it whatever the distribution splits;
        # Digest::SHA is core on Debian but a separate package on Fedora.
        expect "PL/Perl(untrusted) runs XS-backed code from the bundled perl" \
            "RESULT=OK " "${WORK}/perl_xs.txt"
    fi
fi

printf '\n-- PL/Tcl --\n'
# Trusted PL/Tcl deliberately runs its interpreter as a *safe* slave and skips
# Tcl_Init on it (pltcl.c:505), so tcl_library and ::env are unavailable there
# by design -- "info library" is expected to fail. The untrusted variant does
# run Tcl_Init, which is where the bundled script library becomes observable.
#
# Which Tcl that is depends on the host the bundle was built on (8.6 on Debian,
# 9.0 on Fedora), so the expected version is read out of the bundle. What the
# checks below are for is that it is the *bundled* interpreter and script
# library, not whatever the test image happens to have.
TCL_BUNDLED="$(basename "$(ls -d "${PG}"/lib/tcl[0-9]* 2>/dev/null | head -n 1 || true)" 2>/dev/null || true)"
TCL_BUNDLED="${TCL_BUNDLED#tcl}"
if run "CREATE EXTENSION pltcl" psql_c -c 'CREATE EXTENSION pltcl'; then
    run "CREATE FUNCTION ... LANGUAGE pltcl" psql_c -c 'CREATE FUNCTION f_tcl() RETURNS text AS $$
return "PATCHLEVEL=[info patchlevel] UNICODE=[string length é]"
$$ LANGUAGE pltcl'
    psql_q -c 'SELECT f_tcl()' > "${WORK}/tcl.txt" 2>&1
    expect "PL/Tcl runs and handles unicode" "PATCHLEVEL=${TCL_BUNDLED}." "${WORK}/tcl.txt"
    expect "PL/Tcl unicode round-trip" "UNICODE=1" "${WORK}/tcl.txt"
fi

if run "CREATE EXTENSION pltclu" psql_c -c 'CREATE EXTENSION pltclu'; then
    run "CREATE FUNCTION ... LANGUAGE pltclu" psql_c -c 'CREATE FUNCTION f_tclu() RETURNS text AS $$
set out "LIBRARY=[info library] "
append out "INIT_TCL=[file exists [file join [info library] init.tcl]]"
return $out
$$ LANGUAGE pltclu'
    psql_q -c 'SELECT f_tclu()' > "${WORK}/tclu.txt" 2>&1
    expect_eq "PL/Tcl(untrusted) uses the bundled script library" \
        "LIBRARY=${PG}/lib/tcl${TCL_BUNDLED} INIT_TCL=1" "${WORK}/tclu.txt"
fi

# Bridge extensions exercise both the PL runtime and the server module path.
printf '\n-- PL bridge extensions --\n'
run "CREATE EXTENSION hstore_plperl"     psql_c -c 'CREATE EXTENSION hstore_plperl'
run "CREATE EXTENSION jsonb_plperl"      psql_c -c 'CREATE EXTENSION jsonb_plperl'
run "CREATE EXTENSION bool_plperl"       psql_c -c 'CREATE EXTENSION bool_plperl'
run "CREATE EXTENSION hstore_plpython3u" psql_c -c 'CREATE EXTENSION hstore_plpython3u'
run "CREATE EXTENSION jsonb_plpython3u"  psql_c -c 'CREATE EXTENSION jsonb_plpython3u'

# -- 6. JIT -----------------------------------------------------------
# The bundle is built without LLVM, so there should be no llvmjit.so and no
# query should be JIT-ed: the provider is what JIT needs, and without one
# expressions are interpreted. That is still asserted rather than skipped --
# a bundle that quietly grew a provider back would otherwise pass this section
# by the section not being there.
# Note: the JIT section of EXPLAIN is suppressed by COSTS OFF (explain.c
# ties it to es->costs), so costs must stay on here.
printf '\n-- JIT --\n'
JIT_QUERY="SET jit_above_cost=0; SET jit_inline_above_cost=0;
    SET jit_optimize_above_cost=0;
    EXPLAIN (ANALYZE) SELECT sum(g*2) FROM generate_series(1,200000) g WHERE g % 7 = 0"
if [ -e "${PG}/lib/postgresql/llvmjit.so" ]; then
    printf '  ----  this bundle carries a JIT provider (built with LLVM)\n'
    run "JIT engages" psql_c -c "${JIT_QUERY}"
    expect "JIT section present" "JIT:" "${WORK}/log.JIT engages"
    expect "JIT expressions compiled" "Expressions true" "${WORK}/log.JIT engages"
else
    run "expensive query still runs" psql_c -c "${JIT_QUERY}"
    if grep -q "JIT:" "${WORK}/log.expensive query still runs" 2>/dev/null; then
        bad "no JIT section without a provider" "${WORK}/log.expensive query still runs"
    else
        ok "no JIT section (no llvmjit.so in this bundle)"
    fi
fi

# -- 7. dump / restore ------------------------------------------------
printf '\n-- pg_dump / pg_restore --\n'
run "create dump source"  psql_c -c 'CREATE DATABASE dumptest'
run "populate"            psql_c -d dumptest -c 'CREATE TABLE t(a int); INSERT INTO t SELECT generate_series(1,1000)'
run "pg_dump -Fc"         "${PG}/bin/pg_dump" -h "${WORK}" -p "${PORT}" -U postgres -Fc -d dumptest -f "${WORK}/dumptest.dump"
run "create restore target" psql_c -c 'CREATE DATABASE restoretest'
run "pg_restore"          "${PG}/bin/pg_restore" -h "${WORK}" -p "${PORT}" -U postgres -d restoretest "${WORK}/dumptest.dump"
psql_q -d restoretest -c 'SELECT count(*) FROM t' > "${WORK}/restored.txt" 2>&1
expect "restored row count" "1000" "${WORK}/restored.txt"

# -- 8. restart with shared_preload_libraries -------------------------
# Loading a module at postmaster startup resolves $libdir, which is the
# clearest test of the pkglibdir relocation.
printf '\n-- shared_preload_libraries --\n'
run "pg_ctl restart with preload" "${PG}/bin/pg_ctl" -D "${WORK}/data" -l "${WORK}/pg.log" \
    -o "-p ${PORT} -k ${WORK} -c shared_preload_libraries=pg_stat_statements" -w restart
run "CREATE EXTENSION pg_stat_statements" psql_c -c 'CREATE EXTENSION pg_stat_statements'
psql_q -c 'SELECT count(*) > 0 FROM pg_stat_statements' > "${WORK}/pss.txt" 2>&1
expect "pg_stat_statements usable" "t" "${WORK}/pss.txt"

# -- 9. stop ----------------------------------------------------------
printf '\n-- stop --\n'
run "pg_ctl stop" "${PG}/bin/pg_ctl" -D "${WORK}/data" -w -m fast stop

# -- 10. external library audit ---------------------------------------
# Each bundle binary is reached through a "#!/bin/sh" wrapper, so the process
# first runs the *container's* shell and only then exec()s the bundled loader
# in place. LD_DEBUG appends to the same per-pid file across that exec, so only
# the loads from the first bundle load onwards belong to the bundle program.
printf '\n-- external library audit --\n'
: > "${WORK}/outside.txt"
BUNDLE_PROCS=0
for f in "${WORK}"/ld.*; do
    [ -f "$f" ] || continue
    first=$(grep -n -m1 -F "calling init: ${PG}/" "$f" 2>/dev/null | cut -d: -f1)
    [ -n "${first}" ] || continue
    BUNDLE_PROCS=$((BUNDLE_PROCS + 1))
    tail -n +"${first}" "$f" \
        | sed -n 's/.*calling init: \(\/[^ ]*\).*/\1/p' \
        | sort -u | grep -v "^${PG}/" >> "${WORK}/outside.txt" || true
done
sort -u "${WORK}/outside.txt" -o "${WORK}/outside.txt" 2>/dev/null || true

if [ "${BUNDLE_PROCS}" -eq 0 ]; then
    bad "external library audit (no bundle processes seen)" /dev/null
elif [ -s "${WORK}/outside.txt" ]; then
    bad "external library audit" "${WORK}/outside.txt"
    printf '        (%s bundle processes inspected)\n' "${BUNDLE_PROCS}"
else
    ok "external library audit (${BUNDLE_PROCS} bundle processes, 0 outside loads)"
fi

printf '\n%s passed, %s failed\n' "${PASSES}" "${FAILURES}"
[ "${FAILURES}" -eq 0 ]
INNER

# -- run the payload in each image ------------------------------------
# Each image gets its own scratch directory so leftovers from one run cannot
# make the next one fail with "already exists".
OVERALL=0
INDEX=0
for IMAGE in "${IMAGES[@]}"; do
    INDEX=$((INDEX + 1))
    IMGDIR="${WORKDIR}/work-${INDEX}"
    mkdir -p "${IMGDIR}"
    chmod 777 "${IMGDIR}"

    echo ""
    echo "================================================================"
    echo "== ${IMAGE}"
    echo "================================================================"

    # --user 65534 ("nobody"): PostgreSQL refuses to run as root, and this uid
    # exists in every base image.
    if "${RUNTIME}" run --rm \
        --user 65534:65534 \
        -e HOME=/work \
        -e "VERIFY_EXTENSIONS=${VERIFY_EXTENSIONS:-}" \
        -v "${BUNDLE_ABS}:/opt/pg${MOUNT_OPTS}" \
        -v "${IMGDIR}:/work${WORK_MOUNT_OPTS}" \
        -v "${WORKDIR}/inner.sh:/inner.sh${MOUNT_OPTS}" \
        "${IMAGE}" /bin/sh /inner.sh; then
        echo "== ${IMAGE}: OK"
    else
        echo "== ${IMAGE}: FAILED"
        OVERALL=1
    fi
done

echo ""
if [[ "${OVERALL}" -eq 0 ]]; then
    echo "=== All images passed ==="
else
    echo "=== Verification FAILED ==="
fi
exit "${OVERALL}"
