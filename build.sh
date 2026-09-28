#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/cache}"
PG_FTP_BASE="https://ftp.postgresql.org/pub/source"

# -- usage ------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 <version> [--full] [--no-download] [--cache-dir DIR]

Modes:
  (default)   client tools      -> output/<version>
  --full      client + server   -> output/<version>-full

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

Examples:
  $0 18.4                 client bundle          -> output/18.4
  $0 18.4 --full          client + server bundle -> output/18.4-full
  $0 19beta1 --full       build PG 19 beta 1 (all features enabled)
  $0 18.4 --no-download   skip download, use existing cache
  $0 /path/to/pg-src      build from local source tree
  CACHE_DIR=/tmp/pg $0 18.4   use custom cache directory

EOF
    exit 1
}

# -- argument parsing -------------------------------------------------
SKIP_DOWNLOAD=false
BUILD_MODE="client"
VERSION=""

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
# Rootless podman is the preferred runtime. Docker is a fallback; note that
# its daemon normally runs as root, so only use it where that is acceptable.
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

# -- build ------------------------------------------------------------
case "${BUILD_MODE}" in
    client) OUT_SUFFIX="";      MODE_DESC="client tools only" ;;
    full)   OUT_SUFFIX="-full"; MODE_DESC="client + server tools" ;;
esac
OUT_DIR="${SCRIPT_DIR}/output/${VERSION}${OUT_SUFFIX}"

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
    -v "${SRC_DIR}:/src${SRC_MOUNT_OPTS}" \
    -v "${OUT_DIR}:/out${OUT_MOUNT_OPTS}" \
    pg18-builder

echo ""
echo "=== Done ==="
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
        echo "Start it with:"
        echo "  ${OUT_DIR}/bin/pg_ctl -D /path/to/pgdata -l /tmp/pg.log -o \"-p 5433 -k /tmp\" start"
        echo "Connect with:"
        echo "  ${OUT_DIR}/bin/psql -h /tmp -p 5433 -U postgres"
        ;;
esac
