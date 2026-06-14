# pg-portable

Build portable PostgreSQL client tools for any x86_64 Linux system — no installation required.

Given a version number, it automatically downloads the official source tarball, verifies the SHA256 checksum, compiles inside a rootless podman container, and bundles all binaries together with their shared libraries. Copy the output folder anywhere and run.

## Quick start

```bash
./build.sh 18.4
```

This downloads PostgreSQL 18.4, builds it, and produces `output/18.4/`. Then:

```bash
output/18.4/bin/psql -h myhost -U myuser
```

## Features

- **Zero host dependencies** — only podman (rootless) and curl are required
- **Auto-download + verify** — fetches from `ftp.postgresql.org` and checks SHA256
- **Source caching** — downloaded tarballs and extracted sources are reused across builds
- **Bundled libraries** — every shared library dependency (OpenSSL, Kerberos, LDAP, readline, zstd, …) is included
- **Cross-distro** — runs on any x86_64 Linux with kernel ≥ 5.x (tested: Debian → Ubuntu)

## Requirements

| Tool  | Minimum version |
|-------|-----------------|
| podman (rootless) | 4.x+ |
| curl | any |
| bash | 4.x+ |
| sha256sum | any (coreutils) |

## Usage

```bash
./build.sh <version> [options]
```

### Examples

```bash
# Stable release
./build.sh 18.4

# Beta / RC
./build.sh 19beta1

# Skip download — use previously cached source
./build.sh 18.4 --no-download

# Build from a local source tree
./build.sh /home/user/postgresql-18.4

# Custom cache directory
CACHE_DIR=/tmp/pg-cache ./build.sh 18.4
```

### Options

| Option | Description |
|--------|-------------|
| `--no-download` | Skip downloading; fail if tarball is not cached |
| `--cache-dir DIR` | Set cache directory (default: `./cache`) |

## Output

```
output/18.4/
├── bin/
│   ├── psql              ← shell wrapper
│   ├── psql.real         ← real binary
│   ├── pg_dump / .real
│   ├── pg_restore / .real
│   └── … (37 tools)
└── lib/
    ├── ld-linux-x86-64.so.2   ← bundled dynamic linker
    ├── libpq.so.5 → libpq.so.5.18
    ├── libssl.so.3
    ├── libcrypto.so.3
    ├── libreadline.so.8
    └── … (41 libraries)
```

The wrapper scripts invoke the real binaries through the bundled `ld-linux`, ensuring the bundled `libc.so.6` and other libraries are used instead of whatever the host system provides.

## How it works

### build.sh (host side)

1. Parses the version argument
2. Downloads `postgresql-{version}.tar.bz2` and its `.sha256` from the official PostgreSQL FTP
3. Verifies the checksum
4. Extracts the source (cached for future runs)
5. Builds the podman image from `Containerfile`
6. Runs the container with the source (read-only) and output directory mounted

### bundle.sh (inside container)

1. **meson setup** — configures the build with SSL, GSSAPI, LDAP, readline, zstd, LZ4 enabled
2. **meson compile** — builds the full project (client + server + contrib)
3. **meson install** — installs to a staging prefix
4. Copies all binaries to the bundle
5. Runs `ldd` on every binary, collects all unique shared library paths
6. Copies those `.so` files to `lib/` (including glibc components and `ld-linux`)
7. Runs `patchelf --set-rpath '$ORIGIN/../lib'` on every ELF file (except glibc itself and ld-linux)
8. Creates shell wrappers that launch each binary through the bundled dynamic linker

## Directory structure

```
pg18-portable/
├── build.sh              # Entry point: download → verify → build
├── bundle.sh             # Container entrypoint: compile → collect → patch → wrap
├── Containerfile         # Build environment (Debian Bookworm + TUNA mirror)
├── LICENSE               # MIT
├── README.md
├── cache/                # Downloaded tarballs and extracted source
└── output/
    └── {version}/
        ├── bin/
        └── lib/
```

## License

MIT — see [LICENSE](LICENSE).
