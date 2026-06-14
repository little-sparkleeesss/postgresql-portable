#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/cache}"
PG_FTP_BASE="https://ftp.postgresql.org/pub/source"

# ── usage ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 <version> [--full] [--no-download] [--cache-dir DIR]

Examples:
  $0 18.4              build client-only portable bundle
  $0 18.4 --full       build client + server portable bundle
  $0 19beta1 --full    build PG 19 beta 1 with all features
  $0 18.4 --no-download   skip download, use existing cache
  $0 /path/to/pg-src   build from local source tree
  CACHE_DIR=/tmp/pg $0 18.4   use custom cache directory

EOF
    exit 1
}

# ── argument parsing ─────────────────────────────────────────────────
SKIP_DOWNLOAD=false
BUILD_FULL=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            BUILD_FULL=true
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

# ── determine source directory ───────────────────────────────────────
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

    # ── download ─────────────────────────────────────────────────────
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

        # ── verify sha256 ────────────────────────────────────────────
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

    # ── extract ──────────────────────────────────────────────────────
    if [[ -d "${SRC_DIR}" ]]; then
        echo "Source already extracted: ${SRC_DIR}"
    else
        echo "Extracting: ${CACHE_DIR}/${TARBALL}"
        tar -xjf "${CACHE_DIR}/${TARBALL}" -C "${CACHE_DIR}"
        echo "Extraction complete: ${SRC_DIR}"
    fi
fi

# ── build ────────────────────────────────────────────────────────────
OUT_DIR="${SCRIPT_DIR}/output/${VERSION}"

echo "=== Building podman image ==="
podman build -t pg18-builder "${SCRIPT_DIR}"

mkdir -p "${OUT_DIR}"

BUILD_MODE="client"
if [[ "${BUILD_FULL}" = true ]]; then
    BUILD_MODE="full"
fi

echo ""
echo "=== Running build container ==="
echo "Source: ${SRC_DIR}"
echo "Output: ${OUT_DIR}"
echo "Version: ${VERSION}"
echo "Mode: ${BUILD_MODE}"

podman run --rm \
    -e "PG_VERSION=${VERSION}" \
    -e "BUILD_MODE=${BUILD_MODE}" \
    -v "${SRC_DIR}:/src:ro,Z" \
    -v "${OUT_DIR}:/out:Z" \
    pg18-builder

echo ""
echo "=== Done ==="
echo "Result: ${OUT_DIR}/"
ls -la "${OUT_DIR}/"
echo ""
echo "Run with: ${OUT_DIR}/bin/psql"
