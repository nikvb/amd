# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

app_amd_ws is an Asterisk module that performs Answering Machine Detection (AMD) by streaming audio to an external WebSocket server and receiving classification results (HUMAN/MACHINE).

## Build Commands

```bash
# Build the module (auto-detects Asterisk headers)
make

# Build with specific Asterisk source path
ASTTOPDIR=/path/to/asterisk-source make

# Or specify include directory directly
ASTINCDIR=/usr/include make

# Install to Asterisk modules directory
make install

# Reload module in running Asterisk
make reload

# Unload/load module individually
make unload
make load

# Clean build artifacts
make clean
```

## Quick Install (as root)

```bash
./install.sh              # Install deps, build, and load module
./install.sh --deps-only  # Only install dependencies
./install.sh --build-only # Build without installing
./install.sh --uninstall  # Remove the module
```

## Dependencies

- Asterisk 16+ with headers (asterisk-dev package or source)
- libwebsockets development library
- GCC compiler

## Architecture

Single-file C module (`app_amd_ws.c`) that:

1. **Asterisk Integration**: Registers `AMD_WS()` dialplan application via `ast_register_application_xml`
2. **WebSocket Client**: Uses libwebsockets to connect to external AMD server
3. **Audio Streaming**: Captures audio frames from channel, buffers 500ms chunks (8000 bytes at 8kHz/16-bit), and sends each chunk as a binary WebSocket frame when the buffer fills
4. **Result Handling**: Sets `AMDSTATUS` (HUMAN/MACHINE/NOTSURE) and `AMDCAUSE` channel variables

Key structures:
- `struct amd_ws_session` - Per-call state including WebSocket connection, audio buffer, and result
- `ws_callback()` - libwebsockets callback handling connection lifecycle and data transfer
- `amd_ws_exec()` - Main detection loop that reads audio frames and manages WebSocket communication

## Protocol

The module sends a JSON config on connect:
```json
{"config":{"sample_rate":8000,"VID":"caller-id"}}
```

Audio is sent as binary WebSocket frames at scheduled intervals. Server responds with empty acks until detection completes, then sends a result containing HUMAN or MACHINE.

## Debugging

```bash
# Enable Asterisk debug logging
asterisk -rx "core set debug 3"

# Check module is loaded
asterisk -rx "module show like amd_ws"
```
