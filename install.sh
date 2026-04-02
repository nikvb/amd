#!/bin/bash
#
# app_amd_ws - Self-contained installer
# AMD (Answering Machine Detection) via WebSocket for Asterisk
#
# One-liner:
#   curl -sfL https://github.com/nikvb/amd/raw/main/install.sh | sudo bash
#
# Usage: bash install.sh [--uninstall|--deps-only|--build-only|--help]
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

MODULE_NAME="app_amd_ws"
BUILD_DIR=""

# --- Cleanup on exit ---
cleanup_build() {
    [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
}
trap cleanup_build EXIT

# --- Detect Asterisk version ---
get_asterisk_version() {
    local version=""
    if pgrep -x asterisk > /dev/null 2>&1; then
        version=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -1)
        [ -n "$version" ] && echo "$version" && return 0
    fi
    if command -v asterisk > /dev/null 2>&1; then
        version=$(asterisk -V 2>/dev/null | grep -oP 'Asterisk \K[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -1)
        [ -n "$version" ] && echo "$version" && return 0
    fi
    log_error "Cannot detect Asterisk version"
    return 1
}

# --- Find headers matching version ---
find_ast_headers() {
    local ast_version="$1"
    local ast_base=$(echo "$ast_version" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+')

    if [ -f "/usr/include/asterisk.h" ]; then
        echo "/usr/include"
        return 0
    fi
    for src in /usr/src/asterisk-${ast_version}*/; do
        [ -f "${src}include/asterisk.h" ] && echo "${src%/}" && return 0
    done
    if [ "$ast_base" != "$ast_version" ]; then
        for src in /usr/src/asterisk-${ast_base}*/; do
            [ -f "${src}include/asterisk.h" ] && echo "${src%/}" && return 0
        done
    fi
    return 1
}

# --- Download Asterisk source ---
download_asterisk_source() {
    local ast_version="$1"
    local ast_base=$(echo "$ast_version" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+')

    log_info "Downloading Asterisk ${ast_version} source headers..."
    cd /usr/src

    local urls=(
        "https://download.vicidial.com/required-apps/asterisk-${ast_version}.tar.gz"
        "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ast_base}.tar.gz"
        "https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-${ast_base}.tar.gz"
        "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ast_base}.tar.gz"
    )

    for url in "${urls[@]}"; do
        log_info "Trying: $url"
        if curl -sfL --connect-timeout 10 "$url" -o "asterisk-download.tar.gz"; then
            tar xzf "asterisk-download.tar.gz"
            rm -f "asterisk-download.tar.gz"
            local extracted=$(ls -dt asterisk-${ast_base}* 2>/dev/null | head -1)
            if [ -n "$extracted" ] && [ -f "$extracted/include/asterisk.h" ]; then
                log_info "Asterisk source ready at /usr/src/$extracted"
                echo "/usr/src/$extracted"
                return 0
            fi
        fi
    done

    log_error "Failed to download Asterisk source"
    return 1
}

# --- Find Asterisk module directory ---
find_ast_moddir() {
    if pgrep -x asterisk > /dev/null; then
        local moddir=$(asterisk -rx "core show settings" 2>/dev/null | grep "Module directory" | awk '{print $NF}')
        [ -n "$moddir" ] && [ -d "$moddir" ] && echo "$moddir" && return 0
    fi
    for dir in /usr/lib64/asterisk/modules /usr/lib/asterisk/modules /usr/local/lib/asterisk/modules; do
        [ -d "$dir" ] && echo "$dir" && return 0
    done
    return 1
}

# --- Build libwebsockets from source (static with -fPIC) ---
build_libwebsockets() {
    local LWS_VERSION="4.3.3"
    local LWS_DIR="/usr/src/libwebsockets-${LWS_VERSION}"

    if [ -f "/usr/local/lib/libwebsockets.a" ]; then
        log_info "libwebsockets static library already built"
        return 0
    fi

    log_info "Downloading libwebsockets ${LWS_VERSION}..."
    cd /usr/src

    [ ! -d "$LWS_DIR" ] && {
        curl -sL "https://github.com/warmcat/libwebsockets/archive/refs/tags/v${LWS_VERSION}.tar.gz" -o lws.tar.gz
        tar xzf lws.tar.gz
        rm -f lws.tar.gz
    }

    cd "$LWS_DIR"
    mkdir -p build && cd build

    log_info "Building libwebsockets (static with -fPIC)..."
    cmake .. -DLWS_WITH_SSL=OFF -DLWS_WITH_STATIC=ON -DLWS_WITH_SHARED=OFF \
             -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON \
             -DLWS_WITHOUT_TEST_PING=ON -DLWS_WITHOUT_TEST_CLIENT=ON \
             -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    make -j$(nproc)
    make install

    echo "/usr/local/lib" > /etc/ld.so.conf.d/libwebsockets.conf
    ldconfig
    log_info "libwebsockets built and installed"
}

# --- Check if static libwebsockets exists ---
check_static_lws() {
    for p in /usr/local/lib /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu; do
        [ -f "$p/libwebsockets.a" ] && return 0
    done
    return 1
}

# --- Install dependencies ---
install_deps() {
    log_info "Checking dependencies..."

    [ -f /etc/os-release ] && . /etc/os-release

    if [ -f /etc/SuSE-release ] || [ "$ID" = "opensuse-leap" ] || [ "$ID" = "opensuse" ] || [[ "$ID_LIKE" == *"suse"* ]]; then
        log_info "openSUSE/SUSE detected"
        if ! zypper lr 2>/dev/null | grep -q "repo-oss\|openSUSE"; then
            zypper ar -f http://download.opensuse.org/distribution/leap/15.5/repo/oss/ repo-oss 2>/dev/null || true
            zypper ar -f http://download.opensuse.org/update/leap/15.5/oss/ repo-update 2>/dev/null || true
            zypper --gpg-auto-import-keys ref
        fi
        for pkg in gcc cmake make curl; do
            command -v $pkg > /dev/null 2>&1 || zypper -n install $pkg
        done
        check_static_lws || build_libwebsockets

    elif [ -f /etc/redhat-release ]; then
        log_info "CentOS/RHEL detected"
        for pkg in gcc cmake curl make; do
            command -v $pkg > /dev/null 2>&1 || yum install -y $pkg
        done
        check_static_lws || build_libwebsockets

    elif [ -f /etc/debian_version ]; then
        log_info "Debian/Ubuntu detected"
        apt-get update -qq
        for pkg in gcc cmake curl make; do
            command -v $pkg > /dev/null 2>&1 || apt-get install -y $pkg
        done
        check_static_lws || build_libwebsockets

    else
        log_warn "Unknown distro, building libwebsockets from source..."
        build_libwebsockets
    fi

    log_info "Dependencies OK"
}

# --- Write embedded source files using heredocs ---
extract_source() {
    BUILD_DIR=$(mktemp -d /tmp/app_amd_ws.XXXXXX)
    log_info "Extracting source to $BUILD_DIR"

    write_source_file > "$BUILD_DIR/app_amd_ws.c"
    write_makefile > "$BUILD_DIR/Makefile"

    if [ ! -s "$BUILD_DIR/app_amd_ws.c" ] || [ ! -s "$BUILD_DIR/Makefile" ]; then
        log_error "Failed to extract embedded source files"
        exit 1
    fi
}

# --- Build ---
build_module() {
    cd "$BUILD_DIR"

    local ast_version
    ast_version=$(get_asterisk_version) || exit 1
    log_info "Asterisk version: $ast_version"

    local ast_src include_path
    ast_src=$(find_ast_headers "$ast_version") || true

    if [ -z "$ast_src" ]; then
        log_warn "Headers not found, downloading..."
        ast_src=$(download_asterisk_source "$ast_version") || exit 1
    fi

    if [ -f "$ast_src/asterisk.h" ]; then
        include_path="$ast_src"
    elif [ -f "$ast_src/include/asterisk.h" ]; then
        include_path="$ast_src/include"
    else
        log_error "asterisk.h not found"
        exit 1
    fi

    log_info "Using headers: $include_path"

    # autoconfig.h is generated by ./configure - run it if missing
    if [ ! -f "$include_path/asterisk/autoconfig.h" ]; then
        log_info "autoconfig.h missing - running ./configure in $ast_src ..."
        ( cd "$ast_src" && ./configure --quiet 2>&1 | tail -3 ) || true
        if [ ! -f "$include_path/asterisk/autoconfig.h" ]; then
            log_error "Failed to generate autoconfig.h - cannot compile"
            exit 1
        fi
    fi

    [ -f "/usr/local/lib/pkgconfig/libwebsockets.pc" ] && \
        export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"

    log_info "Compiling..."
    if ! make STATIC=1 ASTINCDIR="$include_path"; then
        log_error "Compilation failed"
        exit 1
    fi

    [ ! -f "${MODULE_NAME}.so" ] && { log_error "Build failed"; exit 1; }
    log_info "Build successful"
}

# --- Install ---
install_module() {
    local moddir
    moddir=$(find_ast_moddir) || { log_error "Module directory not found"; exit 1; }

    if pgrep -x asterisk > /dev/null; then
        local use_count=$(asterisk -rx "module show like ${MODULE_NAME}" 2>/dev/null | grep "${MODULE_NAME}" | awk '{print $4}')
        if [ -n "$use_count" ] && [ "$use_count" != "0" ]; then
            log_warn "Module has $use_count active sessions, hanging up..."
            for ch in $(asterisk -rx "core show channels verbose" 2>/dev/null | grep AMD_WS | awk '{print $1}'); do
                asterisk -rx "channel request hangup $ch" 2>/dev/null || true
            done
            sleep 3
        fi
        asterisk -rx "module unload ${MODULE_NAME}.so" 2>/dev/null || true
        sleep 1
    fi

    log_info "Installing to ${moddir}/"
    install -m 755 "$BUILD_DIR/${MODULE_NAME}.so" "${moddir}/"

    if pgrep -x asterisk > /dev/null; then
        log_info "Loading module..."
        if asterisk -rx "module load ${MODULE_NAME}.so" 2>&1; then
            log_info "Module loaded"
            asterisk -rx "module show like ${MODULE_NAME}" 2>&1
        else
            log_warn "Module load failed - check Asterisk logs"
        fi
    else
        log_info "Asterisk not running - module will load on next start"
    fi

    echo ""
    log_info "Installation complete!"
    echo ""
    echo "  Usage in dialplan:"
    echo "    exten => s,n,AMD_WS(host,port,vid,timeout_ms)"
    echo ""
    echo "  Example:"
    echo "    exten => s,n,AMD_WS(23.175.49.220,2700,\${CALLERID(name)},10000)"
    echo ""
}

# --- Uninstall ---
uninstall_module() {
    if pgrep -x asterisk > /dev/null; then
        log_info "Unloading module..."
        asterisk -rx "module unload ${MODULE_NAME}.so" 2>/dev/null || true
        sleep 1
    fi

    for dir in /usr/lib64/asterisk/modules /usr/lib/asterisk/modules /usr/local/lib/asterisk/modules; do
        if [ -f "$dir/${MODULE_NAME}.so" ]; then
            log_info "Removing $dir/${MODULE_NAME}.so"
            rm -f "$dir/${MODULE_NAME}.so"
        fi
    done

    log_info "Uninstall complete"
}

# ============================================================================
# Embedded source files (written via heredoc functions)
# ============================================================================

write_source_file() {
cat << 'EMBEDDED_C_EOF'
/*
 * app_amd_ws.c - AMD via WebSocket
 * Sends audio chunks to external AMD server (compatible with amdy.io)
 */

#include "asterisk.h"
#include "asterisk/module.h"
#include "asterisk/channel.h"
#include "asterisk/pbx.h"
#include "asterisk/app.h"
#include "asterisk/format_cache.h"
#include "asterisk/callerid.h"
#include "asterisk/lock.h"

/* Undef Asterisk's pthread type overrides before including libwebsockets */
#undef pthread_mutex_t
#undef pthread_cond_t

#include <libwebsockets.h>

#define SAMPLE_RATE 8000
#define CHUNK_MS 500
#define CHUNK_SAMPLES (SAMPLE_RATE * CHUNK_MS / 1000)  /* 4000 samples */
#define CHUNK_BYTES (CHUNK_SAMPLES * 2)                 /* 8000 bytes */
#define FRAME_MS 20

#define DEFAULT_WS_PORT 8080
#define DEFAULT_TIMEOUT_MS 5000
#define CONNECT_TIMEOUT_MS 2000
#define CONFIG_SEND_TIMEOUT_MS 1000
#define RESULT_WAIT_ITERATIONS 20
#define SERVICE_INTERVAL_MS 50

static const char app[] = "AMD_WS";

/* Track active sessions for safe unload */
static int active_sessions = 0;
static ast_mutex_t session_lock;

struct amd_ws_session {
    struct lws *wsi;
    struct lws_context *context;
    unsigned char audio_buffer[LWS_PRE + CHUNK_BYTES];
    unsigned char config_buffer[LWS_PRE + 512];
    int buffer_pos;
    int config_len;
    int frames_collected;
    char result[256];
    int got_result;
    int connected;
    int config_sent;
};

/* Escape a string for safe JSON embedding. Writes to dst (including NUL).
 * Returns number of chars written (excluding NUL), or -1 if dst_size too small. */
static int json_escape(char *dst, size_t dst_size, const char *src)
{
    size_t pos = 0;
    unsigned char c;

    while ((c = (unsigned char)*src++)) {
        const char *esc;
        char hex[7];
        size_t elen;

        switch (c) {
        case '"':  esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\b': esc = "\\b";  break;
        case '\f': esc = "\\f";  break;
        case '\n': esc = "\\n";  break;
        case '\r': esc = "\\r";  break;
        case '\t': esc = "\\t";  break;
        default:
            if (c < 0x20) {
                snprintf(hex, sizeof(hex), "\\u%04x", c);
                esc = hex;
            } else {
                if (pos + 1 >= dst_size) return -1;
                dst[pos++] = (char)c;
                continue;
            }
        }
        elen = strlen(esc);
        if (pos + elen >= dst_size) return -1;
        memcpy(dst + pos, esc, elen);
        pos += elen;
    }

    dst[pos] = '\0';
    return (int)pos;
}

static int ws_callback(struct lws *wsi, enum lws_callback_reasons reason,
                       void *user, void *in, size_t len)
{
    struct amd_ws_session *session = (struct amd_ws_session *)lws_context_user(lws_get_context(wsi));

    switch (reason) {
    case LWS_CALLBACK_CLIENT_ESTABLISHED:
        session->connected = 1;
        lws_callback_on_writable(wsi);
        break;

    case LWS_CALLBACK_CLIENT_RECEIVE:
        if (len > 0 && len < sizeof(session->result)) {
            memcpy(session->result, in, len);
            session->result[len] = '\0';
            if (strstr(session->result, "HUMAN") ||
                strstr(session->result, "MACHINE") ||
                strstr(session->result, "AMD")) {
                session->got_result = 1;
            }
        }
        break;

    case LWS_CALLBACK_CLIENT_WRITEABLE:
        if (!session->config_sent && session->config_len > 0) {
            lws_write(wsi, &session->config_buffer[LWS_PRE],
                      session->config_len, LWS_WRITE_TEXT);
            session->config_sent = 1;
        } else if (session->buffer_pos > 0) {
            lws_write(wsi, &session->audio_buffer[LWS_PRE],
                      session->buffer_pos, LWS_WRITE_BINARY);
            session->buffer_pos = 0;
        }
        break;

    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
    case LWS_CALLBACK_CLIENT_CLOSED:
        session->connected = 0;
        break;

    default:
        break;
    }
    return 0;
}

static const struct lws_protocols protocols[] = {
    { "amd", ws_callback, 0, CHUNK_BYTES + LWS_PRE },
    { NULL, NULL, 0, 0 }
};

static int amd_ws_exec(struct ast_channel *chan, const char *data)
{
    char *parse;
    struct ast_format *readformat = NULL;
    struct ast_frame *f;
    struct amd_ws_session session = {0};
    struct lws_context_creation_info ctx_info = {0};
    struct lws_client_connect_info conn_info = {0};
    struct timeval start_time;
    int timeout_ms = DEFAULT_TIMEOUT_MS;
    int total_ms;
    int elapsed_ms;
    char ws_host[256] = "127.0.0.1";
    int ws_port = DEFAULT_WS_PORT;
    char vid[256] = "";
    char vid_escaped[512];
    char config_json[512];
    int i;
    int format_changed = 0;

    /* Track session */
    ast_mutex_lock(&session_lock);
    active_sessions++;
    ast_mutex_unlock(&session_lock);

    AST_DECLARE_APP_ARGS(args,
        AST_APP_ARG(host);
        AST_APP_ARG(port);
        AST_APP_ARG(vid);
        AST_APP_ARG(timeout);
    );

    if (!ast_strlen_zero(data)) {
        parse = ast_strdupa(data);
        AST_STANDARD_APP_ARGS(args, parse);

        if (!ast_strlen_zero(args.host))
            ast_copy_string(ws_host, args.host, sizeof(ws_host));
        if (!ast_strlen_zero(args.port)) {
            ws_port = atoi(args.port);
            if (ws_port <= 0 || ws_port > 65535) {
                ast_log(LOG_WARNING, "AMD_WS: Invalid port '%s', using default %d\n",
                        args.port, DEFAULT_WS_PORT);
                ws_port = DEFAULT_WS_PORT;
            }
        }
        if (!ast_strlen_zero(args.vid))
            ast_copy_string(vid, args.vid, sizeof(vid));
        if (!ast_strlen_zero(args.timeout)) {
            timeout_ms = atoi(args.timeout);
            if (timeout_ms <= 0) {
                ast_log(LOG_WARNING, "AMD_WS: Invalid timeout '%s', using default %d\n",
                        args.timeout, DEFAULT_TIMEOUT_MS);
                timeout_ms = DEFAULT_TIMEOUT_MS;
            }
        }
    }

    /* If VID not provided, try to get caller ID name */
    if (ast_strlen_zero(vid)) {
        const char *cid_name;
        ast_channel_lock(chan);
        cid_name = ast_channel_caller(chan)->id.name.str;
        if (!ast_strlen_zero(cid_name)) {
            ast_copy_string(vid, cid_name, sizeof(vid));
        } else {
            ast_copy_string(vid, "Unknown", sizeof(vid));
        }
        ast_channel_unlock(chan);
    }

    ast_verb(3, "AMD_WS: %s host=%s port=%d vid=%s timeout=%d\n",
        ast_channel_name(chan), ws_host, ws_port, vid, timeout_ms);

    /* Build JSON config with escaped VID */
    if (json_escape(vid_escaped, sizeof(vid_escaped), vid) < 0) {
        ast_copy_string(vid_escaped, "Unknown", sizeof(vid_escaped));
    }
    snprintf(config_json, sizeof(config_json),
        "{\"config\":{\"sample_rate\":%d,\"VID\":\"%s\"}}",
        SAMPLE_RATE, vid_escaped);

    session.config_len = strlen(config_json);
    memcpy(&session.config_buffer[LWS_PRE], config_json, session.config_len);

    /* Answer if not already */
    if (ast_channel_state(chan) != AST_STATE_UP) {
        if (ast_answer(chan)) {
            pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
            pbx_builtin_setvar_helper(chan, "AMDCAUSE", "ANSWER_FAILED");
            goto done;
        }
    }

    /* Set read format to slin (16-bit 8kHz) */
    readformat = ao2_bump(ast_channel_readformat(chan));
    if (ast_set_read_format(chan, ast_format_slin)) {
        ast_log(LOG_WARNING, "AMD_WS: Unable to set read format to slin\n");
        ao2_ref(readformat, -1);
        readformat = NULL;
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "FORMAT_FAILED");
        goto done;
    }
    format_changed = 1;

    /* Create WebSocket context */
    ctx_info.port = CONTEXT_PORT_NO_LISTEN;
    ctx_info.protocols = protocols;
    ctx_info.user = &session;
    ctx_info.gid = -1;
    ctx_info.uid = -1;

    /* Suppress libwebsockets logging */
    lws_set_log_level(0, NULL);

    session.context = lws_create_context(&ctx_info);
    if (!session.context) {
        ast_log(LOG_ERROR, "AMD_WS: Failed to create WS context\n");
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONTEXT_FAILED");
        goto cleanup;
    }

    /* Connect to server */
    conn_info.context = session.context;
    conn_info.address = ws_host;
    conn_info.port = ws_port;
    conn_info.path = "/";
    conn_info.host = ws_host;
    conn_info.protocol = "amd";
    conn_info.ssl_connection = 0;

    session.wsi = lws_client_connect_via_info(&conn_info);
    if (!session.wsi) {
        ast_log(LOG_ERROR, "AMD_WS: Failed to connect to %s:%d\n",
                ws_host, ws_port);
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONNECT_FAILED");
        goto cleanup;
    }

    /* Wait for connection */
    total_ms = 0;
    while (!session.connected && total_ms < CONNECT_TIMEOUT_MS) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
        total_ms += SERVICE_INTERVAL_MS;
    }

    if (!session.connected) {
        ast_log(LOG_ERROR, "AMD_WS: Connection timeout to %s:%d\n",
                ws_host, ws_port);
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONNECTION_TIMEOUT");
        goto cleanup;
    }

    ast_verb(3, "AMD_WS: Connected to %s:%d\n", ws_host, ws_port);

    /* Wait for config to be sent */
    total_ms = 0;
    while (!session.config_sent && total_ms < CONFIG_SEND_TIMEOUT_MS) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
        total_ms += SERVICE_INTERVAL_MS;
    }

    /* Main loop - read audio and send chunks */
    session.buffer_pos = 0;
    session.frames_collected = 0;
    start_time = ast_tvnow();

    while (!session.got_result && session.connected) {
        int res;

        elapsed_ms = ast_tvdiff_ms(ast_tvnow(), start_time);
        if (elapsed_ms >= timeout_ms) {
            break;
        }

        res = ast_waitfor(chan, FRAME_MS);
        if (res < 0) {
            break;
        }
        if (res == 0) {
            lws_service(session.context, 0);
            continue;
        }

        f = ast_read(chan);
        if (!f) {
            break;
        }

        if (f->frametype == AST_FRAME_VOICE) {
            int copy_bytes = f->datalen;
            int space = CHUNK_BYTES - session.buffer_pos;

            if (copy_bytes > space) {
                copy_bytes = space;
            }

            memcpy(&session.audio_buffer[LWS_PRE + session.buffer_pos],
                   f->data.ptr, copy_bytes);
            session.buffer_pos += copy_bytes;
            session.frames_collected++;

            if (session.buffer_pos >= CHUNK_BYTES) {
                lws_callback_on_writable(session.wsi);
                lws_service(session.context, 0);
                session.frames_collected = 0;
            }
        }

        ast_frfree(f);
        lws_service(session.context, 0);
    }

    /* Send any remaining audio */
    if (session.buffer_pos > 0 && session.connected) {
        lws_callback_on_writable(session.wsi);
        lws_service(session.context, SERVICE_INTERVAL_MS);
    }

    /* Wait a bit more for result */
    for (i = 0; i < RESULT_WAIT_ITERATIONS && !session.got_result; i++) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
    }

    /* Always capture final elapsed time for logging */
    elapsed_ms = ast_tvdiff_ms(ast_tvnow(), start_time);

    /* Set channel variables */
    {
        const char *status;
        const char *cause;

        if (session.got_result) {
            if (strstr(session.result, "HUMAN")) {
                status = "HUMAN";
            } else if (strstr(session.result, "MACHINE") || strstr(session.result, "AMD")) {
                status = "MACHINE";
            } else {
                status = "NOTSURE";
            }
            cause = session.result;
        } else {
            status = "NOTSURE";
            cause = "TIMEOUT";
        }

        pbx_builtin_setvar_helper(chan, "AMDSTATUS", status);
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", cause);

        ast_verb(3, "AMD_WS: %s status=%s cause=%s elapsed=%dms\n",
            ast_channel_name(chan), status, cause, elapsed_ms);
    }

cleanup:
    if (session.context) {
        lws_context_destroy(session.context);
    }
    if (format_changed && readformat) {
        ast_set_read_format(chan, readformat);
    }
    if (readformat) {
        ao2_ref(readformat, -1);
    }

done:
    ast_mutex_lock(&session_lock);
    active_sessions--;
    ast_mutex_unlock(&session_lock);

    return 0;
}

static int load_module(void)
{
    ast_mutex_init(&session_lock);
    return ast_register_application_xml(app, amd_ws_exec);
}

static int unload_module(void)
{
    int sessions;

    ast_mutex_lock(&session_lock);
    sessions = active_sessions;
    ast_mutex_unlock(&session_lock);

    if (sessions > 0) {
        ast_log(LOG_WARNING, "AMD_WS: Cannot unload - %d active sessions\n", sessions);
        return -1;
    }

    ast_mutex_destroy(&session_lock);
    return ast_unregister_application(app);
}

AST_MODULE_INFO_STANDARD(ASTERISK_GPL_KEY, "AMD via WebSocket");
EMBEDDED_C_EOF
}

write_makefile() {
cat << 'EMBEDDED_MK_EOF'
# Makefile for app_amd_ws - AMD via WebSocket module for Asterisk

STATIC ?= 1

ifeq ($(ASTINCDIR),)
  ifeq ($(ASTTOPDIR),)
    ifneq ($(wildcard /usr/include/asterisk.h),)
      ASTINCDIR = /usr/include
    else
      ASTTOPDIR := $(shell ls -d /usr/src/asterisk-* 2>/dev/null | head -1)
      ifneq ($(ASTTOPDIR),)
        ASTINCDIR = $(ASTTOPDIR)/include
      endif
    endif
  else
    ASTINCDIR = $(ASTTOPDIR)/include
  endif
endif

ifeq ($(ASTINCDIR),)
$(error Cannot find Asterisk headers. Install asterisk-dev or set ASTINCDIR=/path/to/include)
endif

MODULE = app_amd_ws

CC = gcc
CFLAGS = -pthread -O3 -fPIC -std=gnu99
CFLAGS += -I$(ASTINCDIR)
CFLAGS += -DAST_MODULE=\"$(MODULE)\"
CFLAGS += -DAST_MODULE_SELF_SYM=__internal_$(MODULE)_self
CFLAGS += $(shell pkg-config --cflags libwebsockets 2>/dev/null)

LDFLAGS = -pthread -shared

LIBS = $(shell pkg-config --libs libwebsockets)

ifeq ($(STATIC),1)
  LWS_STATIC_LIB := $(firstword $(wildcard \
      /usr/local/lib/libwebsockets.a \
      /usr/lib64/libwebsockets.a \
      /usr/lib/libwebsockets.a \
      /usr/lib/x86_64-linux-gnu/libwebsockets.a))
  ifneq ($(LWS_STATIC_LIB),)
    LIBS = -Wl,--whole-archive $(LWS_STATIC_LIB) -Wl,--no-whole-archive -lm
    $(info Building with STATIC libwebsockets: $(LWS_STATIC_LIB))
  else
    $(warning Static libwebsockets.a not found, falling back to dynamic linking)
  endif
else
  $(info Building with DYNAMIC libwebsockets)
endif

ASTMODDIR ?= $(firstword $(wildcard /usr/lib64/asterisk/modules /usr/lib/asterisk/modules))

all: $(MODULE).so

$(MODULE).o: $(MODULE).c
	@echo "  [CC] $< -> $@"
	$(CC) -o $@ -c $< $(CFLAGS)

$(MODULE).so: $(MODULE).o
	@echo "  [LD] $< -> $@"
	$(CC) -o $@ $(LDFLAGS) $< $(LIBS)

install: $(MODULE).so
	@echo "  [INSTALL] $(MODULE).so -> $(ASTMODDIR)/"
	install -m 755 $(MODULE).so $(ASTMODDIR)/

clean:
	rm -f $(MODULE).o $(MODULE).so

reload:
	@echo "  [RELOAD] $(MODULE)"
	asterisk -rx "module unload $(MODULE).so" 2>/dev/null || true
	asterisk -rx "module load $(MODULE).so"

unload:
	asterisk -rx "module unload $(MODULE).so"

load:
	asterisk -rx "module load $(MODULE).so"

.PHONY: all install clean reload unload load
EMBEDDED_MK_EOF
}

# --- Main ---
main() {
    log_info "=== app_amd_ws installer ==="

    case "${1:-}" in
        --uninstall)
            uninstall_module
            ;;
        --deps-only)
            install_deps
            ;;
        --build-only)
            extract_source
            install_deps
            build_module
            log_info "Module built at $BUILD_DIR/${MODULE_NAME}.so"
            # Don't cleanup BUILD_DIR on --build-only so user can access .so
            BUILD_DIR=""
            ;;
        --help|-h)
            echo "Usage: bash install.sh [--uninstall|--deps-only|--build-only|--help]"
            echo ""
            echo "One-liner install:"
            echo "  curl -sfL https://github.com/nikvb/amd/raw/main/install.sh | sudo bash"
            ;;
        "")
            extract_source
            install_deps
            build_module
            install_module
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
}

if [ "$(id -u)" != "0" ]; then
    log_error "Must run as root"
    exit 1
fi

main "$@"
