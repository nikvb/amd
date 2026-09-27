# ViciDial: iPhone / Google Voice call screening — hold and redial

iPhone "Call Screening", Samsung "Call Assist" and Google Voice screening answer
the call with a robot that asks who is calling and only then decides whether to
ring the person. A plain `MACHINE` verdict hangs up at the robot and the lead is
burned. AMDY reports these cases with their own classes, and while the screening
session is **held open**, a second call to the same number arrives as
**call waiting** and rings the person directly. The dialplan below does exactly
that: hold the screened leg, redial the number once, and let the second call
land on extension 8370 for a fresh detection and normal agent routing.

## What AMDY returns

`AMDSTATUS=MACHINE`, `AMDCAUSE=<CLASS>-<dur>-<confidence>` where `<CLASS>` is one of:

| Class | Meaning |
|---|---|
| `CALLASSISTSCRNAMD` | iPhone / Samsung call-assistant screening prompt |
| `GVOICEAMD` | Google Voice screening |
| `SCREENINGAMD` | generic / legacy screening class |

`AMD_WS` 2.0 also exports **`AMDPHONE`** and **`AMDCOUNTRYCODE`** — the number and
country code it looked up in `vicidial_auto_calls` (or received via `p()`/`k()`) —
so the dialplan knows what to redial.

## Dialplan (extension 8370)

Only the lines between `screen_check` and `continue`, plus the `[amdws-screen-hold]`
context, are new. `9` is the campaign's dial prefix — use whatever your carrier
pattern in `[default]` expects (this is the same `Local/9<number>@default` channel
ViciDial itself originates).

```text
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000)
exten => 8370,n,GotoIf($["${AMDCAUSE}" = "CONNECTION_ERROR" | "${AMDCAUSE}" = "PROCESSING_ERROR" | "${AMDCAUSE}" = "FATAL_ERROR"]?amd_fallback:screen_check)
exten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)
exten => 8370,n,Goto(continue)
; --- call screening: hold this leg and redial the number once (call waiting rings the person) ---
exten => 8370,n(screen_check),Set(AMDCLASS=${CUT(AMDCAUSE,-,1)})
exten => 8370,n,GotoIf($["${AMDSTATUS}" = "MACHINE" & "${SCREEN_REDIAL}" != "1" & "${AMDPHONE}" != "" & ("${AMDCLASS}" = "CALLASSISTSCRNAMD" | "${AMDCLASS}" = "GVOICEAMD" | "${AMDCLASS}" = "SCREENINGAMD")]?amdws-screen-hold,s,1)
; --- end of screening block ---
exten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})

[amdws-screen-hold]
; The screened leg waits here while the redial rings (up to 55 s). This context has
; its own empty h extension: the held leg must NOT run ViciDial's hangup AGI, or it
; would close the lead's vicidial_auto_calls row under the second call.
exten => s,1,NoOp(AMD_WS: ${AMDCLASS} - holding the screened leg, redialing ${AMDPHONE} once)
exten => s,n,Originate(Local/9${AMDPHONE}@default,exten,default,8370,1,55,c(${CALLERID(num)})n(${CALLERID(name)})v(SCREEN_REDIAL=1))
exten => s,n,NoOp(AMD_WS: redial result ${ORIGINATE_STATUS})
exten => s,n,GotoIf($["${ORIGINATE_STATUS}" = "SUCCESS"]?answered)
; nobody picked up the redial: hand this leg back to ViciDial as a machine result
exten => s,n,Set(AMDSTATUS=MACHINE)
exten => s,n,Set(AMDCAUSE=${AMDCLASS}-REDIAL-${ORIGINATE_STATUS})
exten => s,n,Goto(default,8370,continue)
exten => s,n(answered),Hangup()
exten => h,1,NoOp(AMD_WS: screened leg released (second call owns the lead))
```

How it behaves:

1. `AMD_WS` says `MACHINE / CALLASSISTSCRNAMD-…`. The leg jumps to `[amdws-screen-hold]`.
2. `Originate()` places **one** new call to `9<AMDPHONE>` through the normal carrier
   pattern, with the same outbound caller id (`c()`) and the same VID as caller id
   name (`n()`), and waits **up to 55 s** for it to be answered — the screened leg is
   held the whole time, which keeps the screening session busy.
3. The person sees a second incoming call (call waiting) and answers. That call
   executes `8370@default` from the top: `call_log`, `AMD_WS` (a fresh detection;
   `SCREEN_REDIAL=1` prevents a third call if it is screened again), then
   `VD_amd.agi` → `agi-VDAD_ALL_outbound.agi`, which updates the lead's
   `vicidial_auto_calls` row to the new channel and routes to an agent. As soon
   as it is answered the held leg hangs up (`answered`) inside the hold context,
   so ViciDial's hangup AGI does not run for it.
4. Nobody answers within 55 s (`ORIGINATE_STATUS` = `RINGING`, `NOANSWER`, `BUSY`,
   `FAILED`): the held leg goes back to `8370,continue` as `MACHINE` /
   `CALLASSISTSCRNAMD-REDIAL-<status>`. `VD_amd.agi` sees `AMDRESPONSE=CALLASSISTSCRNAMD`
   and dispositions the lead as usual (AA), and the normal `h` extension of
   `[default]` runs when it hangs up.

Verified on the test harness (mock service, simulated carrier): answered path —
second call lands on 8370 with `SCREEN_REDIAL=1` and the caller id, held leg
released on answer; no-answer path — held leg returns to `continue` with
`MACHINE / CALLASSISTSCRNAMD-REDIAL-RINGING`.

Notes:
- **One redial per screening** is enforced by `SCREEN_REDIAL=1` on the second call.
- Each redial is a new carrier call and a new detection.
- If you want the screener to hear who is calling while the redial rings, put a
  `Playback(custom/screen-intro)` (8 kHz mono) before the `Originate` line; keep it
  short so the redial starts within a few seconds.
- Do this only for the three screening classes. `CALLASSISTAMD` (assistant answered,
  no screening prompt) and every other machine class go to `continue` unchanged.
- The `[amdws-screen-hold]` `h` extension is deliberately empty. If your `[default]`
  `h` is customised, do not copy it there.
- To have ViciDial place the redial itself instead (an `Originate` row in
  `vicidial_manager` processed by `AST_manager_send.pl`), the fields are the same:
  channel `Local/9<AMDPHONE>@default`, exten `8370`, context `default`, callerid
  `"<VID>" <cid>`, variable `SCREEN_REDIAL=1`. The dialplan `Originate()` needs no
  AMI credentials and was the tested path.

## Alternative: keep polling the same call

Where a second call is not wanted, the same leg can be held and re-polled: play a
short intro to the screener while listening, then run `AMD_WS` again (up to 3×12 s)
until the service returns `HUMAN`. Screeners that hand over on the same line (some
Google Voice configurations) work this way; iPhone screening usually does not, which
is why the redial is the primary recipe.

```text
exten => 8370,n(screen),Set(SCREEN_TRY=$[${SCREEN_TRY} + 1])
exten => 8370,n,GotoIf($[${SCREEN_TRY} > 3]?screen_giveup)
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},12000,custom/screen-intro,n)
exten => 8370,n,GotoIf($["${AMDSTATUS}" = "HUMAN"]?continue)
exten => 8370,n,GotoIf($["${AMDSTATUS}" = "HANGUP"]?screen_hangup)
exten => 8370,n,Goto(screen)
exten => 8370,n(screen_giveup),Set(AMDSTATUS=MACHINE)
exten => 8370,n,Set(AMDCAUSE=SCREENTIMEOUT-${SCREEN_TRY})
exten => 8370,n,Goto(continue)
```
