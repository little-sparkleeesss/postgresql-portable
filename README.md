# pg-portable

Build portable PostgreSQL bundles for any x86_64 Linux system — no installation required.

Given a version number, it automatically downloads the official source tarball, verifies the SHA256 checksum, compiles inside a container, and bundles the binaries together with everything they load at runtime. Copy the output folder anywhere and run.

Two flavours:

| Command | Output | Contents |
|---------|--------|----------|
| `./build.sh 18.4` | `output/18.4/` | Client tools (`psql`, `pg_dump`, …) |
| `./build.sh 18.4 --full` | `output/18.4-full/` | Client **and** server tools, plus all contrib extensions, the `share/` data tree and the PL interpreter runtimes |

Which program counts as a client or a server tool is the split the upstream
documentation draws between *PostgreSQL Client Applications* and *PostgreSQL
Server Applications*: 21 client programs and 14 server programs, plus
`oid2name` and `vacuumlo` — contrib frontends that are not in either list but
are libpq clients. The two lists live at the top of `bundle.sh`.

The client half then adds the one helper program its own tools reach across the
line for: `pg_verifybackup` runs `pg_waldump`. That makes a client bundle 24
programs instead of 23 — the tools that are in there work, rather than dying
with "program not found in the same directory as".

The flavours can coexist; they are separate builds with different tool sets and
different feature sets.

There is no server-only flavour. It would drop 19 client programs and **not one
shared library** — its `lib/` and `share/` would be byte-identical to `--full`'s
— for 2.8 MiB, while having to ship `psql`, `pg_dump`,
`pg_dumpall` and `pg_restore` anyway, for `pg_upgrade`. Passing `--server` fails
with a pointer to `--full`.

## Quick start

Client:

```bash
./build.sh 18.4
output/18.4/bin/psql -h myhost -U myuser
```

Server, with client tools in the same bundle:

```bash
./build.sh 18.4 --full

cd output/18.4-full
./bin/initdb -D /path/to/pgdata --locale=C.UTF-8 -U myuser
./bin/pg_ctl -D /path/to/pgdata -l /tmp/pg.log -o "-p 5433 -k /tmp" start
./bin/psql -h /tmp -p 5433 -U myuser postgres
./bin/pg_ctl -D /path/to/pgdata stop -m fast
```

## Features

- **Zero host dependencies** — only podman (rootless) or docker and curl are required to *build*
- **Auto-download + verify** — fetches from `ftp.postgresql.org` and checks SHA256
- **Source caching** — downloaded tarballs and extracted sources are reused across builds
- **Bundled libraries** — every shared library the binaries load (OpenSSL, Kerberos, LDAP, ICU, LLVM, readline, zstd, …) is included, plus the glibc the binaries were built against
- **Bundled interpreter runtimes** (`--full`) — the Python, Perl and Tcl runtimes that PL/Python, PL/Perl and PL/Tcl need
- **Selectable locales** (`--locales`) — carry the glibc locale data for the languages you need, so `initdb --locale=zh_CN.UTF-8` works on a host that has no locales of its own
- **Cross-distro** — runs on any x86_64 Linux with kernel ≥ 5.x (verified: Debian bookworm → Debian bookworm and Rocky Linux 9)
- **Optional host build** (`--without-container`) — compile without a container runtime at all; what the toolchain is missing is probed for and installed through apt or dnf

## Requirements

| Tool  | Minimum version |
|-------|-----------------|
| podman (rootless) or docker | 4.x+ / 20.x+ |
| curl | any |
| bash | 4.x+ |
| sha256sum | any (coreutils) |

With `--without-container` no container runtime is needed; the build toolchain
(gcc, meson, ninja, bison, flex, patchelf, the `-dev` packages of OpenSSL,
Kerberos, LDAP, ICU, LLVM, …) is installed on the host instead, through apt
(Debian, Ubuntu) or dnf (Fedora, RHEL, Rocky).

## Usage

```bash
./build.sh <version> [options]
```

### Examples

```bash
# Client bundle (default)
./build.sh 18.4

# Newest 18.x, whatever that is today — always lands in output/18/
./build.sh 18

# Client + server bundle, all features enabled
./build.sh 18.4 --full

# …and able to run initdb --locale=zh_CN.UTF-8 on a host that has no locales
./build.sh 18.4 --full --locales=zh_CN.UTF-8,en_US.UTF-8

# Beta / RC
./build.sh 19beta1 --full

# Skip download — use previously cached source
./build.sh 18.4 --no-download

# Build from a local source tree
./build.sh /home/user/postgresql-18.4

# Custom cache directory
CACHE_DIR=/tmp/pg-cache ./build.sh 18.4

# Build on this machine, installing whatever the toolchain is missing
./build.sh 18.4 --full --without-container
```

### Versions

`<version>` is one of three things:

| Form | Meaning |
|------|---------|
| `18.4` | That release, named exactly as upstream names it |
| `18` | The newest `18.x`, resolved at build time |
| `19beta1` | A beta or release candidate, which upstream does not name `<major>.x` and so has to be spelled out |

`18` is resolved against the directory index the tarball itself comes from, so
whatever it names can actually be downloaded.

**The output directory is named after the version as asked for, not as
resolved.** `./build.sh 18` always produces `output/18/` — `output/18-full/` with
`--full` — so a CI job can hardcode the path while the release inside it follows
upstream. The tarball, the extracted tree and the version compiled into the
bundle are all the concrete release, and the build reports which one that was.
A version given in full resolves to itself, so `./build.sh 18.6` still produces
`output/18.6/`, and nothing changes for it.

Two details of that index shape the result. It is not dense — numbers get
skipped when a release is withdrawn, so `18.5` may never exist while `18.6`
does — which is why the answer is the highest one listed and never "the
previous plus one". And the entries are compared with `sort -V`, because a
plain sort puts `17.9` above `17.11`.

With `--no-download` there is no index to read, so `18` means the newest `18.x`
**in the cache**, and the build says so: that choice can be older than what
upstream has.

### Options

| Option | Description |
|--------|-------------|
| `--full` | Build the client + server bundle (both tool sets) |
| `--locales=LIST` | Carry these glibc locales besides `C.UTF-8`: comma separated names, or `all`. Needs `--full` |
| `--no-download` | Skip downloading; fail if tarball is not cached |
| `--cache-dir DIR` | Set cache directory (default: `./cache`) |
| `--without-container` | Compile on the host instead of in a container |
| `--skip-deps` | With `--without-container`: report missing dependencies but install nothing |
| `--yes` | Do not ask before installing packages |

The container runtime is chosen automatically: `podman` if present, otherwise
`docker`. Override with `CONTAINER_RUNTIME=podman|docker`.

### Locales

`--locales` decides which glibc locale *data* the bundle carries, on top of the
`C.UTF-8` that every `--full` bundle already has. That is a different thing from
the message catalogues under `share/locale`, which translate PostgreSQL's own
output and are always complete.

| Value | Effect | Cost |
|-------|--------|------|
| *(omitted)* | `C.UTF-8` only, as before | — |
| `--locales=zh_CN.UTF-8,en_US.UTF-8` | those locales | about 0.4–3 MB each |
| `--locales=all` | every locale the build image has | about 230 MB |

Without it, `initdb --locale=zh_CN.UTF-8` fails on a bare host with `invalid
locale name`; with it, the locale comes from the bundle. Two things worth
knowing before using it:

- **The launcher then sets `LOCPATH`.** glibc searches `LOCPATH` *in addition to*
  its own directory, but it consults a `locale-archive` only when `LOCPATH` is
  unset — so on a host that keeps its locales in an archive, those stop being
  visible. The server note below spells that out; it is the one real cost.
- **`all` means "whatever the build image has"**, so a bundle built on Debian and
  one built on Rocky do not carry quite the same set.

The data comes from the build image, where `locales-all` ships each locale as a
directory under `/usr/lib/locale`. Those directories are largely symlinks into
*each other* — Debian's `zh_CN.utf8` points eight of its twelve categories at
`yue_HK`, `bo_CN`, `ug_CN`, `aa_DJ.utf8` and `cmn_TW` — so a locale named on the
command line is copied with its links resolved: a link into a locale that was not
asked for would otherwise dangle. `all` keeps the links, because there the whole
set is present for them to resolve against.

Host builds need the same data. `locales-all` provides it; so does the much
smaller `locales` package, whose definitions `bundle.sh` compiles with
`localedef` instead of copying.

### Building on the host

`--without-container` compiles in the working copy of the source tree and needs
the same toolchain the `Containerfile` installs, so the build starts by probing
the host for it. Only what is actually missing is installed, and the package
list is shown with the exact command before anything runs — answer the prompt or
pass `--yes`. Which package that is is left to the package manager rather than
to a hardcoded name, so a distribution that renames, splits or merges a package
still works.

```
=== Host build: checking build dependencies (dnf) ===
  ldap        openldap-devel   (for lib:ldap:ldap.h)
  zlib        zlib-ng-compat-devel   (for lib:zlib:zlib.h)
  ...
  perl-build  perl-FindBin perl-File-Basename perl-Getopt-Long perl-Scalar-List-Utils   (for fn:perl_build_mods)
  perl-mods   perl-Opcode perl-ExtUtils-Embed perl-ExtUtils-ParseXS   (for fn:perl_mods)
  ...
  tclsh       tcl   (for cmd:tclsh,tclsh8.6,tclsh8.7)

Install with:
  sudo dnf install -y gcc meson ninja-build ... perl-FindBin ... tcl
```

On dnf the table names a *provide* — `pkgconfig(zlib)`, a header path, a binary
path — and dnf resolves it to whichever package provides it today; on Debian
that package is `zlib1g-dev`, on Fedora `zlib-ng-compat-devel`, and neither is
written down anywhere. apt has no such index to search, so candidate names are
tried against the package index and, when every one of them is gone, the index
is searched for the closest `*-dev` name.

Fedora splits core perl into one package per module, which is where that shows
its teeth: PostgreSQL's build scripts need `FindBin` before a single file
compiles, and Fedora keeps it in `perl-FindBin`, so a build that only installed
"perl" dies minutes in with `Can't locate FindBin.pm in @INC`.

Nothing is installed that the table does not know about. When meson stops on
something it cannot find — which is how a dependency a newer PostgreSQL release
brings with it shows up — the failure quotes meson's line and says that the
answer is a row in that table (and, for container builds, a package in the
`Containerfile`).

A host build is a normal build otherwise: it produces the same bundle layout
into `output/<version>[-full]`, built against the host's glibc rather
than the build image's.

## Output

```
output/18.4-full/
├── bin/
│   ├── psql                ← shell wrapper
│   ├── psql.real           ← real binary
│   ├── postgres / postgres.real
│   ├── initdb, pg_ctl, pg_dump, pg_restore, … (37 tools in total)
├── lib/
│   ├── ld-linux-x86-64.so.2      ← bundled dynamic linker
│   ├── libc.so.6, libssl.so.3, libLLVM-14.so.1, libicudata.so.72, …
│   ├── libnss_files.so.2         ← glibc dlopen()s these, ldd never shows them
│   ├── libpq.so.5 → libpq.so.5.18
│   ├── python3.11/               ← CPython standard library
│   ├── perl/                     ← Perl's @INC trees, mirrored by absolute path
│   ├── tcl8.6/                   ← Tcl script library
│   ├── locale/C.utf8/            ← glibc locale data (LOCPATH), not NLS
│   ├── locale/zh_CN.utf8/        ← …and any others --locales asked for,
│   │                                under the folded name glibc looks up
│   └── postgresql/               ← loadable modules: plpgsql, plperl, plpython3,
│                                    pltcl, llvmjit, all contrib extensions
└── share/
    ├── postgresql/               ← timezone data, extension SQL, sample configs
    └── locale/                   ← NLS message catalogues
```

The interpreter tree sits where its own interpreter looks for it: Python built
with `platlibdir=lib64` (Fedora, RHEL) finds its standard library under
`lib64/python3.11/`, so a bundle built there keeps that name rather than `lib/`.

Sizes of an 18.4 build: `--full` is around 366 MB, most of it LLVM (104 MB),
z3 (22 MB), ICU (33 MB) and the interpreter runtimes (110 MB — Python 54, Perl
53, Tcl 3). The client bundle is around 24 MB: with the server-only features off
there is no LLVM, no ICU and no interpreter runtime to carry, and nothing below
`share/` or `lib/postgresql/` is needed by a client tool. `--full` enables every
optional feature; if size matters more than JIT or PL/Python, those are the
knobs to turn off in `bundle.sh`. `--locales` adds to whatever was built: about
1–3 MB per locale, or roughly 230 MB for `all`, which is most of a bundle's worth
again. The build image grows by about 220 MB either way, since it holds the data
the bundles are cut from.

Every executable is a small `/bin/sh` wrapper that `exec`s the real binary
through the bundled dynamic linker:

```sh
exec "$LD_LINUX" --inhibit-cache --library-path "$LIB_DIR" "$REAL_BIN" "$@"
```

`--inhibit-cache` keeps the loader from reading the host's `/etc/ld.so.cache`,
so a missing library fails loudly instead of silently picking up a host copy.

## How it works

### build.sh (host side)

1. Parses the version argument
2. With `--without-container`: probes the host for the build toolchain and
   installs what is missing (apt or dnf), then runs
   `bundle.sh` directly on the working copy
3. Downloads `postgresql-{version}.tar.bz2` and its `.sha256` from the official PostgreSQL FTP
4. Verifies the checksum
5. Extracts the source (cached for future runs)
6. Builds the image from `Containerfile`
7. Runs the container as the invoking user, with the source (read-only) and output directory mounted

### bundle.sh (inside the container)

1. **meson setup / compile / install** into a staging prefix. The whole tree is
   compiled in every mode; the mode decides what is shipped. `--full` enables
   NLS, PL/Perl, PL/Python, PL/Tcl, LLVM, ICU, libxslt, libnuma, liburing,
   SELinux, systemd and UUID support, and the client build leaves the
   server-only ones off.
2. Reads the compiled-in `PGBINDIR`/`PGSHAREDIR`/`PKGLIBDIR`/`LOCALEDIR` out of the
   generated `pg_config_paths.h` rather than hardcoding them
3. Copies the programs of the mode's tool set, then runs `ldd` over them to
   collect shared library dependencies
4. Adds the libraries `ldd` cannot see: `libpq`/`libecpg`/`libpgtypes` are taken
   straight out of the install prefix — the build uses `-Drpath=false`, so
   nothing resolves them and no `ldd` pass ever walks *into* them. Their
   dependency chain is then collected level by level, because a libpq client is
   dead without it (`libpq` → `libssl`, `libgssapi_krb5`, `libldap` →
   `libkrb5`, `libsasl2`, …). Added the same way are the `libnss_*.so.2` modules
   glibc `dlopen()`s by name and the `.so` files inside the interpreter trees
5. Copies the server payload (`--full`): loadable modules,
   `share/postgresql`, `share/locale`, the interpreter runtimes, the locales
   `--locales` asked for, and the glibc
   locale data for `C.UTF-8`
6. `patchelf --set-rpath` on everything except glibc itself, the loader and the NSS
   modules; rebuilds SONAME symlinks
7. Replaces each executable with a wrapper script
8. Asserts that every `DT_NEEDED` entry of every bundled ELF resolves inside the
   bundle, then writes the launcher wrappers

### Why it is relocatable

PostgreSQL records absolute install paths at build time, but
`make_relative_path()` (`src/port/path.c`) rewrites them relative to the
executable's own directory when the last path component matches the compiled-in
`PGBINDIR` tail — i.e. when the binary lives in a directory named `bin`. Because
`find_my_exec()` only looks at `argv[0]` and the wrapper `exec`s
`<bundle>/bin/<name>.real` by absolute path, `share/postgresql`,
`lib/postgresql` and `share/locale` all resolve inside the bundle.

This makes two things load-bearing:

- **`bin/` must keep its name**, and `bin/`, `lib/`, `share/` must stay siblings.
- **The build prefix must not contain `pgsql` or `postgres`**, or meson drops the
  `postgresql` path component and the layout changes. `bundle.sh` aborts if that
  happens.

## Server notes

- **PostgreSQL refuses to run as root.** `initdb` and `postgres` must run as an
  ordinary user, and the data directory must be owned by that user.
- **`initdb --locale=C.UTF-8` works everywhere; anything else needs `--locales`.**
  `--full` carries `C.UTF-8` (`lib/locale/C.utf8`) and the launcher points
  `LOCPATH` at it, but only on a host with no `/usr/lib/locale/C.utf8` of its
  own, so that a host which has one keeps its own. Every other locale comes from
  the host, and a bare host resolves only `C`, `POSIX` and the bundled
  `C.UTF-8` — which is why `initdb --locale=zh_CN.UTF-8` fails there. Build with
  `--locales=zh_CN.UTF-8` to carry it. See *Locales* below.
- **A bundle built with `--locales` takes over the locale path.** Its launcher
  sets `LOCPATH=<bundle>/lib/locale:/usr/lib/locale`, and glibc consults a
  `locale-archive` **only** when `LOCPATH` is unset (`locale/findlocale.c`: it
  tries the archive only if there was no LOCPATH). So on a host that keeps its
  locales in an archive — RHEL-family machines with `glibc-all-langpacks`, a
  Debian that has run `locale-gen` — every locale that lives only in that
  archive stops resolving for processes started through the wrapper, including
  the ones the server forks, and including locales the bundle was not asked to
  carry. Per-locale directories under `/usr/lib/locale` keep working; that path
  is named in `LOCPATH` for that reason. Nothing changes for a bundle built
  without `--locales`.
- **The default socket directory is `/tmp`** (compiled into PostgreSQL). On a
  shared machine use `-k` to point at a private directory.
- **Do not symlink the files in `bin/` elsewhere.** The wrapper resolves its own
  location and expects `<bundle>/lib` and `<bundle>/share` to be siblings. A
  symlink *into* the bundle is followed correctly; a copy or a link to somewhere
  else is not.
- **PL/Python, PL/Perl and PL/Tcl use the bundled interpreters.** To make that
  possible, the `postgres` wrapper exports `PYTHONHOME`, `PERL5LIB` and
  `TCL_LIBRARY`. These are inherited by everything the server forks, so a host
  interpreter started from `COPY … PROGRAM` or `\!` will see them too. Only the
  `postgres` wrapper sets them; `psql` and friends do not.
- **Server-side JIT works, but cross-module inlining does not.** PostgreSQL's
  meson build does not generate the bitcode tree (`lib/postgresql/bitcode/`) —
  an upstream TODO. `llvmjit.so` loads, expressions are compiled and optimised;
  only the inlining step is skipped, which it handles gracefully (DEBUG1 log
  message). Not a correctness issue.

### Helper programs

Several programs run a helper program found next to them, so a bundle that omits
the helper ships a tool that cannot work. One such call crosses the client/server
line, and the client bundle carries the helper for it:

- **`pg_verifybackup`** (client) runs `pg_waldump` (server) to parse the WAL in a
  backup, so client bundles carry `pg_waldump`. `--no-parse-wal` skips that step.

`pg_upgrade` (server) runs `pg_dumpall`, `pg_dump`, `pg_restore` and `psql`, but
those are client tools `--full` ships anyway, so nothing is added for it.

Every other sibling lookup stays inside one half: `initdb`, `pg_ctl` and
`pg_rewind` need `postgres`, `pg_ctl` also needs `initdb`, `pg_createsubscriber`
needs `pg_ctl` and `pg_resetwal`, and `pg_dumpall` needs `pg_dump`.

### What is *not* self-contained

Some things are host policy by nature, and bundling them would be wrong:

- **`/bin/sh`** — the wrappers are shell scripts. `dirname`, `pwd` and
  `readlink` are used if present.
- **`/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf`** — identity stays the
  host's business. The NSS *modules* are bundled, the lookup order is not.
- **`/etc/hosts`, `/etc/resolv.conf`** — name resolution.
- **Locale data other than `C.UTF-8`** — unless `--locales` was given, the bundle
  carries the one locale `initdb` needs to run anywhere (see the server notes)
  and reads the rest from the host, the way a native installation does. With
  `--locales` it carries the ones asked for; it does not become independent of
  the host's locale data, it stops depending on it for those.
- **The host's `locale-archive`** — a bundle built with `--locales` sets
  `LOCPATH`, and glibc then ignores a locale-archive completely. Locales that
  exist only there are not available to the bundle's processes. This is a
  property of glibc, not of the bundle, and it is why the launcher only takes
  the locale path when it has something to put there.
- **`/etc/ssl/certs`** — trust anchors must be the host's, or they would never
  be updated.
- **PAM** — `libpam.so.0` is bundled, but `pam_*.so` modules and `/etc/pam.d/*`
  are the host's authentication stack. PAM authentication is therefore not
  portable across distributions.
- **Kerberos / GSSAPI** — `/etc/krb5.conf` and the GSSAPI mechanism plugins
  describe *your* realm and are not bundled.
- **SELinux** — `libselinux.so.1` is bundled, but the policy and
  `/sys/fs/selinux` belong to the host. `sepgsql` therefore only works where
  SELinux is enabled and configured.

Building third-party extensions against this bundle is **not supported**: the
`include/` tree and `lib/postgresql/pgxs/` are not bundled, so `pg_config`
reports include paths that do not exist. Pure-SQL extensions that ship their own
`.control` and `.sql` files can still be installed with `CREATE EXTENSION`.

## Directory structure

```
postgresql-portable/
├── build.sh              # Entry point: download → verify → build
├── bundle.sh             # Container entrypoint: compile → collect → patch → wrap
├── Containerfile         # Build environment (Debian Bookworm + TUNA mirror)
├── LICENSE               # MIT
├── README.md
├── cache/                # Downloaded tarballs and extracted source
└── output/
    ├── {version}/        # client bundle
    └── {version}-full/   # client + server bundle
```

## License

MIT — see [LICENSE](LICENSE).
