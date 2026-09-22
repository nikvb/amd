# install.sh

`install.sh` is a self-contained `curl | bash` installer for `app_amd_ws`. It
is **generated** by `tools/gen-installer.sh` from `app_amd_ws.c`, `Makefile`,
`ast-detect.sh` and `amd_ws.conf.sample`; its header comment names the source
commit it was generated from. Never edit `install.sh` by hand: change the
source files and run `make installer` (CI runs `tools/check-embedded.sh` and
fails if the embedded copies are stale).

## Running it

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- -y
```

Or from a checkout: `sudo ./install.sh -y`. Run it as root on the telephony
server that runs Asterisk. It logs everything it prints to
`/var/log/app_amd_ws-install.log`.

**Which URL:** until 2.0.0 is merged to `main` and tagged, the `main` URL
still serves the 1.x installer. After the release use the tag,
`https://raw.githubusercontent.com/nikvb/amd/v2.0.0/install.sh`, whose sha256
is published in the release notes; compare with `sha256sum install.sh` after
downloading if you do not pipe into `bash`.

## Flags

| Flag | Effect |
|---|---|
| `-y` | Assume yes to any confirmation prompt. Use it when piping into `bash`. |
| `--dry-run` | Detect and print the plan (distro, Asterisk, headers, module directory, what would be installed), change nothing. No root needed. |
| `--deps-only` | Install build dependencies only. |
| `--build-only` | Detect, resolve headers and build in a temporary directory; do not install or load. Writes the module to `--output` (default `./app_amd_ws.so`). No root needed. |
| `--output FILE` | With `--build-only`: where to write the built module. |
| `--no-db` | Do not install the MariaDB/MySQL client dev package and build without the DB lookup (`MYSQL=0`). |
| `--no-load` | Install the file but do not unload/load the module in the running Asterisk. |
| `--headers DIR` | Use this header directory (`asterisk.h` inside), skipping detection. |
| `--asterisk-src DIR` | Use `DIR/include` of this configured and built source tree. |
| `--version VER` | Override the detected Asterisk version (e.g. `18.21.0-vici`) for header lookup and downloads. |
| `--allow-configure` | Permit running `./configure` inside a downloaded source tarball when no `autoconfig.h` is available otherwise (slow; the installer names the extra packages `./configure` needs). Off by default, and refused for a tarball whose sha256 could not be verified (no published checksum and none pinned in the installer): download it yourself, verify it, and pass `--tarball-file`. |
| `--bundle-url URL` | Base URL for header bundles (default `https://download.amdy.io/asterisk-headers`; env `AMD_WS_BUNDLE_URL`). |
| `--tarball-file F` | Use this local Asterisk source tarball instead of downloading one (resolution step 4). |
| `--wait N` | Seconds to keep retrying a soft `module unload` that is refused because calls are inside `AMD_WS()` (default 30). |
| `--keep-build` | Keep the temporary build directory (for debugging a build failure). |
| `--uninstall` | Remove the installed module and the header cache (see below). |
| `--remove-backups` | With `--uninstall`: also delete `app_amd_ws.so.bak.*`. |
| `--help` | Usage text, exit 0. |

Environment overrides (all optional): the `ast-detect.sh` set (`ASTERISK`,
`ASTVERSION`, `ASTBUILDSUM`, `ASTINCDIR`, `ASTTOPDIR`, `ASTMODDIR`,
`AST_SRC_ROOTS`, `AST_INC_ROOTS`, `ASTNOCHECK=1`), `AMD_WS_BUNDLE_URL`,
`AMD_WS_CACHE_DIR` (default `/var/cache/app_amd_ws`), `AMD_WS_LOG_FILE`
(default `/var/log/app_amd_ws-install.log`), `AMD_WS_ETCDIR` (default
`/etc/asterisk`), `MYSQL_CFLAGS`/`MYSQL_LIBS`. Non-root runs (`--dry-run`,
`--build-only`) use a private `mktemp` cache directory and log file under
`$TMPDIR` (printed at the start; the cache is removed on exit unless
`--keep-build`), never a predictable path another user could pre-create.

## What it does, in order

1. **Detect the distribution** and package manager: openSUSE/SLES (ViciBox
   9-13, `zypper`), RHEL family (CentOS 7, Alma/Rocky 8-9, `yum` or `dnf`),
   Debian/Ubuntu (`apt-get`). It **never adds repositories** and **never
   upgrades or reinstalls Asterisk**.
2. **Install build dependencies** only: `gcc make pkg-config binutils tar curl`
   plus the MariaDB/MySQL client development package (skipped with
   `--no-db`).
3. **Detect the running Asterisk** with `ast-detect.sh` (binary via
   `/proc/<pid>/exe`, version via `core show version` / `asterisk -V` /
   `strings`, build-option sum via `strings`). Detection runs first so the
   plan can be printed; whatever needed `strings` (binutils) on a box that did
   not have it yet is read again right after the dependencies are installed.
   See [build-and-headers.md](build-and-headers.md).
4. **Resolve headers**, first match wins:
   1. local trees and installed headers validated by `ast-detect.sh`
      (`/usr/src/asterisk*/…/include`, `<prefix>/include`, `/usr/include`);
   2. the distro devel package **only if** the running Asterisk belongs to the
      distro package (`rpm -qf` / `dpkg -S` on the binary), pinned to the exact
      installed version: `zypper install --oldpackage asterisk-devel-<ver>-<rel>`,
      `dnf`/`yum install asterisk-devel-<ver>`, `apt-get install asterisk-dev=<ver>`;
   3. header bundle download:
      `<bundle-url>/asterisk-<ver>-headers.tar.gz`, sha256-verified from the
      sidecar when published (`certified/18.9-cert1` is looked up as
      `asterisk-certified-18.9-cert1-headers.tar.gz`). **No bundles are
      published at `download.amdy.io` yet**; this step currently 404s and
      falls through.
   4. source tarball, headers only: `download.vicidial.com/required-apps/asterisk-<ver>.tar.gz`
      for `-vici` versions, else `downloads.asterisk.org/pub/telephony/asterisk/{releases,old-releases}/asterisk-<base>.tar.gz`.
      Verification: a sha256 **pinned in the installer** for the tarballs whose
      origin publishes none (`asterisk-16.30.1-vici`, `asterisk-18.21.0-vici`,
      upstream `asterisk-16.30.1`), else the origin's `.sha256` sidecar
      (asterisk.org); an unverifiable download is used for the headers but
      `--allow-configure` is refused for it. Only `*/include/*` and
      `.version` are extracted; `autoconfig.h` comes from the bundle if one
      exists, otherwise `./configure` runs only with `--allow-configure`;
      `buildopts.h` is synthesised from the running core's sum. Downloaded
      headers are cached in `/var/cache/app_amd_ws` (never `/usr/src`).

   If all four fail the installer stops with a message naming every rejected
   candidate and the exact `--headers` / `--asterisk-src` / `--version` to
   pass.
5. **Build** in a `mktemp` directory with the same `Makefile` the repository
   uses, and run its gates (`make check`: no unresolved symbols, correct
   build-option sum).
6. **Back up** the existing module to
   `<moddir>/app_amd_ws.so.bak.<timestamp>` and **install** the new file.
   The module directory comes from `core show settings`, then `astmoddir` in
   `/etc/asterisk/asterisk.conf`, then a known directory that contains
   `pbx_config.so`. It never installs to `/`.
7. **Swap the running module**: `module unload app_amd_ws.so` softly. The core
   refuses the unload while any call is inside `AMD_WS()`; the installer then
   retries every 2 s for up to `--wait` seconds (default 30). It **never hangs
   up channels**. If the unload is still refused, the new file is left
   installed, the installer prints exactly what to run later, and exits with
   status 3.
8. **Load and verify**: `module load app_amd_ws.so`, then parse the reply of
   `module show like app_amd_ws` and check that
   `core show application AMD_WS` answers. Logs the module version as reported
   by `amd_ws show settings` (`module version (amd_ws show settings): 2.0.0`).
9. **Print a fixed example dialplan snippet** (`api.amdy.io,2700`, no
   hard-coded IPs) and where the log went.

All downloads use `curl -fsSL --retry 3` restricted to `https` (and `file://`
mirrors), never following a redirect to plain `http`; checksums are verified
wherever the origin publishes one or the installer pins one. The script runs
with `set -Eeuo pipefail` and correct traps: a truncated download executes
nothing, an unexpected failure prints the failing line and command, and every
successful path (including `--help`) exits 0.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Success (also for `--help`, `--dry-run`, `--deps-only`, `--build-only`, and `--uninstall` when the module could be unloaded or was not loaded). | Nothing. Check `module show like app_amd_ws`. |
| `1` | A step failed (download, checksum, unsupported distro, ...). | Read the last lines of the output or `/var/log/app_amd_ws-install.log`; the message names the failing step and the override or fix. |
| `2` | Usage error, or not running as root without `--dry-run`/`--build-only`. | Fix the command line; run with `sudo`. |
| `3` | Built and installed, but the previous module is still loaded because calls were inside `AMD_WS()` for the whole `--wait` period. Also returned by `--uninstall` when the module could not be unloaded: the file is removed, the code stays resident until Asterisk restarts. | Run the printed command when the dialer is idle (a `module unload app_amd_ws.so` followed by `module load app_amd_ws.so`, or an Asterisk restart at the next maintenance window). The new code is active after that. |
| `4` | No Asterisk headers matching the running Asterisk could be found or obtained. | The message lists every rejected candidate; pass `--headers DIR`, `--asterisk-src DIR`, `--version VER`, `--tarball-file F` or `--allow-configure`. |
| `5` | Build or gate failure, or the new module failed to load (the backup is restored and reloaded). | Read the compiler/gate output in the log. |
| `6` | Build dependencies could not be installed. | Install `gcc make pkg-config binutils tar curl` (and the MariaDB/MySQL client dev package unless `--no-db`) by hand, or fix the package manager. |

## What it changes on the system

| Change | Where | Removed by `--uninstall`? |
|---|---|---|
| Build dependency packages (`gcc`, `make`, `pkg-config`, `binutils`, `tar`, `curl`, MariaDB/MySQL client dev) | package manager | No (system packages are left alone). |
| Distro `asterisk-devel` / `asterisk-dev`, only in resolution step 2 | package manager | No. |
| Header bundle / tarball extraction | temporary directory, removed after the build | n/a |
| `app_amd_ws.so` | Asterisk module directory | Yes. |
| `app_amd_ws.so.bak.<timestamp>` | Asterisk module directory | Kept by default; deleted with `--uninstall --remove-backups`. |
| Header cache (bundle / tarball headers) | `/var/cache/app_amd_ws` | Yes. |
| Loaded module | running Asterisk | Unloaded on `--uninstall` (soft; refused while in use). |
| Log | `/var/log/app_amd_ws-install.log` | Kept. |
| `amd_ws.conf.sample` | `/etc/asterisk/amd_ws.conf.sample` (copy it to `amd_ws.conf` to change defaults). An existing `/etc/asterisk/amd_ws.conf` is never created, touched or overwritten. | No. |

It does **not** modify `/etc/asterisk/extensions.conf`, an existing
`/etc/asterisk/amd_ws.conf`, `/etc/asterisk/modules.conf`,
`/etc/astguiclient.conf`, ViciDial's database, or any repository configuration. Configuration is yours to add; see the
configuration reference in the [README](../README.md#configuration-reference)
and `amd_ws.conf.sample`.

## Upgrade

Run the same one-liner again. The installer backs up the current module,
installs the new build and swaps it in as described in step 7. If the dialer is
busy for longer than `--wait` seconds you get exit code 3 and the new file
becomes active at the next unload/load or restart. Nothing is hung up.

For a fleet, `--build-only` on one box of each Asterisk version produces a
`.so` you can copy to the others **only** if they run the exact same Asterisk
build (same version string and same build-option sum). When in doubt let the
installer build on every box; it takes seconds.

## Rollback

The previous module is at `<moddir>/app_amd_ws.so.bak.<timestamp>`. To go
back:

```bash
M=$(asterisk -rx 'core show settings' | awk -F': *' '/Module directory/{print $2}'); ls -1t "$M"/app_amd_ws.so.bak.* | head -1
```

then copy the chosen backup over `app_amd_ws.so` and reload:

```bash
cp -a "$M/app_amd_ws.so.bak.<timestamp>" "$M/app_amd_ws.so" && asterisk -rx 'module unload app_amd_ws.so' && asterisk -rx 'module load app_amd_ws.so'
```

`module unload` is refused while calls are inside `AMD_WS()`; retry when idle.
A 1.x backup will load again only if the 1.x libwebsockets build it was linked
against is still on the box; rolling back from 2.x to 1.x is therefore not
recommended (see [migration-v1-to-v2.md](migration-v1-to-v2.md)).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- --uninstall
```

Unloads the module (softly; refused while in use, exit code 3 in that case,
the file is removed anyway), removes `app_amd_ws.so`
from the module directory and the header cache `/var/cache/app_amd_ws`.
Backups `app_amd_ws.so.bak.*` stay unless `--remove-backups` is added. It
restores nothing else: packages, dialplan, `amd_ws.conf`,
`amd_ws.conf.sample` and the install log stay. Remove the `AMD_WS(...)`
line from extension 8370 yourself (or point the campaign back to extension
8369 in ViciDial) before uninstalling, otherwise calls hit an unknown
application.

See also: [build-and-headers.md](build-and-headers.md), [troubleshooting.md](troubleshooting.md).
