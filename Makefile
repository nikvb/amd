# Makefile for app_amd_ws - AMD via WebSocket module for Asterisk
#
# Usage:
#   make                    - Build the module
#   make install            - Install to Asterisk modules directory
#   make clean              - Remove build artifacts
#   make reload             - Reload module in Asterisk

# Auto-detect Asterisk include directory
# Priority: ASTINCDIR > ASTTOPDIR/include > system headers > source tree
ifeq ($(ASTINCDIR),)
  ifeq ($(ASTTOPDIR),)
    # Check for system headers first (asterisk-dev package)
    ifneq ($(wildcard /usr/include/asterisk.h),)
      ASTINCDIR = /usr/include
    else
      # Try to find source tree
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

# Module name
MODULE = app_amd_ws

# Compiler settings
CC = gcc
CFLAGS = -pthread -O3 -fPIC -std=gnu99
CFLAGS += -I$(ASTINCDIR)
CFLAGS += -DAST_MODULE=\"$(MODULE)\"
CFLAGS += -DAST_MODULE_SELF_SYM=__internal_$(MODULE)_self
CFLAGS += $(shell pkg-config --cflags libwebsockets 2>/dev/null)

LDFLAGS = -pthread -shared
LIBS = $(shell pkg-config --libs libwebsockets)

# Asterisk module directory
ASTMODDIR ?= $(shell if [ -d /usr/lib64/asterisk/modules ]; then echo /usr/lib64/asterisk/modules; else echo /usr/lib/asterisk/modules; fi)

# Targets
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
