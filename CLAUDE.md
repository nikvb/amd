# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this is

`app_amd_ws` is a single-file Asterisk dialplan application module,
`AMD_WS()`, that streams the first seconds of an answered call to the amdy.io
Answering Machine Detection service over WebSocket and sets `AMDSTATUS` /
`AMDCAUSE` (plus `AMDRESPONSE`, `AMDELAPSED`) for ViciDial's extension 8370.
Version 2 uses Asterisk's own `res_http_websocket` client (no libwebsockets),
bounded waits everywhere, token-based result classification, optional
parallel playback and an optional MySQL lookup of phone/country from
`vicidial_auto_calls`.

Audience for all user-facing text: a ViciDial administrator, not a C
developer. Precise commands, tables, no marketing.

## Source of truth

- Behaviour: `README.md` (dialplan API, status/cause vocabulary,
  configuration), `docs/protocol.md` (wire protocol), `docs/architecture.md`.
- Build/headers: `docs/build-and-headers.md`. Installer: `docs/installer.md`.
- Reference implementations of the protocol: the production EAGI client
  `amd.py` (wire behaviour to match) — the 1.x module's lws loop is **not** a
  reference; its failure modes are listed in `docs/architecture.md`.
- Tests are the executable spec: `test/run.sh`, `test/README.md`,
  `docs/testing.md`.

## Files and ownership

| Path | Notes |
|---|---|
| `app_amd_ws.c` | The module. Compile warning-free with `-Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wformat=2 -Wshadow -std=gnu99` against 16.30.1, 18.x and 20.x headers. |
| `amd_ws.conf.sample` | Every configuration key with its default. Keep in sync with the README table. |
| `Makefile`, `ast-detect.sh` | Detect the **running** Asterisk (binary via `/proc/<pid>/exe`, version, `AST_BUILDOPT_SUM` via `strings`), validate header candidates, build, gate, install. |
| `install.sh` | **Generated.** Never edit directly. Change the sources and run `make installer` (`tools/gen-installer.sh`). `tools/check-embedded.sh` fails CI when it is stale. |
| `tools/` | `gen-installer.sh`, `make-header-bundle.sh`, `check-embedded.sh`. |
| `test/` | `mock_amd_server.py`, `asterisk/` config, `run.sh`, `README.md`. Runs as a normal user. |
| `docs/`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE` (GPL-2.0) | Documentation. Update `CHANGELOG.md` with every user-visible change. |

## Build and test commands

```bash
make show-config                 # detected Asterisk binary, version, build-option sum, headers, MySQL client
make                             # build app_amd_ws.so
make check                       # ldd -r symbol gate + embedded AST_BUILDOPT_SUM (+ compile matrix over ./bundles)
sudo make install                # backs up old .so to .so.bak.<timestamp>, installs into ASTMODDIR
make load | make unload | make reload   # asterisk -rx with reply parsing (exit code of -rx is always 0)
make installer                   # regenerate install.sh
make test                        # test/run.sh: mock server + real Asterisk, all scenarios
make clean
```

Overrides: `ASTINCDIR=`, `ASTTOPDIR=`, `ASTMODDIR=`, `ASTNOCHECK=1` (sum
mismatch → warning; never for production), `MYSQL=auto|1|0`,
`MYSQL_CFLAGS=`/`MYSQL_LIBS=`, `BUNDLES=`.

On the development box: the reference tree with full source is
`/home/na/asterisk-16.30.1-vici` (headers identical to `/usr/include/asterisk*`);
the binary runs with `LD_LIBRARY_PATH=/usr/lib64 /usr/sbin/asterisk`; modules
are in `/usr/lib64/asterisk/modules`; the core's build-option sum is
`da6642af068ee5e6490c5b1d2cc1d238` (= `md5("OPTIONAL_API\n")`). MariaDB
client dev files may be staged outside `/usr`; pass `MYSQL_CFLAGS`/`MYSQL_LIBS`
explicitly in that case. There is no MySQL server; the DB-unreachable path
must complete within `db_timeout_ms`.

Installer checks without touching the system: `./install.sh --dry-run`,
`./install.sh --build-only`, `shellcheck install.sh`.

## Architecture map (`app_amd_ws.c`)

1. Config: `amd_ws.conf` via `ast_config_load` (`CONFIG_FLAG_FILEUNCHANGED`
   on reload); `/etc/astguiclient.conf` parsed at load/reload (tolerant
   parser). `reload_module` re-reads both.
2. DB lookup (`#ifdef HAVE_MYSQL`): `mysql_library_init()` once in
   `load_module`; one persistent `MYSQL*` under an `AST_MUTEX_DEFINE_STATIC`
   mutex; connect/read/write timeouts from `db_timeout_ms`; escape with
   `mysql_real_escape_string`; fail soft; warnings rate-limited to 1/min.
3. `amd_ws_exec`: parse args (`AST_APP_OPTIONS`), answer unless `A`, set read
   format `slin`, connect with `ast_websocket_client_create_with_options`
   (`.timeout = connect_timeout_ms`), send config TEXT, main loop on
   `ast_waitfor_nandfds(chan, ws fd, <= 20 ms)`, heap accumulator, schedule
   sends, `ast_websocket_read` with fragment reassembly, token classifier,
   playback start/stop, result grace, uniform exit path (`{"eof":1}`, close
   1000, unref, restore format, set 4 variables, verbose-3 summary, counters).
4. CLI `amd_ws show settings`; counters via `ast_atomic_fetchadd_int`.
5. Module glue: `ast_register_application` with full synopsis/description
   (out-of-tree XML docs are not shown by `core show application`),
   `AST_MODULE_INFO(... .support_level = AST_MODULE_SUPPORT_EXTENDED,
   .load_pri = AST_MODPRI_DEFAULT, .requires = "res_http_websocket")`,
   `load_module` returns `AST_MODULE_LOAD_DECLINE` on failure, unload relies on
   the core's use count.

## Frozen contracts (do not change without a CHANGELOG + migration note)

- `AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])`; options
  `n s d(ms) c(ms) p(phone) k(code) a A`.
- `AMDSTATUS` ∈ {`HUMAN`, `MACHINE`, `NOTSURE`, `HANGUP`, server token
  uppercased}; `AMDCAUSE` ∈ {token, `INTERR`, `NETERR`, `AUDIO_TIMEOUT`,
  `NO_AUDIO_TIMEOUT`, `HANGUP`}. The ViciDial fallback
  `GotoIf($["${AMDCAUSE}"="NETERR" | "${AMDCAUSE}"="INTERR"]?amd_fallback)`
  must keep working.
- Wire: config frame `{"config":{"sample_rate":8000,"VID":"..."[,"phone":..][,"country_code":..]}}`,
  binary slin chunks on `send_schedule` then every `chunk_bytes`, `{"eof":1}`,
  CLOSE 1000. Classification: first terminal token (`HUMAN`; `MACHINE`/`AMD`;
  `extra_statuses`) after splitting on non-`[A-Za-z0-9_]`; JSON
  `status`/`result`/`classification` value only.
- Return value 0 always. Two verbose-3 lines per call:
  `AMD_WS: <chan> vid=<vid> host=<h>:<p> play=<file|none>` and
  `AMD_WS: <chan> status=<S> cause=<C> elapsed=<ms> sent=<bytes> chunks=<n>`.

## Working rules

- No libwebsockets. No busy loops; every wait bounded by `ast_tvdiff_ms`
  against a deadline; service the channel while waiting; hangup → `HANGUP`
  immediately, stop playback, close ws, no grace.
- Never drop or truncate audio. Per-call stack < 32 KB.
- Never log credentials; no phone numbers at normal verbosity.
- Do not version-gate on `ASTERISK_VERSION_NUM` (not in the headers); rely on
  OPTIONAL_API stubs returning NULL → `INTERR` with a clear log line.
- Do not edit `install.sh`; regenerate it. Do not add package repositories or
  upgrade Asterisk in the installer. Never hang up channels to unload.
- Never install headers or modules into the system on the development box as
  part of a test; `test/run.sh` uses a scratch run directory and a module
  directory of symlinks.
- Documentation must trace to actual behaviour; where something is open,
  point to `amd_ws.conf.sample` rather than inventing a default.
- When a change touches behaviour: update `README.md`, the relevant `docs/`
  page, `CHANGELOG.md`, add a scenario to `test/run.sh`, and run
  `make installer`.

## Debugging on a dialer

```bash
asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'module show like res_http_websocket'
asterisk -rx 'amd_ws show settings'
asterisk -rx 'core show application AMD_WS'
asterisk -rx 'core set debug 3 app_amd_ws'          # per-frame detail; 'core set debug 0 app_amd_ws' to stop
grep 'AMD_WS:' /var/log/asterisk/full | tail
```

Playbook: `docs/troubleshooting.md`.
