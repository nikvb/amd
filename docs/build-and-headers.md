# Building the module and finding the right Asterisk headers

This page explains why `app_amd_ws.so` can be built on a production dialer
without rebuilding Asterisk, what has to match the running Asterisk, how the
`Makefile` and `ast-detect.sh` find a matching header tree, what a header
bundle is, and where headers come from on each kind of ViciDial install.

## Why no Asterisk recompile is needed

An Asterisk module links **nothing** from Asterisk at build time. Its
`ast_*`, `ao2_*` and `pbx_*` symbols are resolved when Asterisk `dlopen()`s
the `.so` (with `RTLD_NOW | RTLD_LOCAL`) against the running executable. The
build therefore needs only:

1. a C toolchain (`gcc`, `make`),
2. the Asterisk **headers** of the running build,
3. optionally the MariaDB/MySQL client headers and library.

Measured on the reference box: a directory holding only the 57 headers the
module transitively includes (55 static headers plus the two generated ones,
`asterisk/autoconfig.h` and `asterisk/buildopts.h`) compiles the module to a
byte-identical object. The set of 57 is version-specific, so header bundles
ship the whole `include/` directory of a version (about 600 KB compressed)
rather than a hand-picked list.

## What must match the running Asterisk

| What | Why | How it is checked |
|---|---|---|
| **Version series** (16, 18, 20, ...) | `struct ast_module_info` differs between 13 and 16+ (13 is out of scope); 16, 18, 20 and 22 are layout-identical for everything this module uses. Public headers of the `-vici` builds are byte-identical to upstream for the same version. | `.version` of a source tree must equal the running version when present; the distro package version must equal it for `/usr/include`. |
| **`AST_BUILDOPT_SUM`** | The loader compares the 32-hex md5 compiled into the module (from `buildopts.h`) with its own and refuses the module on mismatch: `Module 'app_amd_ws.so' was not compiled with the same compile-time options as this version of Asterisk`. The sum is the md5 of the ABI-relevant menuselect options joined by `, ` plus a newline. A default build is `OPTIONAL_API` alone, so `echo OPTIONAL_API \| md5sum` = `da6642af068ee5e6490c5b1d2cc1d238`. `DEBUG_THREADS` and friends change the sum. **It is not a version check**: 16 and 18 default builds share the same sum. | The header tree's `buildopts.h` must contain the core's sum (error; `ASTNOCHECK=1` downgrades to a warning). After linking, `strings` on the `.so` must show the same sum. |
| **Platform constants** in `autoconfig.h` | Of the ~485 macros only 7 influence this module, all of them x86_64/glibc facts (`AST_JSON_INT_T`, `HAVE_ARPA_INET_H`, `HAVE_LOCALE_T_IN_LOCALE_H`, `HAVE_STRTOQ`, `SIZEOF_FD_SET_FDS_BITS`, `TYPEOF_FD_SET_FDS_BITS`, `HAVE_SYS_TIME_H`). None of the optional-library `HAVE_*` results (DAHDI, PJPROJECT, OpenSSL, ...) reach this module. | An `autoconfig.h` from any x86_64 glibc build of the same major works; the bundle ships one. |

Recovering the running core's sum without any source tree:

```bash
strings -a /usr/sbin/asterisk | grep -xE '[0-9a-f]{32}' | sort | uniq -c | sort -rn | head -1
# or from any stock module:
strings -a /usr/lib64/asterisk/modules/app_amd.so | grep -xE '[0-9a-f]{32}'
```

Trap: the `Build Options` line of `core show settings` is **not** the md5
input (it lists all menuselect cflags, e.g. `BUILD_NATIVE, OPTIONAL_API`,
while the sum covers only the ABI-relevant subset). Use the embedded string.

## The detection algorithm (`ast-detect.sh`, used by `make` and `install.sh`)

Both the Makefile and the installer run the same script. It prints one
`[ast-detect] accept ...` / `[ast-detect] reject ...: <reason>` line per
candidate to stderr and a summary of what was chosen. `make show-config`
shows the result without building.

1. **Find the running Asterisk binary**: `/proc/<pid>/exe` of the daemon
   (consoles started with `asterisk -r` are skipped), then `asterisk` in
   `PATH`, then `/usr/sbin/asterisk`. The running image is used even if the
   file on disk has since been replaced.
2. **Version**: `timeout 5 asterisk -rx 'core show version'` (running daemon),
   else `asterisk -V` (binary on disk), else the version-string pair that
   `strings` finds in the binary (`16.30.1-vici` next to `163001`; both are
   required to avoid false hits). `certified/18.9-cert1` and
   `18.10.0~dfsg+...` style strings are normalised to a base version.
3. **Core build-option sum**: `strings` on the binary or on a stock module.
4. **Header candidates, in order**:
   1. `ASTINCDIR=` or `ASTTOPDIR=` overrides (still validated unless
      `ASTNOCHECK=1`);
   2. `/usr/src/asterisk-<ver>*/include` and
      `/usr/src/asterisk/asterisk-<ver>*/include` (the nested layout ViciDial
      scratch installs use), then the same directories matched on the base
      version;
   3. `<prefix>/include` next to the binary;
   4. `/usr/include`, `/usr/local/include`.

   Tarballs, sound directories (`asterisk-core-sounds-*`) and
   `asterisk-perl-*` are never matched. Matching is done with `LC_ALL=C`.
5. **Validation of a candidate**: `asterisk.h`, `asterisk/autoconfig.h` and
   `asterisk/buildopts.h` must all exist (i.e. the tree was configured *and*
   built), `.version` must agree with the running version when present, and
   `AST_BUILDOPT_SUM` in `buildopts.h` must equal the core's sum.
6. **Failure**: an error that lists every rejected candidate with its reason and
   the exact override to pass.

Overrides honoured by `make` (all optional):

| Variable | Meaning |
|---|---|
| `ASTINCDIR=DIR` | Header directory (contains `asterisk.h`). |
| `ASTTOPDIR=DIR` | Configured and built Asterisk source tree; `DIR/include` is used. |
| `ASTMODDIR=DIR` | Module directory for `install`/`uninstall`. Default: `core show settings` → `astmoddir` in `asterisk.conf` → a known directory that contains `pbx_config.so`. Never `/`. |
| `ASTNOCHECK=1` | Turn the build-option-sum mismatch into a warning. Only for experiments; the loader will still refuse a real mismatch. |
| `MYSQL=auto\|1\|0` | `auto` (default): first of `pkg-config libmariadb`, `pkg-config mariadb`, `pkg-config mysqlclient`, `mariadb_config`, `mysql_config`; `1` requires it; `0` disables the DB lookup. Prints `MySQL: yes (<how>)` or `MySQL: no`. Defines `-DHAVE_MYSQL` when found. |
| `MYSQL_CFLAGS=... MYSQL_LIBS=...` | Explicit flags, bypassing detection. |
| `BUNDLES=DIR` | Extra header bundles for `make check` (default `./bundles`). |
| `WERROR=1` | Treat compiler warnings as errors (CI uses it). |
| `ASTETCDIR=DIR`, `DESTDIR=` | Where `make install` puts `amd_ws.conf.sample` (default `/etc/asterisk`) and a staging prefix. |

Further overrides for unusual boxes are listed in the Makefile header
(`make help`): `ASTERISK=`, `ASTVERSION=`, `ASTBUILDSUM=`, `AST_SRC_ROOTS=`,
`AST_INC_ROOTS=`, `AST_TIMEOUT=`, `CFLAGS=`, `EXTRA_CPPFLAGS=`, `EXTRA_LIBS=`.

## Makefile targets

| Target | What it does |
|---|---|
| `all` (default) | Detect, compile with `-MD -MP` dependency tracking (system headers included, so a silent fall-through to `/usr/include/asterisk` is caught), link. A `.buildflags` stamp forces a rebuild when `ASTINCDIR`, the version, the sum or `CFLAGS` change. Every build runs four gates: (1) every Asterisk header used came from `ASTINCDIR`; (2) the object embeds the core's `AST_BUILDOPT_SUM`; (3) `ldd -r app_amd_ws.so` leaves no undefined symbol that Asterisk does not provide: when the core binary is readable its `nm -D` export list decides (plus `ast_websocket_*` from `res_http_websocket.so`), otherwise the name pattern `ast_*`, `__ast_*`, `ao2_*`, `__ao2_*`, `pbx_*`, `ast_websocket_*`, `option_debug`, `option_verbose`; (4) the `.so` embeds the sum. A failed gate deletes the output. |
| `check` | `all` plus a compile-only matrix against every header bundle found under `$(BUNDLES)` (`asterisk-*-headers.tar.gz` are extracted, `buildopts.h` is synthesised for the core's sum). |
| `install` | Backs up an existing `app_amd_ws.so` to `app_amd_ws.so.bak.<timestamp>`, installs the new one atomically into `ASTMODDIR` and `amd_ws.conf.sample` into `ASTETCDIR`. Refuses an empty/`/` target. |
| `uninstall` | Removes the module from `ASTMODDIR` (backups and `amd_ws.conf` are kept). |
| `clean` | Removes objects, dependency files, the `.so` and stamps. Does not run detection. |
| `show-config` | Prints the detected binary, version, sum, header directory, module directory and MySQL client. |
| `installer` | Regenerates `install.sh` via `tools/gen-installer.sh`. |
| `test` | Runs `test/run.sh` if present (see [testing.md](testing.md)). |
| `load`, `unload`, `reload` | `asterisk -rx 'module load/unload ...'` **with reply parsing** — the exit code of `asterisk -rx` is always 0, so the reply is grepped for `Loaded` / `Unloaded` / `Error`. `unload`/`reload` are refused by the core while a call is inside `AMD_WS()`. |

Compiler flags used for the module (the source compiles warning-free with them
against 16.30.1, 18.x and 20.x headers):

```text
-pthread -O2 -g -fPIC -std=gnu99 -Wall -Wextra -Wno-unused-parameter
-Wno-missing-field-initializers -Wformat=2 -Wshadow
-DAST_MODULE=\"app_amd_ws\" -DAST_MODULE_SELF_SYM=__internal_app_amd_ws_self
[-DHAVE_MYSQL]
```

No libwebsockets anywhere; `LIBS` is composed from independent parts.

## Header bundles

A header bundle is `asterisk-<ver>-headers.tar.gz`: the complete `include/`
directory of one Asterisk version plus `.version`, with an `autoconfig.h`
generated on an x86_64 glibc box, and **without** `buildopts.h`. The installer
downloads it from

```text
${AMD_WS_BUNDLE_URL:-https://download.amdy.io/asterisk-headers}/asterisk-<ver>-headers.tar.gz
```

and verifies it against the `.sha256` sidecar file published next to it when
present. Certified versions are named without the slash
(`certified/18.9-cert1` → `asterisk-certified-18.9-cert1-headers.tar.gz`);
the `.version` inside the bundle keeps the real string.

**Status: no bundles are published at `download.amdy.io/asterisk-headers/`
yet** (every URL 404s). Until they are, a box without local headers and
without a distro devel package needs `--asterisk-src DIR`, `--headers DIR`,
or the tarball route with `--allow-configure`. Publishing bundles for
`16.30.1-vici`, `18.21.0-vici` and `18.26.4-vici` is a release step
([CONTRIBUTING.md](../CONTRIBUTING.md#releasing)).

`buildopts.h` is then **synthesised on the target** by `ast_synth_buildopts`
in `ast-detect.sh`: the sum read out of the running binary is matched against
every combination of the ABI-relevant menuselect options (`DEBUG_THREADLOCALS
DO_CRASH TEST_FRAMEWORK DEBUG_THREADS DEBUG_FD_LEAKS LOADABLE_MODULES
OPTIONAL_API G711_NEW_ALGORITHM INTEGER_CALLERID`, 512 md5 computations) and
the file is written with one `#define` per option found, e.g. for the stock
sum:

```c
/*
 * buildopts.h
 * Synthesised by ast-detect.sh for AST_BUILDOPT_SUM da6642af068ee5e6490c5b1d2cc1d238
 * (the running Asterisk was built with: OPTIONAL_API)
 */

#define OPTIONAL_API 1
#define AST_BUILDOPT_SUM "da6642af068ee5e6490c5b1d2cc1d238"
#define AST_BUILDOPTS "OPTIONAL_API"
#define AST_BUILDOPTS_ALL "OPTIONAL_API"
```

A sum that no combination of stock options produces (a custom build with
e.g. `BUSYDETECT_*`, sanitizers, or Asterisk 13's `MALLOC_DEBUG`) is refused
with `AST_BUILDOPT_SUM <sum> is not one produced by stock menuselect options
(custom build) - use the real configured+built source tree: ASTTOPDIR=...`.
This is why a bundle for a *version* works for every default build of that
version, and why a box with a non-default sum gets a clear error asking for
`ASTTOPDIR` instead of a module the loader would refuse.

### Building a bundle

`tools/make-header-bundle.sh` builds a bundle either from an already
configured Asterisk source tree, or from a source tarball on a build box that
has the `./configure` dependencies listed below (it extracts, configures and
packs). Run it without arguments for its usage text. Output:
`asterisk-<ver>-headers.tar.gz` plus its `.sha256` sidecar; upload both to the
bundle URL. Bundles are built per exact version string (`18.21.0-vici`,
`18.26.4-vici`, `16.30.1-vici`, ...; a certified tree's `certified/18.9-cert1`
becomes `asterisk-certified-18.9-cert1-headers.tar.gz` automatically). Do this
on a build box, never on the dialer. With `--tarball ... --configure` the
extracted tree is removed afterwards; when `./configure` fails it is kept so
`configure.log` can be read.

### Why `./configure` on the dialer is the last resort

Measured on the reference box: `./configure` of a pristine 16.30.1 tree took 54 s
and needs `g++`, `libedit-devel` (16/18) or `ncurses-devel`, `libuuid-devel`,
`jansson-devel`, `libxml2-devel` and `sqlite3-devel`, which stock ViciBox RPM
installs do not have. It produces `autoconfig.h` but **not** `buildopts.h`
(that needs `menuselect` + `make`). The installer therefore runs `./configure`
only with `--allow-configure` and always synthesises `buildopts.h` itself.

## Distro matrix: where the headers come from

| Install type | Asterisk | Header source (in the order the tools try) | Facts |
|---|---|---|---|
| ViciDial scratch install (RHEL family, Debian/Ubuntu, openSUSE) from `download.vicidial.com/required-apps/asterisk-<ver>-vici.tar.gz` | `16.30.1-vici`, `18.21.0-vici` (`13.29.2-vici` exists but 13 is unsupported) | (1) the configured+built tree, usually `/usr/src/asterisk/asterisk-<ver>-vici` or `/usr/src/asterisk-<ver>-vici`; (2) `/usr/include`, which Asterisk's `make install` fills (`bininstall` runs `install-headers`). | Both carry `autoconfig.h` and `buildopts.h`. `/usr/include` has no version marker (`asterisk/version.h` is an `#error` stub), so it can only be validated by its sum, which default 16 and 18 builds share; that is why an exact source tree (whose `.version` is proof) is searched first. Tarballs published: `asterisk-13.29.2-vici`, `asterisk-16.30.1-vici`, `asterisk-18.21.0-vici` (older 1.x/11 too). `18.26.4-vici` is **not** on `download.vicidial.com`. Tarballs have no published checksums. |
| ViciBox 9-13 (openSUSE Leap, Asterisk RPM from OBS `home:vicidial`) | `18.26.4-vici` (ViciBox 12/13); 13.x/16.x on older ViciBox | (2) distro devel package: `asterisk-devel` pinned to the exact installed version (`zypper install --oldpackage asterisk-devel-<ver>-<rel>`), only when `rpm -qf` says the running binary belongs to the package; (3) header bundle; (4) upstream tarball headers. | OBS project `home:vicidial:asterisk-18` publishes `asterisk` and `asterisk-devel` for Leap 15.5, 15.6, 16.0 and 16.1 (`asterisk-devel-18.26.4-lp156.11.5.x86_64.rpm`, 592 KB, contains `autoconfig.h` and `buildopts.h`, sum `da6642af...`). `asterisk-devel` `Requires: asterisk = 18.26.4`, so an **unpinned** install would upgrade Asterisk itself. The `asterisk-13` and `asterisk-16` OBS projects publish no repositories any more, so those boxes cannot get a devel RPM and go straight to the bundle. No `/usr/include/asterisk.h`, no `/usr/src/asterisk-*` on a stock ViciBox. |
| Debian / Ubuntu distro Asterisk | bullseye `16.28.0`, jammy `18.10.0`, noble `20.6.0` (no bookworm/trixie package) | (2) `apt-get install asterisk-dev=<exact installed version>`, only when `dpkg -S` says `/usr/sbin/asterisk` belongs to the `asterisk` package. | Distro modules carry a different sum (`1fb7f5c0...` on Ubuntu 18.10), so the check catches a distro `asterisk-dev` sitting under a scratch-installed `-vici` core. Unusual for ViciDial, which needs the `-vici` patches. |
| Upstream source build (18/20/21/22, custom prefix) | any | (1) `ASTTOPDIR=`; `<prefix>/include`; (3) bundle; (4) `downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-<base>.tar.gz` or `old-releases/`, verified with the published `.sha256`. | Top-level `asterisk-<ver>.tar.gz` URLs only exist for current releases; `releases/` and `old-releases/` serve every version. Certified builds live under `certified-asterisk/releases/`. |

If nothing validates, the installer stops with the list of rejected candidates
and the exact commands to fix it (`--headers DIR`, `--asterisk-src DIR`,
`--version VER`). Never copy headers from a different Asterisk version or a
different build into place to "make it compile": the loader would refuse the
module, or worse, accept a module built against a different struct layout.

See also: [installer.md](installer.md), [troubleshooting.md](troubleshooting.md).
