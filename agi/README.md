# `agi/amd.py` — the EAGI client (alternative to the `AMD_WS()` module)

This is the production EAGI script that ViciDial servers run from extension
8370 (`EAGI(/var/lib/asterisk/agi-bin/amd.py)`), as served from
`https://gw.724care.com/amdy.tar.gz` (version 2.2, 2026-07-14), with one
change: the **no-audio and hangup results use stock Asterisk `app_amd`
vocabulary**, so `VD_amd.agi` treats them exactly as it treats the built-in
`AMD()` application.

Both integrations — this script and the `AMD_WS()` module in the repository
root — set the same variables for the same situations (see the README's
status table).

## What changed in 2.2.1 (vs the tarball on gw)

| Situation | 2.2 (tarball) | 2.2.1 (this file) | Why |
|---|---|---|---|
| FD 3 returns 0 bytes (channel hung up) | `AMDSTATUS=NOAUDIO`, `AMDCAUSE=NOAUDIO` | `AMDSTATUS=HANGUP`, `AMDCAUSE=HANGUP` | Stock `app_amd` sets `HANGUP`. `VD_amd.agi` recognises `PERSON|HUMAN|NOTSURE|HANGUP`; `NOAUDIO` fell through to the *machine* path. |
| `MAX_WAIT_TIME` reached with no audio at all | `AMDSTATUS=NOTSURE`, `AMDCAUSE=NO_AUDIO_TIMEOUT` | `AMDSTATUS=NOTSURE`, `AMDCAUSE=NOAUDIODATA-<ms>` | Stock `app_amd` sets `NOAUDIODATA-<ms>`. `VD_amd.agi` strips `-<ms>` into `AMDRESPONSE`; with `NOAUDIODATA-Hangup-ENABLED` in the campaign's AMD settings container it dispositions the lead **ADAIR** and hangs up. |
| `AMDSTATS` | the raw server text (HUMAN only), otherwise unset | `<elapsed_ms>-<audio_bytes>` on every result | `VD_amd.agi` stores `AMDSTATS` up to the first `-` as `run_time` in `vicidial_amd_log`; stock `app_amd` puts the total time there. |
| Raw server text | in `AMDSTATS` (HUMAN) / `AMDCAUSE` (MACHINE) | additionally exported as `AMDRESPONSE` (≤ 255 chars); `AMDCAUSE` for MACHINE is unchanged | keeps the text available without abusing `AMDSTATS` |

Everything else — endpoint, config JSON (`sample_rate`, `VID`, `phone`,
`country_code`, `caller_id`), the DB lookup of `phone_code,phone_number` from
`vicidial_auto_calls`, send schedule, EOF finalisation, `CONNECTION_ERROR` /
`PROCESSING_ERROR` / `FATAL_ERROR` / `SERVER_TIMEOUT` / `EOF_*` — is
byte-for-byte the production behaviour.

## Install

```bash
install -m 755 agi/amd.py /var/lib/asterisk/agi-bin/amd.py
```

Dependencies (unchanged): `python3`, `websocket-client`, `pyst2`, `PyMySQL`
or `mysqlclient` (whatever the tarball's installer already provides).

## Test

```bash
python3 agi/test_amd_py.py
```

Drives `process_audio_stream()` with a pipe on fd 3, a fake AGI and a fake
WebSocket; covers no-audio, hangup, HUMAN and MACHINE results, and the
`AMDSTATS` format. No Asterisk needed.

## Rebuilding `amdy.tar.gz`

The tarball on gw contains exactly one file, `amd.py` (mode 755, owner root).
To produce an equivalent one from this directory:

```bash
tar --owner=root --group=root --mode=755 -czf amdy.tar.gz -C agi amd.py && sha256sum amdy.tar.gz
```
