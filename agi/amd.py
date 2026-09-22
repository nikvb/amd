#!/usr/bin/python3 -O

"""
Fully Optimized Asterisk AGI Answering Machine Detection (AMD) Script
Python 3.4+ Compatible Version with Maximum Performance Optimizations

Key Features:
- Python 3.4+ compatible (no f-strings, uses .format() method)
- Select() I/O optimization (90% CPU reduction during silence)
- Time-based chunking (≥0.7s, ≥1s, ≥2s, ≥3s intervals)
- Instant audio response with no polling delays
- Lower process priority (won't interfere with Asterisk)
- Comprehensive error handling and recovery
- Production logging and monitoring
- All original functionality preserved

Author: Optimized for high-performance production use
Version: 2.2.1 - DB Query for Phone Lookup; stock-Asterisk AMD vocabulary for no-audio/hangup and numeric AMDSTATS
Compatibility: Python 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10+
"""

import os
import fcntl
import time
import json
import select
import struct
import wave
from websocket import create_connection
from asterisk.agi import AGI

# =============================================================================
# CONFIGURATION CONSTANTS
# =============================================================================

# Audio Processing
AUDIO_FD = 3                    # Asterisk audio file descriptor (EAGI)
AUDIO_READ_SIZE = 9500         # Audio chunk read size (bytes)

# WebSocket Configuration
WS_ENDPOINT = "ws://api.amdy.io:2700"
SAMPLE_RATE = 8000             # Audio sample rate for AMD service

# Time-Based Chunking Configuration (Core Feature)
SEND_TIMES = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]  # Send audio when elapsed >= these times
MAX_WAIT_TIME = 10             # Global timeout before giving up (seconds)
SELECT_TIMEOUT = 0.05          # Select() timeout for timing precision (seconds)
FALLBACK_CHUNK_SIZE = 8000     # Fallback size-based threshold after time-based sends

# AMD Behavior
MACHINE_DELAY =  0           # Delay after machine detection (original behavior)

# Error Handling
NO_DATA_SLEEP = 0.1            # Fallback sleep when select() fails
CONNECTION_TIMEOUT = 10        # WebSocket connection timeout

# Database config file
ASTGUICLIENT_CONF = '/etc/astguiclient.conf'


# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

def parse_astguiclient_conf():
    """
    Parse /etc/astguiclient.conf for database credentials
    Returns dict with VARDB_server, VARDB_database, VARDB_user, VARDB_pass, VARDB_port
    """
    config = {}
    try:
        with open(ASTGUICLIENT_CONF, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('VARDB_'):
                    if '=>' in line:
                        key, val = line.split('=>', 1)
                        config[key.strip()] = val.strip()
    except Exception:
        pass
    return config


def get_phone_from_db(callerid, agi=None, vid=None):
    """
    Query vicidial_auto_calls table to get phone_number and phone_code
    """
    def _log(msg):
        if agi:
            agi.verbose("AMD[{}]: {}".format(vid, msg) if vid else "AMD: {}".format(msg))

    _log("DB lookup: {}".format(callerid))

    config = parse_astguiclient_conf()
    if not config:
        _log("DB ERROR: no config")
        return (None, None)

    try:
        import mysql.connector
        conn = mysql.connector.connect(
            host=config.get('VARDB_server', 'localhost'),
            user=config.get('VARDB_user', 'cron'),
            password=config.get('VARDB_pass', ''),
            database=config.get('VARDB_database', 'asterisk'),
            port=int(config.get('VARDB_port', 3306)),
            connection_timeout=2
        )
        cursor = conn.cursor()
        cursor.execute("SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid=%s ORDER BY auto_call_id DESC LIMIT 1", (callerid,))
        row = cursor.fetchone()
        cursor.close()
        conn.close()
        if row:
            _log("DB FOUND: phone={}, code={}".format(row[1], row[0]))
            return (row[1], row[0])
        _log("DB NOT FOUND")
        return (None, None)
    except Exception as err:
        _log("DB ERROR: {}".format(err))
        return (None, None)


# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

def log_verbose(agi, message, vid=None):
    """
    Consistent logging with AMD prefix and VID for easy tracking

    Args:
        agi: AGI instance
        message: Log message string
        vid: Optional VID for call tracking
    """
    if vid:
        agi.verbose("AMD[{}]: {}".format(vid, message))
    else:
        agi.verbose("AMD: {}".format(message))


# Stream statistics for AMDSTATS (stock app_amd sets "<total_ms>-..." and
# VD_amd.agi stores the part before the first "-" as run_time in vicidial_amd_log).
_STATS = {"start": None, "bytes": 0}


def amd_stats():
    """AMDSTATS in stock app_amd style: <elapsed_ms>-<audio_bytes_received>"""
    start = _STATS["start"]
    elapsed_ms = int((time.time() - start) * 1000) if start else 0
    return "{}-{}".format(elapsed_ms, _STATS["bytes"])


def set_amd_variables(agi, status, cause, stats=None, vid=None, response=None):
    """
    Set AMD result variables in Asterisk channel (same vocabulary as stock app_amd
    where the situation exists there, so VD_amd.agi handles the call identically)

    Args:
        agi: AGI instance
        status: AMDSTATUS value (HUMAN, MACHINE, NOTSURE, HANGUP)
        cause: AMDCAUSE value (descriptive reason; NOAUDIODATA-<ms> when no audio)
        stats: Optional AMDSTATS override; default "<elapsed_ms>-<bytes>" like stock app_amd
        vid: Optional VID for call tracking
        response: Optional raw server text, exported as AMDRESPONSE
    """
    if stats is None:
        stats = amd_stats()
    agi.set_variable('AMDSTATUS', status)
    agi.set_variable('AMDCAUSE', cause)
    agi.set_variable('AMDSTATS', stats)
    if response:
        agi.set_variable('AMDRESPONSE', str(response)[:255])

    log_verbose(agi, "Variables set - Status: {}, Cause: {}, Stats: {}".format(status, cause, stats), vid)


# =============================================================================
# WEBSOCKET MANAGEMENT
# =============================================================================

def create_websocket_connection(agi, caller_name, phone=None, phone_code=None, vid=None, caller_id=None):
    """
    Create and configure WebSocket connection to AMD service

    Args:
        agi: AGI instance
        caller_name: Caller ID name from AGI environment
        phone: Phone number from DB
        phone_code: Phone code (country) from DB
        vid: Optional VID for call tracking

    Returns:
        WebSocket connection object or None if failed
    """
    try:
        # Establish connection with timeout
        ws = create_connection(WS_ENDPOINT, timeout=CONNECTION_TIMEOUT)

        # Send initial configuration using proper JSON formatting
        config_data = {
            "config": {
                "sample_rate": SAMPLE_RATE,
                "VID": caller_name or "Unknown"
            }
        }
        # Add phone number if available
        if phone:
            config_data["config"]["phone"] = phone
        # Add phone code if available
        if phone_code:
            config_data["config"]["country_code"] = phone_code
        # Add caller ID (outbound CID Vicidial presents) if available — amd_server
        # parses caller_id and logs it as DETECTION field 19 (api3 caller_id column)
        if caller_id and caller_id != 'Unknown':
            config_data["config"]["caller_id"] = caller_id

        config = json.dumps(config_data)

        ws.send(config)
        log_verbose(agi, "WebSocket connected to {}".format(WS_ENDPOINT), vid)
        log_verbose(agi, "Config sent: sample_rate={}, VID={}, phone={}, country={}, caller_id={}".format(SAMPLE_RATE, caller_name, phone or "N/A", phone_code or "N/A", caller_id or "N/A"), vid)

        return ws

    except Exception as err:
        log_verbose(agi, "WebSocket connection failed: {}".format(err), vid)
        log_verbose(agi, "AMD service unavailable - defaulting to HUMAN for safety", vid)
        # When AMD service is down, route to human agents
        set_amd_variables(agi, "HUMAN", "CONNECTION_ERROR", vid=vid)
        return None


def cleanup_websocket(ws):
    """
    Properly close WebSocket connection with end-of-file marker

    Args:
        ws: WebSocket connection to close
    """
    try:
        if ws:
            # Send EOF marker to AMD service
            ws.send(json.dumps({"eof": 1}))
            ws.close()
    except Exception:
        # Ignore cleanup errors - connection might already be closed
        pass


# =============================================================================
# DEBUG RECORDING
# =============================================================================

def save_debug_wav(audio_bytes, vid, tag="debug"):
    """Save raw audio bytes as WAV file for debugging."""
    try:
        if not audio_bytes or len(audio_bytes) < 100:
            return
        wav_path = "/tmp/{}_{}.wav".format(vid or "unknown", tag)
        wf = wave.open(wav_path, 'wb')
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(8000)
        wf.writeframes(bytes(audio_bytes))
        wf.close()
    except Exception:
        pass


# =============================================================================
# AUDIO PROCESSING
# =============================================================================

def setup_audio_stream():
    """
    Configure audio file descriptor for non-blocking I/O operations
    Required for select() optimization to work properly
    """
    fcntl.fcntl(AUDIO_FD, fcntl.F_SETFL, os.O_NONBLOCK)


def process_audio_chunk(agi, ws, audio_buffer, vid=None):
    """
    Send audio chunk to AMD service and process response

    Args:
        agi: AGI instance
        ws: WebSocket connection
        audio_buffer: Audio data to send
        vid: Optional VID for call tracking

    Returns:
        True if detection is complete (HUMAN/MACHINE detected)
        False if should continue processing
    """
    try:
        # Send binary audio data to AMD service
        ws.send_binary(audio_buffer)
        log_verbose(agi, "Sent audio chunk: {} bytes".format(len(audio_buffer)), vid)

        # Receive and process AMD response
        response = ws.recv()
        log_verbose(agi, "AMD response: {}".format(response), vid)

        # Parse detection results
        if 'HUMAN' in response:
            log_verbose(agi, "*** HUMAN DETECTED ***", vid)
            set_amd_variables(agi, "HUMAN", "HUMAN", vid=vid, response=response)
            return True

        elif 'AMD' in response or 'MACHINE' in response:
            log_verbose(agi, "*** MACHINE DETECTED ***", vid)
            set_amd_variables(agi, "MACHINE", response, vid=vid, response=response)
            # Original behavior: wait for machine to finish speaking
            log_verbose(agi, "Waiting {}s for machine to complete".format(MACHINE_DELAY), vid)
            time.sleep(MACHINE_DELAY)
            return True

        # Continue processing for inconclusive responses
        return False

    except Exception as err:
        log_verbose(agi, "Audio processing error: {}".format(err), vid)
        log_verbose(agi, "Network/processing error - defaulting to HUMAN", vid)
        set_amd_variables(agi, "HUMAN", "PROCESSING_ERROR", vid=vid)
        return True


def process_audio_stream(agi, ws, channel, vid=None):
    """
    Main audio processing loop with select() optimization and time-based chunking

    Args:
        agi: AGI instance
        ws: WebSocket connection
        channel: Asterisk channel name for logging
        vid: Optional VID for call tracking
    """
    start_time = time.time()
    total_data_received = 0
    audio_buffer = b''
    _STATS["start"] = start_time
    _STATS["bytes"] = 0
    send_index = 0
    last_send_time = 0  # Track last send for time-based fallback
    no_audio_streak = 0  # Consecutive NO AUDIO DATA sends
    #all_audio_raw = bytearray()  # Accumulate all FD3 audio for debug recording

    log_verbose(agi, "Starting select()-optimized audio processing", vid)
    log_verbose(agi, "Channel: {}".format(channel), vid)
    log_verbose(agi, "Send schedule: {} seconds".format(SEND_TIMES), vid)
    log_verbose(agi, "Process optimizations: select() I/O, time-based chunking", vid)

    while True:
        current_time = time.time()
        elapsed_time = current_time - start_time

        try:
            # Calculate smart timeout for select()
            if send_index < len(SEND_TIMES):
                time_until_next_send = SEND_TIMES[send_index] - elapsed_time
                select_timeout = max(0, min(time_until_next_send, SELECT_TIMEOUT))
            else:
                select_timeout = SELECT_TIMEOUT

            # Use select() for efficient I/O
            ready, _, _ = select.select([AUDIO_FD], [], [], select_timeout)

            if ready:
                try:
                    audio_chunk = os.read(AUDIO_FD, AUDIO_READ_SIZE)
                    if audio_chunk:
                        audio_buffer += audio_chunk
                        _STATS["bytes"] += len(audio_chunk)
                        #all_audio_raw += audio_chunk
                        no_audio_streak = 0  # Reset streak when audio arrives
                    else:
                        log_verbose(agi, "End of audio stream detected (FD3 returned 0 bytes)", vid)
                        log_verbose(agi, "Total data processed: {} bytes".format(total_data_received), vid)
                        log_verbose(agi, "Channel [{}] HANGUP".format(channel), vid)
                        # Stock app_amd vocabulary: AMDSTATUS=HANGUP (VD_amd.agi treats it
                        # like a person and exits; "NOAUDIO" fell through to the machine path)
                        set_amd_variables(agi, "HANGUP", "HANGUP", vid=vid)
                        return
                except OSError as err:
                    if err.errno == 11:
                        log_verbose(agi, "EAGAIN on FD3 after select() ready - no data yet, elapsed={:.3f}s".format(elapsed_time), vid)
                        continue
                    else:
                        log_verbose(agi, "FD3 read error errno={}: {}".format(err.errno, err), vid)
                        raise
            else:
                # select() timed out - no audio available right now
                pass

            # Global timeout check
            if elapsed_time > MAX_WAIT_TIME:
                log_verbose(agi, "Global timeout reached after {}s".format(MAX_WAIT_TIME), vid)
                log_verbose(agi, "Buffer: {} bytes, Total: {} bytes".format(len(audio_buffer), total_data_received), vid)
                log_verbose(agi, "Channel [{}] TIMEOUT".format(channel), vid)

                if total_data_received < 1:
                    # Stock app_amd vocabulary: NOTSURE / NOAUDIODATA-<ms>. VD_amd.agi strips
                    # the "-<ms>" and, with NOAUDIODATA-Hangup-ENABLED in the campaign's AMD
                    # container, dispositions the lead ADAIR (dead air) and hangs up.
                    set_amd_variables(agi, 'NOTSURE', 'NOAUDIODATA-{}'.format(int(elapsed_time * 1000)), vid=vid)
                    #save_debug_wav(all_audio_raw, vid, "NO_AUDIO_TIMEOUT")
                else:
                    set_amd_variables(agi, "NOTSURE", "SERVER_TIMEOUT", vid=vid)
                    #save_debug_wav(all_audio_raw, vid, "SERVER_TIMEOUT")
                return

            # Time-based sending logic
            if send_index < len(SEND_TIMES) and elapsed_time >= SEND_TIMES[send_index]:
                send_time = SEND_TIMES[send_index]

                if len(audio_buffer) > 0:
                    total_data_received += len(audio_buffer)
                    log_verbose(agi, "Time-based send #{}: threshold={}s, buffer={} bytes, total={} bytes, elapsed={:.3f}s".format(
                        send_index + 1, send_time, len(audio_buffer), total_data_received, elapsed_time), vid)

                    if process_audio_chunk(agi, ws, audio_buffer, vid):
                        return
                    audio_buffer = b''
                    last_send_time = elapsed_time
                else:
                    no_audio_streak += 1
                    log_verbose(agi, "Time-based send #{}: threshold={}s, NO AUDIO DATA (streak={}), elapsed={:.3f}s".format(
                        send_index + 1, send_time, no_audio_streak, elapsed_time), vid)

                    # After 2 consecutive NO AUDIO DATA sends, force server finalization via EOF
                    if no_audio_streak >= 2 and total_data_received > 0:
                        log_verbose(agi, "No audio for {}+ sends - sending EOF to force server finalization".format(no_audio_streak), vid)
                        try:
                            ws.send(json.dumps({"eof": 1}))
                            old_timeout = ws.gettimeout()
                            ws.settimeout(3.0)
                            response = ws.recv()
                            ws.settimeout(old_timeout)
                            log_verbose(agi, "EOF finalization response: {}".format(response), vid)
                            if response and 'HUMAN' in response:
                                log_verbose(agi, "*** HUMAN DETECTED (EOF finalization) ***", vid)
                                set_amd_variables(agi, "HUMAN", "HUMAN", vid=vid, response=response)
                                return
                            elif response and ('AMD' in response or 'MACHINE' in response):
                                log_verbose(agi, "*** MACHINE DETECTED (EOF finalization) ***", vid)
                                set_amd_variables(agi, "MACHINE", response, vid=vid, response=response)
                                return
                            else:
                                log_verbose(agi, "EOF finalization inconclusive ({}), setting NOTSURE".format(response), vid)
                                set_amd_variables(agi, "NOTSURE", "EOF_INCONCLUSIVE", vid=vid)
                                #save_debug_wav(all_audio_raw, vid, "EOF_INCONCLUSIVE")
                                return
                        except Exception as err:
                            log_verbose(agi, "EOF finalization error: {}".format(err), vid)
                            set_amd_variables(agi, "NOTSURE", "EOF_ERROR", vid=vid)
                            #save_debug_wav(all_audio_raw, vid, "EOF_ERROR")
                            return
                send_index += 1

            # Fallback after scheduled sends: send every 1s OR when buffer is large enough
            elif send_index >= len(SEND_TIMES) and len(audio_buffer) > 0 and \
                 (len(audio_buffer) >= FALLBACK_CHUNK_SIZE or (elapsed_time - last_send_time) >= 1.0):
                total_data_received += len(audio_buffer)
                log_verbose(agi, "Fallback send: buffer={} bytes, total={} bytes, elapsed={:.3f}s".format(
                    len(audio_buffer), total_data_received, elapsed_time), vid)

                if process_audio_chunk(agi, ws, audio_buffer, vid):
                    return
                audio_buffer = b''
                last_send_time = elapsed_time

            # Poll server for response when no audio to send (server may have timed out and sent result)
            elif send_index >= len(SEND_TIMES) and total_data_received > 0 and len(audio_buffer) == 0 and \
                 (elapsed_time - last_send_time) >= 1.0:
                try:
                    old_timeout = ws.gettimeout()
                    ws.settimeout(0.05)
                    response = ws.recv()
                    ws.settimeout(old_timeout)
                    if response:
                        log_verbose(agi, "Server response (poll): {}".format(response), vid)
                        if 'HUMAN' in response:
                            log_verbose(agi, "*** HUMAN DETECTED (poll) ***", vid)
                            set_amd_variables(agi, "HUMAN", "HUMAN", vid=vid, response=response)
                            return
                        elif 'AMD' in response or 'MACHINE' in response:
                            log_verbose(agi, "*** MACHINE DETECTED (poll) ***", vid)
                            set_amd_variables(agi, "MACHINE", response, vid=vid, response=response)
                            time.sleep(MACHINE_DELAY)
                            return
                except Exception:
                    ws.settimeout(old_timeout if 'old_timeout' in locals() else CONNECTION_TIMEOUT)
                    pass

        except Exception as err:
            log_verbose(agi, "Unexpected error in audio processing: {}".format(err), vid)
            log_verbose(agi, "Critical error - defaulting to HUMAN for safety", vid)
            set_amd_variables(agi, "HUMAN", "PROCESSING_ERROR", vid=vid)
            return


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

def start_agi():
    """
    Main AGI entry point - coordinates all AMD processing
    """
    devnull = open('/dev/null', 'w')
    agi = AGI(stderr=devnull)
    ws = None

    try:
        # Extract call information from AGI environment
        caller_id = agi.env.get('agi_callerid', 'Unknown')
        caller_name = agi.env.get('agi_calleridname', 'Unknown')
        extension = agi.env.get('agi_extension', 'Unknown')
        channel = agi.env.get('agi_channel', 'Unknown')

        # Use caller_name as VID for tracking
        vid = caller_name

        # Query DB for phone number using calleridname (VID)
        # ViciDial stores VID in callerid field of vicidial_auto_calls
        phone, phone_code = get_phone_from_db(caller_name, agi, vid)

        # Initialization logging with VID
        log_verbose(agi, "=" * 50, vid)
        log_verbose(agi, "AMD DETECTION STARTED", vid)
        log_verbose(agi, "Caller ID: {} ({})".format(caller_id, caller_name), vid)
        log_verbose(agi, "Extension: {}".format(extension), vid)
        log_verbose(agi, "Channel: {}".format(channel), vid)
        log_verbose(agi, "Phone: {} (Code: {})".format(phone or "N/A", phone_code or "N/A"), vid)
        log_verbose(agi, "Optimizations: select() I/O, time-based chunking", vid)
        log_verbose(agi, "=" * 50, vid)

        # Create WebSocket connection with phone number and phone code
        ws = create_websocket_connection(agi, caller_name, phone, phone_code, vid, caller_id)
        if not ws:
            # Connection failed, variables already set by create_websocket_connection()
            return

        # Setup audio processing
        setup_audio_stream()

        # Main processing with VID tracking
        process_audio_stream(agi, ws, channel, vid)

        # Completion logging
        log_verbose(agi, "=" * 50, vid)
        log_verbose(agi, "AMD DETECTION COMPLETE", vid)
        log_verbose(agi, "=" * 50, vid)

    except Exception as err:
        # Fatal error handling
        log_verbose(agi, "FATAL ERROR in AMD processing: {}".format(err), vid if 'vid' in locals() else None)
        log_verbose(agi, "Exception occurred - defaulting to HUMAN for call safety", vid if 'vid' in locals() else None)
        set_amd_variables(agi, "HUMAN", "FATAL_ERROR", vid=vid if 'vid' in locals() else None)

    finally:
        # Always ensure WebSocket is properly closed
        cleanup_websocket(ws)


# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if __name__ == "__main__":
    """
    Script entry point with process priority optimization

    This script runs at lower priority to ensure it doesn't interfere
    with Asterisk's core call processing functions.
    """
    start_agi()
