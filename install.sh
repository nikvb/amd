#!/bin/bash
#
# app_amd_ws Installation Script
# AMD (Answering Machine Detection) via WebSocket for Asterisk
#
# Usage: ./install.sh [--uninstall]
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

MODULE_NAME="app_amd_ws"
INSTALL_DIR="/usr/src/app_amd_ws"

# Setup working directory
setup_workdir() {
    if [ "$(pwd)" != "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
        cp -f app_amd_ws.c Makefile "$INSTALL_DIR/" 2>/dev/null || true
        cd "$INSTALL_DIR"
        log_info "Working directory: $INSTALL_DIR"
    fi
}

# Find Asterisk module directory
find_ast_moddir() {
    # Try to get from running Asterisk first
    if pgrep -x asterisk > /dev/null; then
        local moddir=$(asterisk -rx "core show settings" 2>/dev/null | grep "Module directory" | awk '{print $NF}')
        if [ -n "$moddir" ] && [ -d "$moddir" ]; then
            echo "$moddir"
            return 0
        fi
    fi
    # Check common locations
    for dir in /usr/lib64/asterisk/modules /usr/lib/asterisk/modules /usr/local/lib/asterisk/modules; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Check if Asterisk is running
check_asterisk() {
    if pgrep -x asterisk > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Build libwebsockets from source
build_libwebsockets() {
    local LWS_VERSION="4.3.3"
    local LWS_DIR="/usr/src/libwebsockets-${LWS_VERSION}"

    if [ -d "$LWS_DIR" ] && [ -f "/usr/local/lib/libwebsockets.so" ]; then
        log_info "libwebsockets already built"
        return 0
    fi

    log_info "Downloading libwebsockets ${LWS_VERSION}..."
    cd /usr/src

    if [ ! -d "$LWS_DIR" ]; then
        curl -sL "https://github.com/warmcat/libwebsockets/archive/refs/tags/v${LWS_VERSION}.tar.gz" -o lws.tar.gz
        tar xzf lws.tar.gz
        rm -f lws.tar.gz
    fi

    cd "$LWS_DIR"
    mkdir -p build && cd build

    log_info "Building libwebsockets..."
    cmake .. -DLWS_WITH_SSL=OFF -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON \
             -DLWS_WITHOUT_TEST_PING=ON -DLWS_WITHOUT_TEST_CLIENT=ON -DCMAKE_INSTALL_PREFIX=/usr/local
    make -j$(nproc)
    make install

    # Update library cache
    echo "/usr/local/lib" > /etc/ld.so.conf.d/libwebsockets.conf
    ldconfig

    # Make pkg-config find it
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"

    log_info "libwebsockets built and installed"
    cd "$INSTALL_DIR"
}

# Install dependencies
install_deps() {
    log_info "Installing dependencies..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
    fi

    if [ -f /etc/SuSE-release ] || [ "$ID" = "opensuse-leap" ] || [ "$ID" = "opensuse" ] || [ "$ID_LIKE" = *"suse"* ]; then
        # openSUSE / SUSE / ViciBox
        log_info "openSUSE/SUSE detected"

        # Check if repos are configured, add if missing
        if ! zypper lr 2>/dev/null | grep -q "repo-oss\|openSUSE"; then
            log_warn "No repositories configured, adding openSUSE Leap 15.5 repos..."
            zypper ar -f http://download.opensuse.org/distribution/leap/15.5/repo/oss/ repo-oss 2>/dev/null || true
            zypper ar -f http://download.opensuse.org/update/leap/15.5/oss/ repo-update 2>/dev/null || true
            zypper --gpg-auto-import-keys ref
        fi

        # Make sure gcc, cmake, git are installed
        for pkg in gcc cmake git make; do
            if ! which $pkg > /dev/null 2>&1; then
                log_info "Installing $pkg..."
                zypper -n install $pkg
            fi
        done

        # Check if libwebsockets is already available
        if pkg-config --exists libwebsockets 2>/dev/null; then
            log_info "libwebsockets already available"
        elif rpm -q libwebsockets-devel > /dev/null 2>&1; then
            log_info "libwebsockets-devel already installed"
        else
            # Try zypper first
            log_info "Trying to install libwebsockets-devel via zypper..."
            if ! zypper -n install libwebsockets-devel 2>/dev/null; then
                log_warn "Package not available, building libwebsockets from source..."
                build_libwebsockets
            fi
        fi
    elif [ -f /etc/redhat-release ]; then
        # CentOS/RHEL
        log_info "CentOS/RHEL detected"
        if rpm -q libwebsockets-devel > /dev/null 2>&1; then
            log_info "libwebsockets-devel already installed"
        else
            log_info "Installing libwebsockets-devel..."
            yum install -y epel-release 2>/dev/null || true
            yum install -y libwebsockets-devel
        fi
        # Make sure gcc is installed
        if ! which gcc > /dev/null 2>&1; then
            yum install -y gcc
        fi
    elif [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        log_info "Debian/Ubuntu detected"
        apt-get update -qq

        # Install asterisk-dev for headers
        if ! dpkg -l asterisk-dev 2>/dev/null | grep -q ^ii; then
            log_info "Installing asterisk-dev..."
            apt-get install -y asterisk-dev
        else
            log_info "asterisk-dev already installed"
        fi

        # Install libwebsockets-dev
        if ! dpkg -l libwebsockets-dev 2>/dev/null | grep -q ^ii; then
            log_info "Installing libwebsockets-dev..."
            apt-get install -y libwebsockets-dev
        else
            log_info "libwebsockets-dev already installed"
        fi

        # Make sure gcc and curl are installed
        if ! which gcc > /dev/null 2>&1; then
            apt-get install -y gcc
        fi
        if ! which curl > /dev/null 2>&1; then
            apt-get install -y curl
        fi
    else
        log_warn "Unknown distribution. Please install libwebsockets-devel/libwebsockets-dev manually."
    fi
}

# Download Asterisk source if needed
download_asterisk_source() {
    local AST_VERSION="16.30.1"
    local AST_DIR="/usr/src/asterisk-${AST_VERSION}"
    # Try vicidial first, then official Asterisk downloads
    local AST_URLS="https://download.vicidial.com/required-apps/asterisk-${AST_VERSION}-vici.tar.gz https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-${AST_VERSION}.tar.gz"

    # Check if already exists
    if [ -d "$AST_DIR" ] && [ -f "$AST_DIR/include/asterisk.h" ]; then
        log_info "Asterisk source already exists at $AST_DIR"
        echo "$AST_DIR"
        return 0
    fi

    # Also check for -vici variant
    if [ -d "${AST_DIR}-vici" ] && [ -f "${AST_DIR}-vici/include/asterisk.h" ]; then
        log_info "Asterisk source already exists at ${AST_DIR}-vici"
        echo "${AST_DIR}-vici"
        return 0
    fi

    cd /usr/src
    local downloaded=0

    for url in $AST_URLS; do
        log_info "Trying: $url"
        if curl -sfL "$url" -o "asterisk-download.tar.gz"; then
            log_info "Downloaded successfully"
            downloaded=1
            break
        fi
        log_warn "Failed, trying next..."
    done

    if [ $downloaded -eq 0 ]; then
        log_error "Failed to download Asterisk source from any mirror"
        return 1
    fi

    log_info "Extracting Asterisk source..."
    tar xzf "asterisk-download.tar.gz"
    rm -f "asterisk-download.tar.gz"

    # Find extracted directory (could be asterisk-X.X.X or asterisk-X.X.X-vici)
    local extracted_dir=$(ls -d asterisk-${AST_VERSION}* 2>/dev/null | head -1)
    if [ -z "$extracted_dir" ] || [ ! -f "$extracted_dir/include/asterisk.h" ]; then
        log_error "Asterisk source extraction failed"
        return 1
    fi

    log_info "Asterisk source ready at /usr/src/$extracted_dir"
    cd "$INSTALL_DIR"
    echo "/usr/src/$extracted_dir"
    return 0
}

# Find Asterisk headers
find_ast_headers() {
    # First check for asterisk-dev system headers (Debian/Ubuntu)
    if [ -f "/usr/include/asterisk.h" ]; then
        echo "/usr"
        return 0
    fi
    # Then check for source tree
    for src in /usr/src/asterisk-* /home/*/asterisk-*; do
        if [ -d "$src" ] && [ -f "$src/include/asterisk.h" ]; then
            echo "$src"
            return 0
        fi
    done
    return 1
}

# Build the module
build_module() {
    log_info "Building ${MODULE_NAME}..."

    # Make sure we're in the right directory
    cd "$INSTALL_DIR"

    # Set PKG_CONFIG_PATH for locally built libwebsockets
    if [ -f "/usr/local/lib/pkgconfig/libwebsockets.pc" ]; then
        export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
        log_info "Using libwebsockets from /usr/local"
    fi

    # Check for Asterisk headers
    log_info "Looking for Asterisk headers..."
    AST_HEADERS=$(find_ast_headers)

    if [ -z "$AST_HEADERS" ]; then
        log_warn "Asterisk headers not found, downloading source..."
        AST_SRC=$(download_asterisk_source)
        if [ -z "$AST_SRC" ]; then
            log_error "Failed to get Asterisk headers"
            exit 1
        fi
        AST_HEADERS="$AST_SRC"
    fi

    if [ "$AST_HEADERS" = "/usr" ]; then
        log_info "Using system Asterisk headers from asterisk-dev package"
        INCLUDE_PATH="/usr/include"
    else
        log_info "Using Asterisk source: $AST_HEADERS"
        INCLUDE_PATH="$AST_HEADERS/include"
    fi

    # Verify headers exist
    if [ ! -f "$INCLUDE_PATH/asterisk.h" ]; then
        log_error "asterisk.h not found at $INCLUDE_PATH"
        exit 1
    fi
    log_info "Found asterisk.h at $INCLUDE_PATH"

    # Make sure we're back in install dir
    cd "$INSTALL_DIR"

    # Check source file exists
    if [ ! -f "app_amd_ws.c" ]; then
        log_error "app_amd_ws.c not found in $INSTALL_DIR"
        exit 1
    fi

    # Build with make
    log_info "Compiling module..."
    make clean 2>/dev/null || true

    if ! make ASTINCDIR="$INCLUDE_PATH"; then
        log_error "Compilation failed"
        exit 1
    fi

    if [ ! -f "${MODULE_NAME}.so" ]; then
        log_error "Build failed - ${MODULE_NAME}.so not created"
        exit 1
    fi

    log_info "Build successful: ${MODULE_NAME}.so"
}

# Install the module
install_module() {
    MODDIR=$(find_ast_moddir)
    if [ -z "$MODDIR" ]; then
        log_error "Asterisk module directory not found"
        exit 1
    fi

    log_info "Installing ${MODULE_NAME}.so to ${MODDIR}/"
    install -m 755 ${MODULE_NAME}.so ${MODDIR}/

    # Reload module if Asterisk is running
    if check_asterisk; then
        log_info "Reloading module in Asterisk..."
        asterisk -rx "module unload ${MODULE_NAME}.so" 2>/dev/null || true
        sleep 1
        if asterisk -rx "module load ${MODULE_NAME}.so"; then
            log_info "Module loaded successfully"
        else
            log_warn "Module load failed - check Asterisk logs"
        fi
    else
        log_info "Asterisk not running - module will be loaded on next start"
    fi

    log_info "Installation complete!"
    echo ""
    log_info "Usage in dialplan:"
    echo "  exten => s,n,Set(VID=\${CALLERID(name)})"
    echo "  exten => s,n,AMD_WS(api.amdy.io,2700,\${VID},5000)"
    echo "  exten => s,n,GotoIf(\$[\"\${AMDSTATUS}\"=\"MACHINE\"]?machine:human)"
    echo ""
    log_info "Parameters: AMD_WS(host,port,vid,timeout_ms)"
}

# Uninstall the module
uninstall_module() {
    MODDIR=$(find_ast_moddir)
    if [ -z "$MODDIR" ]; then
        log_error "Asterisk module directory not found"
        exit 1
    fi

    # Unload if Asterisk is running
    if check_asterisk; then
        log_info "Unloading module from Asterisk..."
        asterisk -rx "module unload ${MODULE_NAME}.so" 2>/dev/null || true
        sleep 1
    fi

    if [ -f "${MODDIR}/${MODULE_NAME}.so" ]; then
        log_info "Removing ${MODDIR}/${MODULE_NAME}.so"
        rm -f "${MODDIR}/${MODULE_NAME}.so"
        log_info "Module uninstalled"
    else
        log_warn "Module not found at ${MODDIR}/${MODULE_NAME}.so"
    fi
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --uninstall    Remove the module"
    echo "  --deps-only    Only install dependencies"
    echo "  --build-only   Only build (don't install)"
    echo "  --help         Show this help"
    echo ""
    echo "Environment variables:"
    echo "  ASTTOPDIR      Path to Asterisk source (auto-detected if not set)"
}

# Main
main() {
    # Setup working directory first
    setup_workdir

    case "${1:-}" in
        --uninstall)
            uninstall_module
            ;;
        --deps-only)
            install_deps
            ;;
        --build-only)
            install_deps
            build_module
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        "")
            install_deps
            build_module
            install_module
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

# Must run as root
if [ "$(id -u)" != "0" ]; then
    log_error "This script must be run as root"
    exit 1
fi

main "$@"
