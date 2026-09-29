# Extension recipes

One file per extension: `<name>.sh`. `--extension=<name>` builds it, and
`--extension=<path>` builds a recipe from anywhere — yours, not necessarily in
here. A recipe is a shell file, and it holds what you would type on a host to
build that extension from source. Nothing about PostgreSQL's build is repeated
in it: the prefix is handed over as `pg_config`, so PGXS and every autoconf
project that takes `--with-pgconfig` find it by themselves.

```sh
# extensions/myext.sh
EXT_DESC="myext -- what it does"
EXT_URL="https://example.invalid/myext-1.2.3.tar.gz"
EXT_SHA256="<64 hex digits>"

ext_build() {
    make PG_CONFIG="$PG_CONFIG" -j"$JOBS"
    make PG_CONFIG="$PG_CONFIG" install
}
```

## What a recipe declares

| Variable | | |
|---|---|---|
| `EXT_URL` | required | Where the source tarball comes from. `build.sh` fetches it on the host, so the build container needs no network at all; `--no-download` applies to it exactly as it does to the PostgreSQL tarball. |
| `EXT_SHA256` | required | What the tarball must hash to. It is the whole of the trust in the source — there is no other check — and it is also how the cached copy is named, so a version bump fetches beside the old file instead of colliding with it. Checked twice: once after the download, once by the build against the file it was handed. |
| `EXT_DEPS` | optional | Build dependencies, as an array of capability probes. See below. |
| `EXT_STRIP` | optional | Leading directories to strip when unpacking. Default `1`, which is what a tarball with one top-level directory needs — nearly all of them. A tarball whose members are the tree itself wants `0`. |
| `EXT_DESC` | optional | One line for the build log. |

The top level of a recipe may only declare things. It is *sourced*, sometimes
more than once — once to read the declarations, once more where the build runs
— so anything with an effect there happens repeatedly.

## What a recipe defines

`ext_build()` is the build, and it runs with the working directory set to the
unpacked source, under `bash -euo pipefail`: a command that fails stops it, so
the plain sequence above is enough and `|| exit` is not needed.

| In the environment | |
|---|---|
| `PG_CONFIG` | `pg_config` of the prefix this build just installed. `make PG_CONFIG="$PG_CONFIG"` and `./configure --with-pgconfig="$PG_CONFIG"` are the two ways projects take it. |
| `PREFIX` | That prefix. It is also where the build is looking for what you install. |
| `PG_MAJOR`, `PG_VERSION` | For the projects that need to know which server they are being built for. |
| `EXT_SRC` | The unpacked source tree — the working directory as well. |
| `EXT_NAME` | The recipe's name. |
| `JOBS` | A sensible `-j` value. |

There is no network: a recipe gets its source from `EXT_URL` and must not fetch
anything else. A project that needs a second download (a data blob, a
submodule) has no way to ask for one yet, and a project that only publishes
through git wants the archive tarball of a tag, which `EXT_URL` can name and
`EXT_SHA256` can pin.

## Dependencies

`EXT_DEPS` names *capabilities*, not packages, because the package that
provides one is a different name on every distribution:

```sh
EXT_DEPS=(lib:geos:geos_c.h lib:proj:proj.h hdr:json-c/json.h cmd:autoconf)
```

| | |
|---|---|
| `cmd:foo,bar` | one of those commands is in `PATH` |
| `hdr:path/to.h,other.h` | one of those headers is under an include root |
| `lib:pcname:fallback.h` | `pkg-config` knows `pcname`, or the header is there. A comma separates alternatives: `lib:icu-uc,icu-i18n:unicode/utypes.h` |

The same three probes `build.sh` asks the host with, and only these three.
A missing one is reported before anything is unpacked, naming the recipe and
the capability:

- **In the build image** they are the `Containerfile`'s business. That apt list
  is the only place a package can come from — nothing is installed while the
  image runs — so a recipe that needs something wants the package that provides
  it added there, beside the core's.
- **On a host build** (`--without-container`) they are reported and never
  installed. The name of the package is the distribution's business, and
  `build.sh` only knows the core's by hand.

## What happens to a recipe

1. `build.sh` reads the declarations, fetches `EXT_URL` into the cache, checks
   it against `EXT_SHA256`, and puts the recipe and the tarball into one
   directory, passed to the build as `EXT_SPECS`.
2. `bundle.sh` sources the recipe, checks the declarations, probes `EXT_DEPS`,
   and checks the tarball against `EXT_SHA256` again.
3. It unpacks the tarball and runs `ext_build`.
4. It checks that something under `$PREFIX` actually changed. A build that
   failed to pick up `PG_CONFIG` installs into `/usr/local` instead, returns 0,
   and would otherwise ship a bundle without the extension and say nothing.

   `PG_CONFIG` is not the whole of it. It covers what PGXS places -- the
   module, the `.control`, the `.sql` -- and a project's own `configure` owns
   everything it installs for itself, under a prefix of its own choosing: it
   defaults to `/usr/local`, and a project that installs frontends of its own
   puts those there too. Its recipe wants `--prefix="$PREFIX"` beside
   `--with-pgconfig`. Left unpinned, the failure depends on who is running the
   build: as the invoking user -- which is what both a container build and a
   host build are -- the install stops part-way with a permission error, while
   a build that happens to run as root succeeds silently, into a path that
   nothing then copies.
5. Everything after that is the ordinary pipeline: the module lands in
   `lib/postgresql/`, the `.control` and `.sql` in
   `share/postgresql/extension/`, its libraries are collected by the same
   `ldd` walk the server's own modules go through, and Step 12b asserts that
   every one of them resolves inside the bundle.

Then `CREATE EXTENSION <name>` works on the target, where `<name>` is what the
`.control` file says — which is not necessarily the recipe's name, since the
two are separate things. The build reports the names it found; keep one for
`verify.sh`, which is what takes it from there:

```sh
VERIFY_EXTENSIONS=<control name> ./verify.sh output/18.4-full
```

## Adding one

1. Write `extensions/<name>.sh` from the sketch above.
2. Add whatever `EXT_DEPS` names to the `Containerfile`, in the apt list.
3. `./build.sh 18.4 --full --extension=<name>`
4. `VERIFY_EXTENSIONS=<control name> ./verify.sh output/18.4-full`

Two things are worth knowing about the result. The extension is compiled by
the same image as the server, so it is linked against the same glibc and the
same OpenSSL — that is what makes it an ordinary part of the bundle rather than
something that has to be checked for compatibility. And `PG_MODULE_MAGIC`
means a build for the wrong major fails at load time and nowhere earlier:
nothing in a recipe checks that the version it pins still supports the server
it is being built against, so that is worth knowing when a recipe is bumped.
