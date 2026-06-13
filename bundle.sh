#!/bin/bash
set -euo pipefail

SRC="${SRC:-/src}"
OUT="${OUT:-/out}"
PG_VERSION="${PG_VERSION:-unknown}"
BUILD_MODE="${BUILD_MODE:-client}"
PREFIX="/tmp/pg-install"
BUILDDIR="/tmp/pgsrc"
BUNDLE="${OUT}/postgresql-${PG_VERSION}"

echo "=== Building PostgreSQL ${PG_VERSION} portable bundle (mode: ${BUILD_MODE}) ==="

# ── Build ──────────────────────────────────────────────────────────────
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

    if [[ "${BUILD_MODE}" = "full" ]]; then
        echo "=== Mode: FULL (client + server, all features enabled) ==="
        meson setup build \
            "${COMMON_OPTS[@]}" \
            -Dnls=enabled \
            -Dplperl=enabled \
            -Dplpython=enabled \
            -Dpltcl=enabled \
            -Ddtrace=auto \
            -Dllvm=enabled \
            -Dselinux=enabled \
            -Dsystemd=enabled \
            -Dicu=enabled \
            -Dlibxslt=enabled \
            -Duuid=e2fs
    else
        echo "=== Mode: CLIENT (client tools only, minimal deps) ==="
        meson setup build \
            "${COMMON_OPTS[@]}" \
            -Dnls=disabled \
            -Dplperl=disabled \
            -Dplpython=disabled \
            -Dpltcl=disabled \
            -Ddtrace=disabled \
            -Dllvm=disabled \
            -Dselinux=disabled \
            -Dsystemd=disabled \
            -Dicu=disabled \
            -Dlibxslt=disabled \
            -Dlibnuma=disabled \
            -Dliburing=disabled \
            -Duuid=none
    fi

echo "=== Step 2: Compile ==="
meson compile -C build

echo "=== Step 3: Install ==="
meson install -C build

fi  # end of SKIP_BUILD check

echo "=== Installed binaries ==="
ls -la "${PREFIX}/bin/"

# ── Bundle ─────────────────────────────────────────────────────────────
echo "=== Step 4: Prepare bundle ==="
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/bin" "${BUNDLE}/lib"

echo "=== Step 5: Copy binaries ==="
cp "${PREFIX}/bin/"* "${BUNDLE}/bin/" 2>/dev/null || true

echo "=== Step 6: Collect shared library deps (via ldd) ==="
declare -A seen_libs

for bin in "${BUNDLE}/bin/"*; do
    [[ -f "${bin}" && -x "${bin}" ]] || continue
    echo "  Analyzing: $(basename "${bin}")"
    # Use process substitution to avoid subshell (pipe would lose seen_libs)
    while read -r line; do
        if [[ "${line}" =~ =\>[[:space:]]+(.+)[[:space:]]+\( ]]; then
            libpath="${BASH_REMATCH[1]}"
            libname="$(basename "${libpath}")"
            if [[ -n "${libpath}" && -f "${libpath}" ]]; then
                if [[ -z "${seen_libs[${libname}]:-}" ]]; then
                    seen_libs["${libname}"]="${libpath}"
                fi
            fi
        fi
    done < <(ldd "${bin}" 2>/dev/null)
done

echo "  Found ${#seen_libs[@]} unique library names"

echo "=== Step 7: Copy libraries ==="
for libname in "${!seen_libs[@]}"; do
    src="${seen_libs[${libname}]}"
    dst="${BUNDLE}/lib/${libname}"
    if [[ -f "${src}" ]]; then
        cp -L "${src}" "${dst}" 2>/dev/null || true
        echo "  ${libname}"
    fi
done

echo "=== Step 8a: Copy libpq from install prefix ==="
# libpq is installed to lib directory, not scanned by ldd since build used rpath=false
for libdir in ${PREFIX}/lib ${PREFIX}/lib64; do
    if ls "${libdir}"/libpq.so* >/dev/null 2>&1; then
        cp -L "${libdir}"/libpq.so* "${BUNDLE}/lib/" 2>/dev/null || true
        echo "  Copied libpq from ${libdir}"
        break
    fi
done
for libdir in ${PREFIX}/lib ${PREFIX}/lib64; do
    for libpfx in libecpg libpgtypes; do
        if ls "${libdir}/${libpfx}.so"* >/dev/null 2>&1; then
            cp -L "${libdir}/${libpfx}.so"* "${BUNDLE}/lib/" 2>/dev/null || true
        fi
    done
done

echo "=== Step 8b: Copy ld-linux ==="
LD_LINUX=$(find /lib* /usr/lib* -maxdepth 1 -name 'ld-linux-x86-64.so*' 2>/dev/null | head -1)
if [[ -n "${LD_LINUX}" && -f "${LD_LINUX}" ]]; then
    cp -L "${LD_LINUX}" "${BUNDLE}/lib/$(basename "${LD_LINUX}")"
    echo "  Copied: $(basename "${LD_LINUX}")"
else
    echo "  WARNING: ld-linux-x86-64.so not found"
fi

echo "=== Step 9: Patch RPATH on all ELF files ==="
# Critical system libs that must NOT be patched (glibc + dynamic linker)
no_patch="ld-linux|libc\.so|libm\.so|libresolv\.so|libpthread\.so|libdl\.so|libnss_"
for f in "${BUNDLE}/bin/"* "${BUNDLE}/lib/"*; do
    [[ -f "${f}" ]] || continue
    bname="$(basename "${f}")"
    if echo "${bname}" | grep -qE "${no_patch}"; then
        echo "  Skipped (system): ${bname}"
        continue
    fi
    ft=$(file -b "${f}" 2>/dev/null || true)
    if echo "${ft}" | grep -qE 'ELF.*(executable|shared object)'; then
        patchelf --remove-rpath "${f}" 2>/dev/null || true
        patchelf --set-rpath '$ORIGIN/../lib' "${f}" 2>/dev/null || true
        echo "  Patched: $(basename "${f}")"
    fi
done

echo "=== Step 10: Handle libpq symlinks ==="
cd "${BUNDLE}/lib"
if [[ -f libpq.so.5.18 ]]; then
    ln -sf libpq.so.5.18 libpq.so.5 2>/dev/null || true
    ln -sf libpq.so.5.18 libpq.so 2>/dev/null || true
    echo "  libpq symlinks created"
fi

echo "=== Step 11: Set interpreter + RPATH (replace wrapper scripts) ==="
LD_LINUX_NAME="ld-linux-x86-64.so.2"
# Use a short path that the user creates a symlink for via setup.sh
INTERP_PATH="/tmp/.pg/lib/${LD_LINUX_NAME}"

for bin in "${BUNDLE}/bin/"*; do
    [[ -f "${bin}" ]] || continue
    bname="$(basename "${bin}")"
    ft=$(file -b "${bin}" 2>/dev/null || true)
    if echo "${ft}" | grep -qE 'ELF.*executable'; then
        # Set interpreter to bundled ld-linux via a fixed symlink path
        patchelf --set-interpreter "${INTERP_PATH}" "${bin}" 2>/dev/null || {
            echo "  WARNING: --set-interpreter failed for ${bname}, keeping wrapper"
            mv "${bin}" "${bin}.real"
            cat > "${bin}" <<'WRAPOF'
#!/bin/sh
DIR="$(dirname "$(readlink -f "$0")")"
BASENAME="$(basename "$0")"
exec "${DIR}/../lib/ld-linux-x86-64.so.2" --library-path "${DIR}/../lib" "${DIR}/${BASENAME}.real" "$@"
WRAPOF
            chmod +x "${bin}"
        }
        echo "  Interpreter: ${bname}"
    fi
done

# Create setup.sh that creates the symlink needed by the interpreter
cat > "${BUNDLE}/setup.sh" <<SETUPEOF
#!/bin/sh
# Create the symlink that patchelf'd binaries expect for their interpreter
BUNDLE_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
INTERP_LINK="${INTERP_PATH}"
INTERP_SRC="\${BUNDLE_DIR}/lib/${LD_LINUX_NAME}"

mkdir -p "\$(dirname "\${INTERP_LINK}")"
if [ ! -f "\${INTERP_LINK}" ]; then
    ln -sf "\${INTERP_SRC}" "\${INTERP_LINK}" 2>/dev/null || {
        # If can't symlink (no permission), try copying
        cp "\${INTERP_SRC}" "\${INTERP_LINK}" 2>/dev/null || true
    }
    echo "Interpreter link created: \${INTERP_LINK} -> \${INTERP_SRC}"
else
    echo "Interpreter link already exists: \${INTERP_LINK}"
fi
echo "Portable PostgreSQL ready at: \${BUNDLE_DIR}"
echo ""
echo "Usage:"
echo "  \${BUNDLE_DIR}/bin/psql -h host -U user"
echo "  \${BUNDLE_DIR}/bin/initdb -D /path/to/data   # full mode"
echo "  \${BUNDLE_DIR}/bin/pg_ctl -D /path/to/data start  # full mode"
SETUPEOF
chmod +x "${BUNDLE}/setup.sh"
echo "  Created setup.sh"

# ── Full-mode extras ─────────────────────────────────────────────────
if [[ "${BUILD_MODE}" = "full" ]]; then
    echo "=== Step 11b: Copy server extensions and share data (full mode) ==="

    # Server extension .so files
    for extdir in ${PREFIX}/lib/postgresql; do
        if [[ -d "${extdir}" ]]; then
            mkdir -p "${BUNDLE}/lib/postgresql"
            cp -r "${extdir}/"* "${BUNDLE}/lib/postgresql/" 2>/dev/null || true
            echo "  Copied server extensions from ${extdir}"
            break
        fi
    done

    # Share data (timezones, extension SQL, sample configs)
    if [[ -d "${PREFIX}/share/postgresql" ]]; then
        mkdir -p "${BUNDLE}/share"
        cp -r "${PREFIX}/share/postgresql" "${BUNDLE}/share/"
        echo "  Copied share/postgresql/"
    fi

    # Patch RPATH on server extension .so files
    no_patch="ld-linux|libc\.so|libm\.so|libresolv\.so|libpthread\.so|libdl\.so|libnss_"
    for ext in "${BUNDLE}/lib/postgresql/"*.so; do
        [[ -f "${ext}" ]] || continue
        patchelf --remove-rpath "${ext}" 2>/dev/null || true
        patchelf --set-rpath '$ORIGIN/..' "${ext}" 2>/dev/null || true
    done
    echo "  Patched RPATH on server extensions"
fi

echo "=== Step 12: Verify ==="
echo ""
echo "--- bin/ ---"
ls -la "${BUNDLE}/bin/"
echo ""
echo "--- lib/ (count: $(ls -1 "${BUNDLE}/lib/" | wc -l)) ---"
ls -la "${BUNDLE}/lib/"
echo ""
echo "--- Running setup.sh (creates interpreter symlink) ---"
if [[ -x "${BUNDLE}/setup.sh" ]]; then
    "${BUNDLE}/setup.sh" 2>&1 || true
fi
echo ""
echo "--- ldd psql ---"
if [[ -f "${BUNDLE}/bin/psql" ]]; then
    ldd "${BUNDLE}/bin/psql" 2>&1 || true
fi
echo ""
echo "--- Testing psql --version ---"
if [[ -x "${BUNDLE}/bin/psql" ]]; then
    "${BUNDLE}/bin/psql" --version 2>&1 || true
fi
if [[ "${BUILD_MODE}" = "full" ]]; then
    echo ""
    echo "--- Testing postgres --version ---"
    if [[ -x "${BUNDLE}/bin/postgres" ]]; then
        "${BUNDLE}/bin/postgres" --version 2>&1 || true
    fi
    echo "--- Server extensions ---"
    ls "${BUNDLE}/lib/postgresql/" 2>/dev/null | head -10 || echo "  (none)"
    echo "--- Share data ---"
    ls "${BUNDLE}/share/postgresql/" 2>/dev/null | head -10 || echo "  (none)"
fi

echo ""
echo "=== Build complete! ==="
echo "Output: ${BUNDLE}"
cd "${BUNDLE}/.."
du -sh "$(basename "${BUNDLE}")"
