# AMDY.IO native Asterisk module (`AMD_WS`) — customer guide

`AMD_WS()` is a dialplan application for Asterisk that streams the first seconds of an
answered call to the AMDY.IO Answering Machine Detection service and sets the same
`AMDSTATUS` / `AMDCAUSE` variables that Asterisk's built-in `AMD()` and the AMDY EAGI
client (`amd.py`) set. It replaces the EAGI script on any Asterisk 16, 18, 20+ system —
ViciDial/Vicibox, or a custom Asterisk dialer — without Python and without touching your
Asterisk build.

## 1. Requirements

| Item | Requirement |
|---|---|
| Asterisk | 16, 18, 20, 21 or 22, with the `res_http_websocket` module (part of every standard build). Asterisk 13 is not supported. |
| Operating system | Any Linux with `gcc`, `make`, `pkg-config`, `tar` and `curl` (the installer adds them). Tested on Vicibox/openSUSE, AlmaLinux/Rocky/CentOS, Debian/Ubuntu. |
| Headers | The installer finds the headers of the **running** Asterisk (source tree in `/usr/src`, installed headers, or the distro `-devel` package). Asterisk is never recompiled or restarted. |
| Network | Outbound TCP to `api.amdy.io` port **2700** from the telephony server. |
| Optional | MariaDB/MySQL client development files, only for the ViciDial phone/country lookup. Without them the module works with the lookup disabled. |

## 2. Install (one command, as root)

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- -y
```

What it does: detects the running Asterisk and its headers, installs the build tools,
compiles the module for exactly that Asterisk, checks the result, backs up any previous
`app_amd_ws.so`, installs and loads the module **without hanging up any call**, and
prints the dialplan snippet. Everything is logged to `/var/log/app_amd_ws-install.log`.

Preview without changing anything:

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- --dry-run
```

Verify:

```bash
asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'amd_ws show settings'
```

Uninstall: append `--uninstall` to the install command.

## 3. Dialplan

```text
AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])
```

| Parameter | Default | Meaning |
|---|---|---|
| `host` | `api.amdy.io` (from `amd_ws.conf`) | AMD service host. |
| `port` | `2700` | TCP port. |
| `vid` | `${CALLERID(name)}` | Call tracking id (ViciDial keeps its call id in the caller id name). |
| `timeout_ms` | `10000` | Detection window, counted from the first audio frame. |
| `playfile` | none | Sound to play to the callee **while** detection runs (`Playback()` semantics: no extension, `&` joins several files). Stops the instant a verdict arrives. |
| `options` | none | Flags, see below. |

### ViciDial / Vicibox (extension 8370)

Replace the `EAGI(...amd.py)` line of your existing 8370 block; everything else stays:

```text
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000)
exten => 8370,n,GotoIf($["${AMDCAUSE}" = "CONNECTION_ERROR" | "${AMDCAUSE}" = "PROCESSING_ERROR" | "${AMDCAUSE}" = "FATAL_ERROR"]?amd_fallback:continue)
exten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)
exten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
```

Then `asterisk -rx 'dialplan reload'`. Campaign settings (Routing Extension 8370, AMD
Agent Route Options) are unchanged. The phone number and country code are looked up
in `vicidial_auto_calls` automatically, as the EAGI client did.

### Generic Asterisk (custom dialer)

```text
exten => s,1,Answer()
exten => s,n,AMD_WS(api.amdy.io,2700,${UNIQUEID},10000)
exten => s,n,GotoIf($["${AMDSTATUS}" = "MACHINE"]?machine:human)
exten => s,n(human),Dial(...)                       ; live person
exten => s,n(machine),Hangup()                     ; or leave a message
```

Add option `n` when there is no ViciDial database on the box (`AMD_WS(api.amdy.io,2700,${UNIQUEID},10000,,n)`).

### Play a prompt during detection

```text
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000,custom/hello,d(500))
```

Plays `custom/hello` (from `/var/lib/asterisk/sounds`) starting 500 ms in, while the
callee's audio is analysed; playback stops as soon as the verdict is known. The file
must be 8 kHz mono (`sox in.wav -r 8000 -c 1 -b 16 hello.wav`).

### Options

| Option | Meaning |
|---|---|
| `n` | Skip the ViciDial phone/country lookup for this call. |
| `p(phone)` / `k(code)` | Send this phone number / country code explicitly instead of looking them up. |
| `i(cid)` | Send this value as `caller_id` (default: the channel's `${CALLERID(num)}`). |
| `d(ms)` | Delay before `playfile` starts. |
| `c(ms)` | Connect timeout (default 10000). |
| `s` | Use TLS (`wss://`). |
| `A` | Do not answer the channel (default: answer if needed). |
| `v` | Trace: log one line per event for this call (see section 7). |

## 4. Results — channel variables

| Variable | Values |
|---|---|
| `AMDSTATUS` | `HUMAN`, `MACHINE`, `NOTSURE`, `HANGUP` |
| `AMDCAUSE` | `HUMAN`; the service's reply on a machine (e.g. `AMD-4.50-0.95`, `NUMBERSAMD-4.50-0.93`, `OTHERAMD-4.50-0.92`); or an error/timeout cause below |
| `AMDSTATS` | `<elapsed_ms>-<audio_ms_sent>-<chunks>-<bytes>` (ViciDial logs the first number as `run_time`) |
| `AMDRESPONSE` | The last raw text the service sent |
| `AMDELAPSED` | Milliseconds from the first audio frame to the result |

| Situation | `AMDSTATUS` | `AMDCAUSE` |
|---|---|---|
| Live person | `HUMAN` | `HUMAN` |
| Answering machine / voicemail | `MACHINE` | service reply, e.g. `AMD-4.50-0.95` |
| Service unreachable (DNS, firewall, connect timeout) | `HUMAN` | `CONNECTION_ERROR` |
| Connection dropped during detection | `HUMAN` | `PROCESSING_ERROR` |
| Internal failure on the Asterisk side | `HUMAN` | `FATAL_ERROR` |
| No verdict within `timeout_ms` | `NOTSURE` | `SERVER_TIMEOUT` |
| No audio received at all (RTP never arrived) | `NOTSURE` | `NOAUDIODATA-<ms>` |
| Callee hung up during detection | `HANGUP` | `HANGUP` |
| Audio stopped mid-call, service could not finalise | `NOTSURE` | `EOF_INCONCLUSIVE` / `EOF_ERROR` |

Errors default to `HUMAN` on purpose: a call is never lost because the AMD service
was unreachable — it goes to an agent (or, in ViciDial, to the built-in `AMD()` via
the fallback line above). `NOAUDIODATA-<ms>` and `HANGUP` are the exact values
Asterisk's built-in `AMD()` uses, so ViciDial's dead-air handling
(`NOAUDIODATA-Hangup-ENABLED`, disposition `ADAIR`) works unchanged.

## 5. Configuration file (optional)

`/etc/asterisk/amd_ws.conf` — copy from `amd_ws.conf.sample`; reload with
`asterisk -rx 'module reload app_amd_ws.so'`. Nothing is required; the dialplan
arguments override the file.

| Key | Default | Meaning |
|---|---|---|
| `host`, `port` | `api.amdy.io`, `2700` | Service endpoint when the dialplan gives none. |
| `timeout_ms` | `10000` | Detection window. |
| `connect_timeout_ms` | `10000` | Connect timeout; lower it (2000–3000) to fall back faster when the service is unreachable. |
| `send_schedule` | `500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000` | When (ms from the first audio frame) audio is sent. `500,1000,1500,…,9000` in 0.5 s steps delivers audio up to 0.5 s sooner. |
| `tls`, `tls_verify`, `tls_cafile` | `no`, `yes`, system CA | `wss://` connections. |
| `db`, `db_timeout_ms` | `yes`, `1000` | ViciDial phone/country lookup (credentials from `/etc/astguiclient.conf`). |
| `send_caller_id` | `yes` | Send `${CALLERID(num)}` as `caller_id`. |
| `playdelay_ms` | `0` | Default delay before `playfile`. |
| `trace` | `no` | Per-call event timeline in the log for every call. |
| `extra_config` | empty | Extra service options as JSON, e.g. `{"short_no_greeting":true}` (verdict ~0.5 s earlier, but without the machine type) or `{"detection_mode":"aggressive"}`. |

## 6. How long does a verdict take?

Typically **5–6 seconds after the callee's first audio**. The service classifies
speech in stages and gives its final answer (including *which* kind of machine)
once it has 4.5 s of speech; leading silence does not count. Chunks are sent on
the schedule above and the service answers within ~50 ms of the chunk that
completes its analysis. A human is usually recognised earlier. To trade the machine
type for speed use `extra_config={"short_no_greeting":true}`; to shave the schedule
granularity use a 0.5 s `send_schedule`.

## 7. Troubleshooting

Health check in one line:

```bash
asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'amd_ws show settings' | head -30; timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo "port 2700 open"
```

Every call writes two lines to `/var/log/asterisk/messages` (or `full`):

```text
AMD_WS: SIP/trunk-0004706c vid=V9231813370204367076 host=api.amdy.io:2700 play=none
AMD_WS: SIP/trunk-0004706c vid=V9231813370204367076 status=MACHINE cause=OTHERAMD-4.50-0.9280 elapsed=6106 sent=96320 chunks=8
```

| `AMDCAUSE` | What it means | What to check |
|---|---|---|
| `CONNECTION_ERROR` | The server could not reach the service | Outbound TCP 2700 to **all** `api.amdy.io` addresses (`dig +short api.amdy.io`); DNS; `module show like res_http_websocket` |
| `PROCESSING_ERROR` | Connected, then the connection broke | Middleboxes cutting WebSockets; `${AMDRESPONSE}`; contact support with the VID |
| `SERVER_TIMEOUT` | Connected, audio sent, no verdict in time | `${AMDRESPONSE}`; contact support with the VID |
| `NOAUDIODATA-<ms>` | No audio ever reached Asterisk | RTP/NAT/codec on the trunk; `rtp set debug on` — not an AMD problem |
| `FATAL_ERROR` | Module-internal (codec, memory, config) | `AMD_WS` warnings in the log; `amd_ws.conf` |
| empty variables | `AMD_WS()` never ran | `dialplan show 8370@default`; module loaded? |

For a full timeline of one call add option `v` (or `trace=yes`) and grep
`AMD_WS:` — you will see the connect, the first audio frame, every chunk sent,
every reply and the result with millisecond offsets.

## 8. Upgrading / uninstalling

Re-run the install command: it builds the new version, backs up the old module
(`app_amd_ws.so.bak.<timestamp>`) and swaps it in without dropping calls (if the
module is busy it waits, never hangs up). `--uninstall` removes the module; your
dialplan is never modified by the installer.

Source, changelog and full reference: https://github.com/nikvb/amd
