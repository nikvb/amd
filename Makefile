# Makefile for app_amd_ws - AMD via WebSocket (res_http_websocket) module for Asterisk >= 16
#
#   make                 build app_amd_ws.so for the Asterisk that is running / installed on this box
#   make show-config     print what was detected (binary, version, buildopt sum, headers, module dir, MySQL)
#   make check           compile-only matrix against every header bundle under $(BUNDLES) (+ the local build)
#   make install         back up the old module (.so.bak.<timestamp>) and install the new one + conf sample
#   make uninstall       remove the module from the Asterisk module directory (backups are kept)
#   make load|unload|reload   via 'asterisk -rx' WITH reply parsing (its exit code is always 0)
#   make installer       regenerate install.sh from the sources (tools/gen-installer.sh)
#   make test            run test/run.sh if present
#   make clean
#
# Detection is done by ./ast-detect.sh (the same file install.sh embeds), so make and the installer
# always agree.  Overrides, all optional, on the command line or in the environment:
#   ASTERISK=/path/asterisk  ASTVERSION=16.30.1-vici  ASTBUILDSUM=<32hex>  ASTMODDIR=/path/modules
#   ASTTOPDIR=/usr/src/asterisk-16.30.1-vici | ASTINCDIR=/path/include   AST_SRC_ROOTS=.. AST_INC_ROOTS=..
#   ASTNOCHECK=1  accept headers whose AST_BUILDOPT_SUM / version cannot be verified (loader may refuse)
#   MYSQL=auto|1|0  MYSQL_CFLAGS=.. MYSQL_LIBS=..   phone/country lookup in vicidial_auto_calls (-DHAVE_MYSQL)
#   WERROR=1        treat warnings as errors (CI)     CFLAGS=.. EXTRA_CPPFLAGS=..   BUNDLES=/path/to/bundles
#
# Every detected value is assigned with ':=' exactly once per make invocation.

SHELL    := /bin/sh
MODULE   := app_amd_ws
MYSQL    ?= auto
ASTNOCHECK ?= 0
BUNDLES  ?= bundles
ASTETCDIR ?= /etc/asterisk
CONF_SAMPLE := amd_ws.conf.sample
DETECT_SH := ./ast-detect.sh

# goals that need neither headers nor a daemon skip detection entirely (instant 'make clean')
NODETECT_GOALS := clean distclean help installer
ifeq ($(filter-out $(NODETECT_GOALS),$(or $(MAKECMDGOALS),all)),)
  DETECT := 0
else
  DETECT := 1
endif
HDR_GOALS := all $(MODULE).so $(MODULE).o check install test

ifeq ($(DETECT),1)
# ---- Asterisk: run the detector once, import its result ------------------------------------
# Overrides are passed explicitly; the detector treats an empty value as "not set".
_det := $(shell ASTERISK='$(ASTERISK)' ASTVERSION='$(ASTVERSION)' ASTBUILDSUM='$(ASTBUILDSUM)' \
                ASTINCDIR='$(ASTINCDIR)' ASTTOPDIR='$(ASTTOPDIR)' ASTMODDIR='$(ASTMODDIR)' \
                AST_SRC_ROOTS='$(AST_SRC_ROOTS)' AST_INC_ROOTS='$(AST_INC_ROOTS)' \
                ASTNOCHECK='$(ASTNOCHECK)' AST_TIMEOUT='$(AST_TIMEOUT)' \
                $(SHELL) $(DETECT_SH) --make > .ast-detect.mk || echo FAIL)
include .ast-detect.mk
# .ast-detect.mk redefines the override variables from what the detector settled on
ifneq ($(AST_DETECT_RC),0)
  ifneq ($(filter $(HDR_GOALS),$(or $(MAKECMDGOALS),all)),)
    $(error no usable Asterisk headers for the running Asterisk - read the [ast-detect] lines above)
  endif
endif
$(info [ast-detect] Asterisk $(or $(ASTVERSION),unknown) via $(ASTVERSION_SRC); binary $(or $(ASTERISK),none) ($(ASTERISK_SRC)); modules $(or $(ASTMODDIR),unknown))
$(info [ast-detect] AST_BUILDOPT_SUM $(or $(ASTBUILDSUM),unknown) via $(ASTBUILDSUM_SRC); headers $(or $(ASTINCDIR),none) ($(ASTINCDIR_SRC)))

# ---- MySQL/MariaDB client: MYSQL=auto|1|0, overridable with MYSQL_CFLAGS/MYSQL_LIBS ----------
ifneq ($(MYSQL),0)
  ifneq ($(strip $(MYSQL_CFLAGS)$(MYSQL_LIBS)),)
    MYSQL_HOW := MYSQL_CFLAGS/MYSQL_LIBS
  else
    MYSQL_PC := $(firstword $(foreach p,libmariadb mariadb mysqlclient,$(if $(shell pkg-config --exists $(p) 2>/dev/null && echo y),$(p))))
    ifneq ($(MYSQL_PC),)
      MYSQL_CFLAGS := $(shell pkg-config --cflags $(MYSQL_PC) 2>/dev/null)
      MYSQL_LIBS   := $(shell pkg-config --libs $(MYSQL_PC) 2>/dev/null)
      MYSQL_HOW    := pkg-config $(MYSQL_PC)
    else
      MYSQL_CONFIG := $(firstword $(shell command -v mariadb_config mysql_config 2>/dev/null))
      ifneq ($(MYSQL_CONFIG),)
        MYSQL_CFLAGS := $(shell $(MYSQL_CONFIG) --cflags 2>/dev/null)
        MYSQL_LIBS   := $(shell $(MYSQL_CONFIG) --libs 2>/dev/null)
        MYSQL_HOW    := $(MYSQL_CONFIG)
      endif
    endif
  endif
  ifeq ($(strip $(MYSQL_LIBS)),)
    ifeq ($(MYSQL),1)
      $(error MYSQL=1 but no MySQL/MariaDB client development files found (pkg-config libmariadb/mariadb/mysqlclient, mariadb_config or mysql_config). Install libmariadb-devel / mariadb-connector-c-devel / libmariadb-dev, or pass MYSQL_CFLAGS= MYSQL_LIBS=)
    endif
    HAVE_MYSQL := 0
    $(info [ast-detect] MySQL: no (client development files not found; phone/country lookup disabled))
  else
    HAVE_MYSQL := 1
    $(info [ast-detect] MySQL: yes ($(MYSQL_HOW)) -> $(MYSQL_LIBS))
  endif
else
  HAVE_MYSQL := 0
  MYSQL_CFLAGS :=
  MYSQL_LIBS :=
  $(info [ast-detect] MySQL: no (MYSQL=0))
endif
endif  # DETECT

# ---- flags ----------------------------------------------------------------------------------
CC       := $(if $(filter default undefined,$(origin CC)),gcc,$(CC))
CFLAGS   ?= -O2 -g
# -MD (not -MMD): the .d must list system headers too, so the provenance gate below can see an
# accidental fall-through to /usr/include/asterisk/*.h
override CFLAGS += -pthread -fPIC -std=gnu99 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wformat=2 -Wshadow -MD -MP
ifeq ($(WERROR),1)
  override CFLAGS += -Werror
endif
# Asterisk headers as system headers (-isystem) so -Wextra does not report Asterisk's own header
# style (e.g. 'inline not at beginning of declaration' in strings.h); /usr/include and
# /usr/local/include stay -I because -isystem would reorder the compiler's own include chain
AST_INC_FLAG = $(if $(filter /usr/include /usr/local/include,$(1)),-I$(1),-isystem $(1))
CPPFLAGS += $(call AST_INC_FLAG,$(ASTINCDIR)) -DAST_MODULE=\"$(MODULE)\" -DAST_MODULE_SELF_SYM=__internal_$(MODULE)_self
ifeq ($(HAVE_MYSQL),1)
  CPPFLAGS += -DHAVE_MYSQL $(MYSQL_CFLAGS)
endif
CPPFLAGS += $(EXTRA_CPPFLAGS)
LDFLAGS  += -pthread -shared
# LIBS is composed from independent parts; nothing ever re-assigns it
LIBS      = $(if $(filter 1,$(HAVE_MYSQL)),$(MYSQL_LIBS)) $(EXTRA_LIBS)

# symbols an Asterisk module may leave undefined: provided by the core at dlopen (ast_*, ao2, pbx_*,
# plus the two option_* globals the ast_debug()/ast_verb() macros read; stock app_amd.so has the same)
# or by res_http_websocket.so (ast_websocket_*, a required module that exports global symbols).
# The pattern is only the fallback: when the core binary is readable, its 'nm -D' export list decides.
CORE_SYM_RE := ^(ast_|__ast_|ao2_|__ao2_|pbx_|ast_websocket_|option_debug$$|option_verbose$$)

# stamp with everything that influences the object: a change of headers/version/sum/flags rebuilds
BUILDFLAGS := $(ASTVERSION) $(ASTINCDIR) $(ASTBUILDSUM) $(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) $(LIBS)

.PHONY: all check install uninstall clean distclean show-config installer test load unload reload help FORCE

all: $(MODULE).so

.buildflags: FORCE
	@echo '$(BUILDFLAGS)' | cmp -s - $@ 2>/dev/null || echo '$(BUILDFLAGS)' > $@

$(MODULE).o: $(MODULE).c .buildflags
	@echo "  [CC] $< -> $@   (Asterisk $(ASTVERSION), headers $(ASTINCDIR))"
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<
	@# gate 1: every Asterisk header actually used must come from ASTINCDIR (no silent /usr/include mix)
	@bad=$$(tr ' \\' '\n\n' < $(MODULE).d | grep -E '/asterisk(\.h|/[^/]*\.h)$$' | grep -v "^$(ASTINCDIR)/" | sort -u); \
	 if [ -n "$$bad" ]; then echo "ERROR: Asterisk headers pulled from outside $(ASTINCDIR):"; echo "$$bad" | sed 's/^/    /'; rm -f $@; exit 1; fi
	@# gate 2: the object embeds the core's AST_BUILDOPT_SUM (the loader compares it)
	@if [ -n '$(ASTBUILDSUM)' ]; then strings -a $@ | grep -qx '$(ASTBUILDSUM)' || { echo "ERROR: $@ does not embed AST_BUILDOPT_SUM $(ASTBUILDSUM)"; rm -f $@; exit 1; }; fi

$(MODULE).so: $(MODULE).o
	@echo "  [LD] $< -> $@"
	$(CC) $(LDFLAGS) -o $@ $< $(LIBS)
	@# post-link gate 3: every symbol still undefined must be one the core (or res_http_websocket) provides
	@und=$$(ldd -r $@ 2>&1 | awk '/undefined symbol/{sub(/[[:space:]]*\(.*/,"",$$3); print $$3}' | sort -u); \
	 if [ -n '$(ASTERISK)' ] && [ -r '$(ASTERISK)' ] && nm -D --defined-only '$(ASTERISK)' >/dev/null 2>&1; then \
	   core=$$(nm -D --defined-only '$(ASTERISK)' | awk '{print $$NF}' | sed 's/@.*//' | sort -u); \
	   missing=$$(printf '%s\n' "$$und" | grep -v '^ast_websocket_' | grep -vxF "$$core"); \
	 else \
	   echo "  [..] no readable core binary - symbol check limited to the name pattern"; \
	   missing=$$(printf '%s\n' "$$und" | grep -v -E '$(CORE_SYM_RE)'); \
	 fi; \
	 missing=$$(printf '%s\n' "$$missing" | grep -v '^$$' || true); \
	 if [ -n "$$missing" ]; then echo "ERROR: $@ needs symbols that neither its libraries nor Asterisk provide (dlopen would fail):"; echo "$$missing" | sed 's/^/    /'; rm -f $@; exit 1; fi; \
	 echo "  [OK] undefined symbols of $@ are all provided by Asterisk$(if $(filter 1,$(HAVE_MYSQL)), or the MySQL client library)"
	@# post-link gate 4: the .so embeds the core's sum
	@if [ -n '$(ASTBUILDSUM)' ]; then strings -a $@ | grep -qx '$(ASTBUILDSUM)' && echo "  [OK] $@ embeds AST_BUILDOPT_SUM $(ASTBUILDSUM)" || { echo "ERROR: $@ does not embed AST_BUILDOPT_SUM $(ASTBUILDSUM)"; rm -f $@; exit 1; }; \
	 else echo "  [..] core AST_BUILDOPT_SUM unknown - not verified"; fi

# ---- check: compile-only matrix against header bundles (tools/make-header-bundle.sh output) ----
# Bundles are directories $(BUNDLES)/asterisk-<ver>/include (tarballs asterisk-<ver>-headers.tar.gz
# found there are extracted first).  Bundles ship no buildopts.h: one is synthesised for the core's
# sum (or the stock OPTIONAL_API sum when unknown), exactly as install.sh does on a customer box.
CHECK_SUM := $(or $(ASTBUILDSUM),da6642af068ee5e6490c5b1d2cc1d238)
CHECK_CPPFLAGS := $(filter-out -I$(ASTINCDIR) -isystem $(ASTINCDIR),$(CPPFLAGS))
check: all
	@set -e; found=0; \
	 for tb in $(BUNDLES)/asterisk-*-headers.tar.gz; do \
	   [ -f "$$tb" ] || continue; d=$${tb%-headers.tar.gz}; \
	   [ -f "$$d/include/asterisk.h" ] || { echo "  [check] extracting $$tb"; mkdir -p "$$d"; tar xzf "$$tb" -C "$$d" --strip-components=1; }; \
	 done; \
	 for inc in $(BUNDLES)/asterisk-*/include; do \
	   [ -f "$$inc/asterisk.h" ] || continue; found=$$((found+1)); tree=$${inc%/include}; name=$${tree##*/}; \
	   [ -f "$$inc/asterisk/buildopts.h" ] || { . $(DETECT_SH); ast_synth_buildopts "$$inc" '$(CHECK_SUM)'; }; \
	   printf '  [check] %-28s ' "$$name"; \
	   $(CC) $(CHECK_CPPFLAGS) -isystem "$$inc" $(CFLAGS) -c -o "$$tree/$(MODULE).o" $(MODULE).c || { echo "FAILED (compile)"; exit 1; }; \
	   bad=$$(tr ' \\' '\n\n' < "$$tree/$(MODULE).d" | grep -E '/asterisk(\.h|/[^/]*\.h)$$' | grep -v "^$$inc/" | sort -u); \
	   [ -z "$$bad" ] || { echo "FAILED (headers from outside the bundle: $$bad)"; exit 1; }; \
	   echo "OK ($$(sed -n 1p "$$tree/.version" 2>/dev/null || echo 'no .version'))"; \
	 done; \
	 if [ $$found -eq 0 ]; then echo "  [check] no header bundles under $(BUNDLES) (see tools/make-header-bundle.sh) - only the local build was checked"; fi

# ---- install / uninstall -------------------------------------------------------------------
install: $(MODULE).so
	@[ -n "$(ASTMODDIR)" ] && [ -d "$(DESTDIR)$(ASTMODDIR)" ] || { echo "ERROR: Asterisk module directory not found - pass ASTMODDIR=/path/to/modules"; exit 1; }
	@if [ -f "$(DESTDIR)$(ASTMODDIR)/$(MODULE).so" ]; then \
	   b="$(DESTDIR)$(ASTMODDIR)/$(MODULE).so.bak.$$(date +%Y%m%d%H%M%S)"; cp -p "$(DESTDIR)$(ASTMODDIR)/$(MODULE).so" "$$b"; echo "  [BACKUP] $$b"; fi
	install -m 755 $(MODULE).so "$(DESTDIR)$(ASTMODDIR)/.$(MODULE).so.new"
	mv -f "$(DESTDIR)$(ASTMODDIR)/.$(MODULE).so.new" "$(DESTDIR)$(ASTMODDIR)/$(MODULE).so"
	@echo "  [INSTALL] $(DESTDIR)$(ASTMODDIR)/$(MODULE).so"
	@if [ -f $(CONF_SAMPLE) ] && [ -d "$(DESTDIR)$(ASTETCDIR)" ]; then install -m 644 $(CONF_SAMPLE) "$(DESTDIR)$(ASTETCDIR)/$(CONF_SAMPLE)"; echo "  [INSTALL] $(DESTDIR)$(ASTETCDIR)/$(CONF_SAMPLE)"; fi
	@echo "  next: make reload   (or: asterisk -rx 'module load $(MODULE).so')"

uninstall:
	@[ -n "$(ASTMODDIR)" ] || { echo "ERROR: Asterisk module directory not found - pass ASTMODDIR=/path/to/modules"; exit 1; }
	rm -f "$(DESTDIR)$(ASTMODDIR)/$(MODULE).so"
	@echo "  [REMOVED] $(DESTDIR)$(ASTMODDIR)/$(MODULE).so (backups $(MODULE).so.bak.* kept, amd_ws.conf kept)"

# ---- load / unload / reload: 'asterisk -rx' exits 0 whatever happened, so parse the reply ------
define ast_rx
$(SHELL) -c 'timeout $(or $(AST_TIMEOUT),5) "$(ASTERISK)" $(ASTERISK_OPTS) -rx "$(1)" 2>&1'
endef
ast_status = $(SHELL) -c '$(call ast_rx,module show like $(MODULE)) | awk -v m="$(MODULE).so" '"'"'$$1==m'"'"

load:
	@[ -n "$(ASTERISK)" ] || { echo "ERROR: no asterisk binary"; exit 1; }
	@out=$$($(call ast_rx,module load $(MODULE).so)); echo "  $$out"; \
	 case "$$out" in "Loaded "*) ;; *) echo "ERROR: module load failed (check /var/log/asterisk/messages)"; exit 1;; esac
	@$(ast_status) | grep -q ' Running ' && echo "  [OK] $(MODULE).so is Running" || { echo "ERROR: $(MODULE).so not Running"; exit 1; }

unload:
	@[ -n "$(ASTERISK)" ] || { echo "ERROR: no asterisk binary"; exit 1; }
	@out=$$($(call ast_rx,module unload $(MODULE).so)); echo "  $$out"; \
	 case "$$out" in "Unloaded "*) ;; *) echo "ERROR: module unload refused (module in use by a call? try again when idle)"; exit 1;; esac

reload: unload load

# ---- misc ---------------------------------------------------------------------------------
show-config:
	@echo "ASTERISK=$(ASTERISK)"; echo "ASTVERSION=$(ASTVERSION)"; echo "ASTVERBASE=$(ASTVERBASE)"; echo "ASTMAJOR=$(ASTMAJOR)"
	@echo "ASTBUILDSUM=$(ASTBUILDSUM)"; echo "ASTINCDIR=$(ASTINCDIR)"; echo "ASTMODDIR=$(ASTMODDIR)"
	@echo "MySQL: $(if $(filter 1,$(HAVE_MYSQL)),yes ($(MYSQL_HOW)),no)"
	@echo "CC=$(CC)"; echo "CFLAGS=$(CFLAGS)"; echo "CPPFLAGS=$(CPPFLAGS)"; echo "LIBS=$(LIBS)"

installer:
	$(SHELL) tools/gen-installer.sh -o install.sh

test:
	@if [ -x test/run.sh ]; then test/run.sh; else echo "no test/run.sh in this checkout"; fi

clean:
	rm -f $(MODULE).o $(MODULE).so $(MODULE).d .buildflags .ast-detect.mk

distclean: clean
	rm -rf bundles/asterisk-*/$(MODULE).o bundles/asterisk-*/$(MODULE).d

help:
	@sed -n '2,22p' Makefile

-include $(MODULE).d
FORCE:
