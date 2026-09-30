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
| `EXT_URL` | required | Where the source tarball comes from. `build.sh` fetches it on the host and pins it by `EXT_SHA256`; `--no-download` applies to it exactly as it does to the PostgreSQL tarball. |
| `EXT_SHA256` | required | What the tarball must hash to. It is the whole of the trust in the source — there is no other check — and it is also how the cached copy is named, so a version bump fetches beside the old file instead of colliding with it. Checked twice: once after the download, once by the build against the file it was handed. |
| `EXT_DEPS` | optional | Build dependencies, as an array of capability probes. See below. |
| `EXT_STRIP` | optional | Leading directories to strip when unpacking. Default `1`, which is what a tarball with one top-level directory needs — nearly all of them. A tarball whose members are the tree itself wants `0`. |
| `EXT_DESC` | optional | One line for the build log. |
| `EXT_PRELOAD` | optional | Set when the module has to be in `shared_preload_libraries` before `CREATE EXTENSION` will work. See below. |
| `EXT_APT` | optional | Packages the build image must install, by Debian package name. See below. |

The top level of a recipe may only declare things. It is *sourced*, sometimes
more than once — once to read the declarations, once more where the build runs
— so anything with an effect there happens repeatedly.

## What a recipe defines

Three functions, and no recipe defines all three.

`ext_build()` is the build. It is the only required one, and it runs with the
working directory set to the unpacked source, under `bash -euo pipefail`: a
command that fails stops it, so the plain sequence above is enough and
`|| exit` is not needed.

`ext_setup()` installs what the build needs and apt does not have -- a
toolchain, usually. It runs earlier and elsewhere: as root, in the image, while
the image is being built, with the network. [What the build image has to
provide](#what-the-build-image-has-to-provide) is about this one.

`ext_verify()` is the recipe's own proof that the extension works, and it runs
afterwards, in `verify.sh`, against the finished bundle. [Saying how the
extension is verified](#saying-how-the-extension-is-verified) is about that
one.

| In `ext_build`'s environment | |
|---|---|
| `PG_CONFIG` | `pg_config` of the prefix this build just installed. `make PG_CONFIG="$PG_CONFIG"` and `./configure --with-pgconfig="$PG_CONFIG"` are the two ways projects take it. |
| `PREFIX` | That prefix. It is also where the build is looking for what you install. |
| `PG_MAJOR`, `PG_VERSION` | For the projects that need to know which server they are being built for. |
| `EXT_SRC` | The unpacked source tree — the working directory as well. |
| `EXT_NAME` | The recipe's name. |
| `JOBS` | A sensible `-j` value. |

The source comes from `EXT_URL`, fetched on the host and pinned by
`EXT_SHA256`; a project that publishes only through git wants the archive
tarball of a tag, which `EXT_URL` can name and `EXT_SHA256` can pin. **Anything
else the build needs, it may fetch for itself**: a recipe has the network. See
[what a recipe may fetch](#what-a-recipe-may-fetch) for what that costs.

A toolchain is the same answer one step earlier -- `ext_setup()` installs it
while the image is being built, so it is there before any recipe runs and every
recipe in that image shares it.

## Saying how the extension is verified

Two things a recipe can declare are not about building at all. They are about
what happens after, when `verify.sh` is handed the finished bundle -- on
another machine, with no recipe anywhere near it. Both are facts only the
recipe has, so both travel *in* the bundle, written there by `bundle.sh`.

`EXT_PRELOAD` is the first. An extension that installs hooks or defines GUCs
in `_PG_init` cannot be created until its module is already loaded, and
`shared_preload_libraries` is the only way to have that happen at postmaster
startup:

```sh
EXT_PRELOAD=1
```

`verify.sh` preloads every extension named for it whose recipe said so, using
the `module_pathname` from the control file. Without this the extension fails
`CREATE EXTENSION` with "must be loaded via shared_preload_libraries", and
nothing in a PostgreSQL installation records which extensions those are -- a
`.control` file has no field for it.

`ext_verify()` is the second, and it is the recipe's own proof that the
extension works:

```sh
ext_verify() {
    run "myext: create a table" psql_c -c "CREATE TABLE t (x myext_type)"
    psql_q -c "SELECT ..." > "${WORK}/myext.txt" 2>&1
    expect "myext: returns what it should" "42" "${WORK}/myext.txt"
}
```

It is worth writing when `CREATE EXTENSION` and `LOAD` between them do not
prove much. They show that the SQL parsed and the module resolved; neither
touches what the extension *does*. An index access method, a background
worker, a type's operators -- those are reached only by a real call, and an
extension built against a PostgreSQL whose internals disagree with the one
loading it gets exactly that far and then aborts a backend. `CREATE
EXTENSION` succeeding is not evidence against that, which is why the recipe
that has something to reach gets to say how.

What `ext_verify` is given, because it runs inside `verify.sh`:

| | |
|---|---|
| `psql_c -c "<sql>"` | run SQL, print output |
| `psql_q -c "<sql>"` | run SQL, quiet |
| `run <name> <command...>` | pass if the command exits 0 |
| `expect <name> <needle> <file>` | pass if the needle is in the file |
| `ok <name>` / `bad <name> <file>` | pass, or fail showing that file |
| `$PG`, `$WORK`, `$PORT` | the bundle, the scratch dir, the port |

It runs against a server that already has the extension created, so it does
not create it. One requirement: **it must be POSIX `sh`.** It is sourced into
the `/bin/sh` of whatever image the bundle is being verified in -- dash on
Debian, not the shell of the build image -- so bash-only syntax is a parse
error there, which is checked for and reported as one failed line rather than
being allowed to kill the run.

Both are optional, and neither is needed for an extension the ordinary checks
already cover.

## What a recipe may fetch

A recipe gets the network while it builds. Nothing is off limits: cargo, pip,
`curl`, a `configure` that downloads its own dependencies -- if it would work on
a machine with a network and the toolchain, it works here.

What that costs is worth stating plainly, because it is the one place this
mechanism stops being able to answer a question it otherwise can. `EXT_SHA256`
is the whole of the trust in the *source*, and it is checked -- but if the build
fetches anything else, then what comes out is a function of what the network
served that day as well as of the tarball you pinned. Two builds a month apart
can differ, and nothing records that they did. A recipe that does not fetch is
reproducible from the recipe file alone; one that does is not, and the file is
where that shows.

Two shapes, and the choice between them is the recipe's:

- **Fetch from `ext_build`.** What the ecosystem already does -- `cargo build`
  reaching crates.io, `pip install` reaching PyPI. No extra declaration and no
  extra artifact: the versions are pinned by whatever lockfile the project
  ships, and the bytes themselves arrive while the bundle is being built.
- **Have `build.sh` fetch it, pinned.** `EXT_URL` itself, and the PostgreSQL
  tarball, are this shape: downloaded on the host, checked against a sha256
  written in the file, cached under `cache/`, and available to `--no-download`
  for a build with no network at all.

The first is the one to reach for when the project's own tooling already knows
how to get what it needs. The second is for a source tarball, and it is the
only part of a build that works with the network unplugged: `--no-download` and
the cache cover `EXT_URL`, and nothing else.

## What the build image has to provide

A recipe gets its own build dependencies installed before anything runs in the
container. There are two ways to say what, and a recipe that needs both uses
both.

`EXT_APT` is packages, by the name the build image's distribution uses:

```sh
EXT_APT=(libgeos-dev libproj-dev)
```

They are installed with the ordinary apt, by the same signatures as
`build-essential` -- which is not the same standard as `EXT_SHA256` pinning a
source tarball, and is the same standard the rest of the image is held to. It
is also the one declaration here that does not pin bytes: a name resolves
against whatever the archive holds the day the image is built, and it is taken
as written rather than as `pkg=version`. A toolchain whose exact version a
build depends on wants `ext_setup()` instead. The names are the *build image's*
distribution's, and that is deliberate: the recipe is the one place a
distribution-specific name is written down, and a host build reports them
rather than installing them.

`ext_setup()` is shell, for what apt cannot supply:

```sh
ext_setup() {
    curl -fsSL -o /tmp/things.tar.gz https://example.invalid/things-1.2.3.tar.gz
    echo "<sha256>  /tmp/things.tar.gz" | sha256sum -c -
    tar -C /usr/local -xzf /tmp/things.tar.gz
}
```

It runs once, as root, in the image, while the image is being built -- under
`set -euo pipefail`, so a command that fails stops the build. This is the one
point in this design where a recipe's code runs as root, and it is separate
from `ext_build` for two reasons: installing a toolchain is a different act
from building an extension, and it has to happen before the image starts.
`ext_build` cannot install a compiler and then use it in the same run, and
apt cannot install one at all once the image's package lists have been
emptied.

The commands have to leave behind something the *build* can find, and the build
is not the process that ran them. It runs as the invoking user rather than as
root, with `HOME=/tmp`, and it is not a login shell, so neither a root-owned
`~/.cargo` nor a `profile.d` snippet reaches it. Two ways, and the second is
what to use when the first will not do:

- **Binaries on `PATH`.** `/usr/local/bin` is on it; a toolchain that installs
  somewhere else wants a symlink, or a `PATH` entry by the second way.

- **Environment, in `/etc/pg-portable.env`.** A setup script appends
  `KEY=value` lines to that file and `bundle.sh` exports and sources it before
  it probes for anything or builds anything. Exported matters: a toolchain
  installed by rustup is reached through a shim that reads `RUSTUP_HOME` from
  the environment, so a variable that is set in `bundle.sh` but not exported is
  a variable the shim never sees:

  ```sh
  cat >> /etc/pg-portable.env <<'ENV'
  CARGO_HOME=/usr/local/cargo
  PATH=/usr/local/cargo/bin:$PATH
  ENV
  ```

  It has to be applied that early because the first thing to look a dependency
  up by name is the capability probe below -- `EXT_DEPS=(cmd:cargo)` -- which
  runs before any recipe code does. A `PATH` set inside `ext_build()` is a
  `PATH` set after the check that needed it.

Neither is installed for a recipe that asks for neither, so a build naming only
C recipes runs an empty setup layer and carries no toolchain at all.

A setup script is trusted exactly as the rest of the recipe is: it is your
file, and this mechanism does not pin what it does. If it fetches a toolchain,
pinning that toolchain's version and bytes is the script's own business -- the
example above is the shape to follow: a sha256 for the installer, and one
version named for what it installs.

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

An include root is `/usr/include`, `/usr/local/include`, any `/usr/include/*/`,
or an LLVM tree: any `/usr/lib/llvm-*/include` or `/usr/lib64/llvm*/include`.
The last two are there because clang's headers do not always live under
`/usr/include`: Debian's libclang is only at `/usr/lib/llvm-14/include`, and
Fedora symlinks its copy into `/usr/lib64/llvm22/include`. That package ships
no `.pc` file either, so a `lib:` probe cannot reach it and only an `hdr:`
probe can find it. The globs are not pinned versions because the major is the
distribution's business -- the same reason a probe names a capability and not
a package.

The same three probes `build.sh` asks the host with, and only these three.

A probe says what must be *true*. It does not say what to install — that is
`EXT_APT` and `ext_setup()`, above — and a recipe wants both. The declaration
is what makes a missing dependency fix itself; the probe is what catches the
case where it did not, which is a package that installs but does not provide
what the recipe thought, a setup script that put its toolchain somewhere the
build never looks, or a host build where nothing was installed at all.

A probe that fails is reported before anything is unpacked, naming the recipe
and the capability. What happens next depends on the build:

- **In the build image** the capability is expected to be there, because
  `build.sh` installed what the recipe declared. A probe failing here means the
  declaration and the probe disagree about what the package provides.
- **On a host build** (`--without-container`) nothing is installed, so a
  failing probe is the expected first answer rather than a contradiction:
  install the equivalent package for your distribution and re-run.

## What happens to a recipe

1. `build.sh` reads the declarations, fetches `EXT_URL` into the cache, checks
   it against `EXT_SHA256`, and puts the recipe and the tarball into one
   directory, passed to the build as `EXT_SPECS`. What the recipe asked the
   *image* for goes into the image build, which is where it takes effect:
   `EXT_APT` collected across every `--extension`, and the body of
   `ext_setup()` if the recipe defines one.
2. `bundle.sh` sources the recipe, checks the declarations, probes `EXT_DEPS`,
   and checks the tarball against `EXT_SHA256` again, since that is the copy the
   recipe is about to be handed.
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
5. What the recipe declared for verification -- `EXT_PRELOAD`, and an
   `ext_verify()` if it defines one -- is written into the bundle at
   `.pg-portable/`, which is how `verify.sh` learns it from a bundle alone.
6. Everything after that is the ordinary pipeline: the module lands in
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
2. Declare what it needs: `EXT_DEPS` for the capabilities to probe, and
   `EXT_APT` / `ext_setup()` for what the build image has to install. Nothing
   outside the recipe has to be edited.
3. `./build.sh 18.4 --full --extension=<name>`
4. `VERIFY_EXTENSIONS=<control name> ./verify.sh output/18.4-full`

Two things are worth knowing about the result. The extension is compiled by
the same image as the server, so it is linked against the same glibc and the
same OpenSSL — that is what makes it an ordinary part of the bundle rather than
something that has to be checked for compatibility. And `PG_MODULE_MAGIC`
means a build for the wrong major fails at load time and nowhere earlier:
nothing in a recipe checks that the version it pins still supports the server
it is being built against, so that is worth knowing when a recipe is bumped.
