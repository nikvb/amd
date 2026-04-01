AMD_WS - Answering Machine Detection via WebSocket for Asterisk
================================================================

This Asterisk module performs Answering Machine Detection (AMD) by
streaming audio to an external WebSocket server and receiving
classification results (HUMAN/MACHINE).

Requirements
------------
- Asterisk 16+ with source code available
- libwebsockets development library
- GCC compiler

Quick Install
-------------
As root:
    ./install.sh

This will:
1. Install libwebsockets-dev dependency
2. Build the module
3. Install to Asterisk modules directory
4. Load the module into running Asterisk

Manual Build
------------
If you prefer to build manually:
    ASTTOPDIR=/path/to/asterisk-source make
    make install
    make reload

Dialplan Usage
--------------
Parameters: AMD_WS(host,port,vid,timeout_ms)

Example:
    exten => 8370,n,Set(VID=${CALLERID(name)})
    exten => 8370,n,AMD_WS(api.amdy.io,2700,${VID},5000)
    exten => 8370,n,GotoIf($["${AMDSTATUS}"="MACHINE"]?machine:human)
    exten => 8370,n(human),NoOp(Human detected)
    exten => 8370,n,Goto(continue)
    exten => 8370,n(machine),NoOp(Machine detected)
    exten => 8370,n(continue),...

Channel Variables Set
---------------------
AMDSTATUS - Detection result:
    HUMAN   - Human voice detected
    MACHINE - Answering machine detected
    NOTSURE - Could not determine
    HANGUP  - Channel hung up during detection

AMDCAUSE - Raw server response or error cause

Protocol
--------
The module sends a JSON config on connect:
    {"config":{"sample_rate":8000,"VID":"caller-id"}}

Then sends audio chunks at scheduled intervals (500ms, 1000ms,
1500ms, 2000ms, 3000ms, 4000ms) to match server expectations.

Server responds with empty acks until detection completes, then
sends a result containing HUMAN or MACHINE.

Troubleshooting
---------------
Enable debug logging in Asterisk:
    asterisk -rx "core set debug 3"

Check module is loaded:
    asterisk -rx "module show like amd_ws"

Uninstall
---------
    ./install.sh --uninstall

License
-------
GNU General Public License Version 2
