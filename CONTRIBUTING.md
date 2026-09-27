# Contributing

Thanks for helping with `app_amd_ws`. This page covers the repository layout,
branching, what a pull request must include, how to regenerate the installer
and how to run the tests. The behavioural contract of the module (dialplan
API, status/cause vocabulary, wire protocol, robustness rules) is documented
in [README.md](README.md) and [docs/](docs/); changes to that contract need a
documentation change in the same pull request.

## Repository layout and ownership

| Path | What | Generated? |
|---|---|---|
| `app_amd_ws.c` | The module (single file). | no |
| `amd_ws.conf.sample` | Configuration reference; every key documented. | no |
| `Makefile`, `ast-detect.sh` | Build system and Asterisk detection. | no |
| `install.sh` | Self-contained installer. | **yes** — from the four files above by `tools/gen-installer.sh`. Do not edit. |
| `tools/gen-installer.sh` | Generates `install.sh`. | no |
| `tools/make-header-bundle.sh` | Builds `asterisk-<ver>-headers.tar.gz` + `.sha256`. | no |
| `tools/check-embedded.sh` | Fails if `install.sh` is stale relative to its sources (used by CI). | no |
| `.github/workflows/ci.yml` | CI. | no |
| `test/` | Mock server, Asterisk test configuration, `run.sh`, `README.md`. | no |
| `docs/`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `LICENSE` | Documentation. | no |

## Branching

- `main` is the released code. Nothing is committed to `main` directly.
- Feature work happens on `feat/<topic>` branches (the 2.0 rewrite is
  `feat/v2-res-http-websocket`).
- Large features are split into `wip/<area>` branches (`wip/core`,
  `wip/build`, `wip/test`, `wip/docs`), each touching only its own files,
  and merged into the feature branch by an integrator who then builds and
  runs the full test suite.
- Fixes are `fix/<topic>` branches from `main` (or from the feature branch if
  they only apply there).
- Rebase or merge `main` into your branch before opening the pull request;
  do not force-push a branch someone else has checked out.

## Pull requests

Every pull request must:

1. Build warning-free with the module flags
   (`-Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wformat=2 -Wshadow -std=gnu99`)
   against Asterisk 16.30.1, 18.x and 20.x headers. `make check` with header
   bundles under `./bundles/` (or `BUNDLES=DIR`) runs the compile matrix.
2. Pass `make check` (no unresolved symbols outside the Asterisk-provided set;
   embedded build-option sum).
3. Pass `test/run.sh` locally (needs a real Asterisk binary; see
   [docs/testing.md](docs/testing.md)). Add a scenario for every behaviour you
   add or fix; the mock server gains a path, `run.sh` gains an assertion.
4. Keep `install.sh` in sync: run `make installer` and commit the regenerated
   file in the same PR whenever `app_amd_ws.c`, `Makefile`, `ast-detect.sh` or
   `amd_ws.conf.sample` change. CI runs `tools/check-embedded.sh` and fails
   otherwise.
5. Pass the CI shellcheck step with both Ubuntu 22.04's 0.8.0 and a current
   release (`shellcheck -S warning -s sh ast-detect.sh tools/*.sh` and
   `shellcheck -S warning -s bash install.sh`; static binaries from the
   shellcheck GitHub releases work) and `python3 -m py_compile test/*.py`.
6. Update the documentation: `README.md` for anything user-visible,
   `amd_ws.conf.sample` for configuration keys, `docs/protocol.md` for wire
   changes, `docs/migration-v1-to-v2.md` if a 1.x behaviour changes again,
   and an entry under `Unreleased` in `CHANGELOG.md`.
7. Describe in the PR text what was tested and how (commands and key output),
   and any decision taken where the documentation was silent.

Commit messages: one topic per commit, imperative subject line under 72
characters, a body that says *why*. Reference the finding or issue you address.

## Rules that are not negotiable

These come from the review of 1.x and are each covered by a test:

- No libwebsockets, no other embedded event-loop library. WebSocket I/O goes
  through `res_http_websocket` only.
- Every wait is bounded by a deadline computed with `ast_tvdiff_ms`; no busy
  loops, no loops that count iterations as time, no fixed `sleep`s on the
  channel thread.
- The channel is serviced (`ast_waitfor` / `ast_read`) in every waiting phase
  wherever the API allows; `ast_read() == NULL` or `ast_check_hangup()` means
  `HANGUP` immediately.
- Audio is never dropped or truncated; the accumulator carries over.
- Classification is `amd.py`'s rule (substring, `HUMAN` first, then
  `AMD`/`MACHINE`, case-sensitive) with the single `AMDY` guard; no token
  parser, no configurable status list. `test/classify_test.py` proves parity
  with the verbatim `amd.py` rule.
- The `AMDSTATUS` / `AMDCAUSE` / `AMDSTATS` vocabulary is frozen (README,
  "Channel variables"): `amd.py` July 2026 plus stock `AMD()`'s `HANGUP` and
  `NOAUDIODATA-<ms>`; the ViciDial fallback on `CONNECTION_ERROR` /
  `PROCESSING_ERROR` / `FATAL_ERROR` must keep working. The words of earlier
  branch builds may appear only in the "was" columns of
  `docs/migration-v1-to-v2.md`.
- `AMD_WS()` returns 0 always. `load_module` returns `AST_MODULE_LOAD_DECLINE`
  on failure. Module mutexes are `AST_MUTEX_DEFINE_STATIC`. Unload relies on
  the core's use count.
- All MySQL code sits under `#ifdef HAVE_MYSQL`; the module must build and run
  without it. Never log credentials; no phone numbers at normal verbosity.
- Per-call stack under 32 KB; heap for the audio accumulator.
- The Makefile never sets `LIBS =` after a `+=`; the installer never adds
  repositories, never upgrades Asterisk, never hangs up channels, never `cd`s
  without a subshell or `pushd`/`popd`, always `set -euo pipefail`.

## Regenerating the installer

```bash
make installer && tools/check-embedded.sh && shellcheck install.sh
```

`make installer` runs `tools/gen-installer.sh`, which embeds the current
`app_amd_ws.c`, `Makefile`, `ast-detect.sh` and `amd_ws.conf.sample` into
`install.sh` and writes the source commit into its header comment. Commit the
result together with the source change.

## Running the tests

```bash
make test               # builds, starts mock server + Asterisk, runs all scenarios
test/run.sh             # same
```

The harness runs as a normal user, needs no root, and binds only the mock
server's port. See [docs/testing.md](docs/testing.md) and
[test/README.md](test/README.md) for requirements and the scenario list.

## Header bundles

When a new Asterisk version appears in the field (a new `-vici` tarball or
ViciBox RPM), build and publish a header bundle from a build box:

```bash
tools/make-header-bundle.sh   # usage text; takes a configured tree or a tarball
```

and upload `asterisk-<ver>-headers.tar.gz` and its `.sha256` to the bundle
location (`https://download.amdy.io/asterisk-headers/`). Add the version to the
compatibility table in `README.md` and, if it needs anything special, to
[docs/build-and-headers.md](docs/build-and-headers.md).

## Releasing

1. Update `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - <date>`,
   add the compare link, start a new empty `[Unreleased]` section.
2. Publish header bundles for the field versions that have no devel package
   (`16.30.1-vici`, `18.21.0-vici`, `18.26.4-vici`) with
   `tools/make-header-bundle.sh` to `https://download.amdy.io/asterisk-headers/`
   (none are published yet; the docs say so until this is done).
3. `make installer`; confirm `tools/check-embedded.sh` passes; run the full
   `test/run.sh`.
4. Merge to `main` and tag `vX.Y.Z` there (`git describe` then yields the
   version the installer header and `--help` print).
5. Replace the branch name in every install URL (`README.md`,
   `docs/installer.md`, `docs/migration-v1-to-v2.md`) with the tag
   (`https://raw.githubusercontent.com/nikvb/amd/vX.Y.Z/install.sh`), publish
   `sha256sum install.sh` in the release notes, and remove the "until merged"
   notes. `main` must never again serve an installer that is not the released
   one.

## License

By contributing you agree that your contribution is licensed under the
GPL-2.0 like the rest of the project ([LICENSE](LICENSE)).
