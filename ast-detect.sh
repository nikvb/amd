#!/bin/sh
# ast-detect.sh - find the Asterisk that is RUNNING (else installed) on this box and a header
# tree that matches it.  Shared by the Makefile and by install.sh (embedded verbatim), so both
# always take the same decision.
#
# POSIX sh (tested with dash and bash).  Every diagnostic goes to STDERR, so callers can use
# $(...) safely; nothing but the requested output ever appears on stdout.
#
# Usage as a library:
#     . ./ast-detect.sh; ast_detect || exit 1
#     make ASTERISK="$ASTERISK" ASTVERSION="$ASTVERSION" ASTBUILDSUM="$ASTBUILDSUM" ASTINCDIR="$ASTINCDIR" ...
# Usage standalone:
#     sh ast-detect.sh            -> KEY=VALUE lines (shell syntax) on stdout, rc 0 = usable headers found
#     sh ast-detect.sh --make     -> KEY := VALUE lines (GNU make syntax) on stdout, rc 0 = usable headers found
#     sh ast-detect.sh --running  -> rc 0 if an Asterisk daemon answers 'core show version' within AST_TIMEOUT
#
# Overrides (environment, or on the make command line):
#     ASTERISK=/path/to/asterisk        the binary to fingerprint (default: the running daemon's image)
#     ASTVERSION=16.30.1-vici           skip version detection
#     ASTBUILDSUM=<32 hex>              skip AST_BUILDOPT_SUM detection
#     ASTINCDIR=/path/include           use exactly this include dir (still validated unless ASTNOCHECK=1)
#     ASTTOPDIR=/path/asterisk-<ver>    use <ASTTOPDIR>/include (same rules)
#     ASTMODDIR=/path/modules           skip module-directory detection
#     AST_SRC_ROOTS="/usr/src ..."      where versioned source trees are searched
#     AST_INC_ROOTS="/usr/include ..."  where installed headers are searched
#     ASTNOCHECK=1                      downgrade a buildopt-sum mismatch / unverifiable headers to a WARNING
#     AST_TIMEOUT=5                     seconds allowed for every 'asterisk -rx' / 'asterisk -V' call
#
# Why all this: an out-of-tree module needs only headers, but they must belong to the same
# Asterisk version as the running core AND carry the same AST_BUILDOPT_SUM (main/loader.c refuses
# the module otherwise).  /usr/include, a distro -dev package and stray trees in /usr/src may all
# be from a different Asterisk than the one that is running, so every candidate is validated.

LC_ALL=C; export LC_ALL

AST_TIMEOUT=${AST_TIMEOUT:-5}
AST_SRC_ROOTS=${AST_SRC_ROOTS:-"/usr/src /usr/src/asterisk /usr/local/src /usr/local/src/asterisk"}
AST_INC_ROOTS=${AST_INC_ROOTS:-"/usr/include /usr/local/include"}
ASTNOCHECK=${ASTNOCHECK:-0}

ad_log()  { printf '[ast-detect] %s\n' "$*" >&2; }
ad_warn() { printf '[ast-detect] WARNING: %s\n' "$*" >&2; }
ad_err()  { printf '[ast-detect] ERROR: %s\n' "$*" >&2; }
ad_run()  { timeout "$AST_TIMEOUT" "$@" 2>/dev/null; }     # never hang on a broken/deadlocked binary

# ---------------------------------------------------------------------------------------------
# 1. binary: image of the running daemon (skipping 'asterisk -r' consoles) -> PATH -> well-known
# ---------------------------------------------------------------------------------------------
ast_daemon_pid() {
    # prints the PID of the daemon (not of a remote console), or nothing
    for p in $(pgrep -x asterisk 2>/dev/null); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- ' -r' && continue
        printf '%s\n' "$p"; return 0
    done
    return 1
}

ast_find_binary() {
    [ -n "${ASTERISK:-}" ] && { ASTERISK_SRC=override; return 0; }
    ASTERISK=''; ASTERISK_SRC=''
    p=$(ast_daemon_pid) || p=''
    if [ -n "$p" ]; then
        ASTERISK=$(readlink "/proc/$p/exe" 2>/dev/null | sed 's/ (deleted)$//')
        [ -n "$ASTERISK" ] && ASTERISK_SRC="running process $p"
    fi
    [ -z "$ASTERISK" ] && { ASTERISK=$(command -v asterisk 2>/dev/null); ASTERISK_SRC=PATH; }
    if [ -z "$ASTERISK" ]; then
        for b in /usr/sbin/asterisk /usr/local/sbin/asterisk; do
            [ -x "$b" ] && { ASTERISK=$b; ASTERISK_SRC="well-known path"; break; }
        done
    fi
    [ -n "$ASTERISK" ] || ASTERISK_SRC="none found"
    [ -n "$ASTERISK" ]
}

# rc 0 when a daemon answers the CLI (the only reliable definition of "running")
ast_running() {
    [ -n "${ASTERISK:-}" ] || ast_find_binary || return 1
    ad_run "$ASTERISK" -rx 'core show version' | grep -q '^Asterisk '
}

# ---------------------------------------------------------------------------------------------
# 2. version: 'core show version' -> 'asterisk -V' -> embedded string pair ("16.30.1-vici" + "163001")
# ---------------------------------------------------------------------------------------------
ast_version_filter() { sed -n 's/^Asterisk \([^ ][^ ]*\).*/\1/p' | head -n 1; }

# main/version.c stores the version string and its numeric form next to each other; requiring both
# avoids false hits like "10.0" from unrelated strings.
ast_version_from_strings() {
    strings -a "$1" 2>/dev/null | awk '
        /^[0-9][0-9]*\.[0-9][0-9]*(\.[0-9][0-9]*)?(-[A-Za-z0-9.]+)?$/ || /^certified\/[0-9][0-9]*\.[0-9][0-9]*(-cert[0-9]+)?$/ { v[$0]=1 }
        /^[0-9][0-9][0-9][0-9][0-9][0-9]?$/ { n[$0]=1 }
        END { for (s in v) { t=s; sub(/^certified\//,"",t); sub(/-cert/,".",t); split(t,a,/[.-]/);
              if (sprintf("%d%02d%02d",a[1],a[2],a[3]) in n) print s } }' | sort -u | head -n 1
}

ast_find_version() {
    if [ -n "${ASTVERSION:-}" ]; then ASTVERSION_SRC=override
    else
        ASTVERSION=''; ASTVERSION_SRC=unknown
        if [ -n "${ASTERISK:-}" ]; then
            ASTVERSION=$(ad_run "$ASTERISK" -rx 'core show version' | ast_version_filter); ASTVERSION_SRC="running daemon (core show version)"
            if [ -z "$ASTVERSION" ]; then ASTVERSION=$(ad_run "$ASTERISK" -V | ast_version_filter); ASTVERSION_SRC="'$ASTERISK -V' (daemon not running; version on disk)"; fi
            if [ -z "$ASTVERSION" ]; then ASTVERSION=$(ast_version_from_strings "$ASTERISK"); ASTVERSION_SRC="strings(1) on $ASTERISK (binary does not run here)"; fi
            [ -n "$ASTVERSION" ] || ASTVERSION_SRC=unknown
            # binary on disk replaced after the daemon started?  Build for the RUNNING one, but say so.
            case $ASTVERSION_SRC in "running daemon"*)
                dv=$(ad_run "$ASTERISK" -V | ast_version_filter)
                [ -n "$dv" ] && [ "$dv" != "$ASTVERSION" ] && ad_warn "running Asterisk is $ASTVERSION but the binary on disk is $dv (restart pending?) - building for the RUNNING one";;
            esac
        fi
    fi
    # 16.30.1-vici -> 16.30.1 ; certified/18.9-cert1 -> 18.9 ; 18.10.0~dfsg... -> 18.10.0 ; GIT-... -> empty
    ASTVERBASE=$(printf '%s\n' "$ASTVERSION" | sed -n 's|^certified/||; s|^\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,2\}\).*|\1|p')
    ASTMAJOR=${ASTVERBASE%%.*}
    [ -n "$ASTVERSION" ]
}

# ---------------------------------------------------------------------------------------------
# 3. module dir: 'core show settings' -> asterisk.conf astmoddir -> first known dir holding pbx_config.so
# ---------------------------------------------------------------------------------------------
AST_MODDIR_CANDS="/usr/lib64/asterisk/modules /usr/lib/asterisk/modules /usr/lib/x86_64-linux-gnu/asterisk/modules /usr/local/lib/asterisk/modules /usr/local/lib64/asterisk/modules"

ast_find_moddir() {
    [ -n "${ASTMODDIR:-}" ] && { ASTMODDIR_SRC=override; return 0; }
    ASTMODDIR=''; ASTMODDIR_SRC=''
    if [ -n "${ASTERISK:-}" ]; then
        ASTMODDIR=$(ad_run "$ASTERISK" -rx 'core show settings' | sed -n 's/^ *Module directory: *//p' | head -n 1)
        [ -n "$ASTMODDIR" ] && ASTMODDIR_SRC="running daemon (core show settings)"
    fi
    if [ -z "$ASTMODDIR" ]; then
        ASTMODDIR=$(sed -n 's/^ *astmoddir *=> *\([^ ;]*\).*/\1/p' /etc/asterisk/asterisk.conf 2>/dev/null | head -n 1)
        [ -n "$ASTMODDIR" ] && ASTMODDIR_SRC="/etc/asterisk/asterisk.conf"
    fi
    if [ -z "$ASTMODDIR" ]; then
        for d in $AST_MODDIR_CANDS; do
            [ -f "$d/pbx_config.so" ] && { ASTMODDIR=$d; ASTMODDIR_SRC="contains pbx_config.so"; break; }
        done
    fi
    [ -n "$ASTMODDIR" ] || ASTMODDIR_SRC="not found"
    [ -n "$ASTMODDIR" ]
}

# ---------------------------------------------------------------------------------------------
# 4. AST_BUILDOPT_SUM of the core: the most frequent 32-hex string in the binary (one copy per
#    built-in module), else in a stock module.  NOT the 'Build Options' line of 'core show
#    settings' - that string also lists non-ABI flags (BUILD_NATIVE, ...) and is not the md5 input.
# ---------------------------------------------------------------------------------------------
ast_sum_of() { strings -a "$1" 2>/dev/null | grep -xE '[0-9a-f]{32}' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'; }

ast_find_buildsum() {
    [ -n "${ASTBUILDSUM:-}" ] && { ASTBUILDSUM_SRC=override; return 0; }
    ASTBUILDSUM=''; ASTBUILDSUM_SRC=''
    if [ -n "${ASTERISK:-}" ] && [ -r "$ASTERISK" ]; then
        ASTBUILDSUM=$(ast_sum_of "$ASTERISK"); ASTBUILDSUM_SRC="strings(1) on $ASTERISK"
    fi
    if [ -z "$ASTBUILDSUM" ] && [ -n "${ASTMODDIR:-}" ]; then
        for m in "$ASTMODDIR/pbx_config.so" "$ASTMODDIR/app_dial.so" "$ASTMODDIR/res_http_websocket.so"; do
            [ -f "$m" ] || continue
            ASTBUILDSUM=$(ast_sum_of "$m"); ASTBUILDSUM_SRC="strings(1) on $m"
            [ -n "$ASTBUILDSUM" ] && break
        done
    fi
    [ -n "$ASTBUILDSUM" ] || ASTBUILDSUM_SRC="unknown (no readable core binary or stock module)"
    [ -n "$ASTBUILDSUM" ]
}

# md5 of the ', '-joined ABI-relevant menuselect options + newline (build_tools/make_buildopts_h)
ast_sum_for_opts() { printf '%s\n' "$1" | md5sum | cut -c1-32; }

# Print the option list behind a known AST_BUILDOPT_SUM, or fail (rc 1) for an unknown sum.
# The candidates are the ABI-relevant options of menuselect (build_tools/cflags.xml order), in
# every combination, so any Asterisk >= 16 built from stock menuselect flags is covered.
# Asterisk 13 puts MALLOC_DEBUG/REF_DEBUG/LOW_MEMORY into the sum as well; 13 is out of scope.
ast_opts_for_sum() {
    _sum=$1
    case $_sum in
        da6642af068ee5e6490c5b1d2cc1d238) printf 'OPTIONAL_API\n'; return 0;;                  # stock 16/18/20/21/22 (ViciDial, ViciBox RPM)
        fa819827cbff2ea35341af5458859233) printf 'LOADABLE_MODULES, OPTIONAL_API\n'; return 0;; # stock 13
    esac
    # brute force over the ordered option set (2^9 = 512 md5 calls, about a second)
    _n=0
    while [ $_n -lt 512 ]; do
        _opts=''; _i=0
        for _o in DEBUG_THREADLOCALS DO_CRASH TEST_FRAMEWORK DEBUG_THREADS DEBUG_FD_LEAKS LOADABLE_MODULES OPTIONAL_API G711_NEW_ALGORITHM INTEGER_CALLERID; do
            if [ $(( (_n >> _i) & 1 )) -eq 1 ]; then
                _opts="${_opts:+$_opts, }$_o"
            fi
            _i=$((_i+1))
        done
        if [ -n "$_opts" ] && [ "$(ast_sum_for_opts "$_opts")" = "$_sum" ]; then printf '%s\n' "$_opts"; return 0; fi
        _n=$((_n+1))
    done
    return 1
}

# ast_synth_buildopts <include dir> <sum>: write <include dir>/asterisk/buildopts.h for a known sum.
# Used when only pristine headers are available (vendor header bundle, headers-only tarball extract).
ast_synth_buildopts() {
    _inc=$1; _sum=$2
    [ -n "$_sum" ] || { ad_err "cannot synthesise buildopts.h: AST_BUILDOPT_SUM of the running Asterisk is unknown"; return 1; }
    _opts=$(ast_opts_for_sum "$_sum") || { ad_err "AST_BUILDOPT_SUM $_sum is not one produced by stock menuselect options (custom build) - use the real configured+built source tree: ASTTOPDIR=/path/to/asterisk-<ver>"; return 1; }
    [ "$(ast_sum_for_opts "$_opts")" = "$_sum" ] || { ad_err "internal error: option list '$_opts' does not hash to $_sum"; return 1; }
    mkdir -p "$_inc/asterisk" || return 1
    {
        printf '/*\n * buildopts.h\n * Synthesised by ast-detect.sh for AST_BUILDOPT_SUM %s\n * (the running Asterisk was built with: %s)\n */\n\n' "$_sum" "$_opts"
        for _o in $(printf '%s' "$_opts" | tr -d ','); do printf '#define %s 1\n' "$_o"; done
        printf '#define AST_BUILDOPT_SUM "%s"\n' "$_sum"
        printf '#define AST_BUILDOPTS "%s"\n' "$_opts"
        printf '#define AST_BUILDOPTS_ALL "%s"\n' "$_opts"
    } > "$_inc/asterisk/buildopts.h" || return 1
    ad_log "synthesised $_inc/asterisk/buildopts.h (AST_BUILDOPTS \"$_opts\", sum $_sum)"
}

# ---------------------------------------------------------------------------------------------
# 5. validate one include dir.  rc 0 = usable; one '[ast-detect] accept/reject <dir>: <why>' line
#    on stderr.  Rules: asterisk.h + asterisk/autoconfig.h (configured) + asterisk/buildopts.h
#    (built or synthesised) must exist; the tree's .version must agree with the running version
#    when present; AST_BUILDOPT_SUM must equal the core's (mismatch = reject, ASTNOCHECK=1 = warn).
#    Installed headers without .version are tied to the binary by package version or by
#    install-time proximity (make install writes both within seconds); otherwise a WARNING.
# ---------------------------------------------------------------------------------------------
ast_check_incdir() {
    d=$1; why=''; note=''
    if   [ ! -f "$d/asterisk.h" ];            then why='no asterisk.h'
    elif [ ! -f "$d/asterisk/autoconfig.h" ]; then why='not configured (no asterisk/autoconfig.h)'
    elif [ ! -f "$d/asterisk/buildopts.h" ];  then why='not built (no asterisk/buildopts.h - ./configure alone is not enough)'
    else
        sum=$(sed -n 's/^#define AST_BUILDOPT_SUM "\([0-9a-f]*\)".*/\1/p' "$d/asterisk/buildopts.h" | head -n 1)
        # the candidate's OWN tree dir (not '$d/..', which would follow a symlinked include/ elsewhere)
        tv=$(sed -n 1p "${d%/include}/.version" 2>/dev/null)
        if [ -n "$tv" ] && [ -n "${ASTVERSION:-}" ] && [ "$tv" != "$ASTVERSION" ] && [ "$tv" != "$ASTVERBASE" ]; then
            why="tree version $tv != running $ASTVERSION"
        elif [ -n "${ASTBUILDSUM:-}" ] && [ "$sum" != "$ASTBUILDSUM" ]; then
            if [ "$ASTNOCHECK" = 1 ]; then note="WARNING: AST_BUILDOPT_SUM ${sum:-none} != core $ASTBUILDSUM, accepted because ASTNOCHECK=1"
            else why="AST_BUILDOPT_SUM ${sum:-none} != core $ASTBUILDSUM (Asterisk would refuse to load the module)"; fi
        elif [ -z "$tv" ]; then
            pv=''
            if command -v rpm >/dev/null 2>&1; then pv=$(rpm -qf --qf '%{VERSION}' "$d/asterisk.h" 2>/dev/null | grep -v 'not owned'); fi
            if [ -z "$pv" ] && command -v dpkg-query >/dev/null 2>&1; then
                pkg=$(dpkg -S "$d/asterisk.h" 2>/dev/null | sed 's/:.*//;q')
                [ -n "$pkg" ] && pv=$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null)
            fi
            pv=$(printf '%s' "$pv" | sed 's/^[0-9]*://')
            bm=$(stat -c %Y "${ASTERISK:-/nonexistent}" 2>/dev/null || echo 0); hm=$(stat -c %Y "$d/asterisk/buildopts.h" 2>/dev/null || echo 0)
            delta=$(( bm - hm )); [ $delta -lt 0 ] && delta=$(( -delta ))
            if   [ -n "$pv" ] && [ -n "$ASTVERBASE" ] && [ "${pv#"$ASTVERBASE"}" != "$pv" ]; then note="installed headers owned by package version $pv (matches running $ASTVERSION)"
            elif [ -n "$pv" ] && [ -n "$ASTVERBASE" ] && [ $delta -gt 3600 ]; then
                if [ "$ASTNOCHECK" = 1 ]; then note="WARNING: installed headers belong to package version $pv, running $ASTVERSION; accepted because ASTNOCHECK=1"
                else why="installed headers belong to package version $pv, running $ASTVERSION (and not rewritten by the same make install)"; fi
            elif [ $delta -le 3600 ] && [ "$bm" -gt 0 ]; then note="installed headers written within ${delta}s of the binary (same make install); sum matches"
            elif [ -z "${ASTBUILDSUM:-}" ]; then note="WARNING: unversioned headers and core sum unknown - cannot verify they match the running Asterisk"
            else note="WARNING: unversioned installed headers (not from a package, not installed together with the binary); AST_BUILDOPT_SUM matches but the Asterisk major version cannot be verified - prefer ASTTOPDIR=<matching source tree>"; fi
        else note="tree .version $tv matches"; fi
    fi
    if [ -n "$why" ]; then ad_log "reject $d: $why"; return 1; fi
    ad_log "accept $d: ${note:-ok}"; return 0
}

# ---------------------------------------------------------------------------------------------
# 6. candidates in priority order; the first valid one wins.
#    ASTINCDIR / ASTTOPDIR override the list; then trees named asterisk-<exact version>, trees of
#    the same base version (asterisk-<base>, asterisk-<base>-*, asterisk-certified-<base>*) under
#    AST_SRC_ROOTS - only directories with include/asterisk.h, so *.tar.gz, sound dirs and
#    asterisk-perl-* never match - then <prefix>/include next to the binary, then AST_INC_ROOTS.
# ---------------------------------------------------------------------------------------------
ad_add() { case " $cands " in *" $1 "*) ;; *) cands="$cands $1";; esac; }

ast_find_incdir() {
    cands=''; ASTINCDIR_SRC=''
    if [ -n "${ASTINCDIR:-}" ]; then cands=$ASTINCDIR; ASTINCDIR_SRC="ASTINCDIR override"
    elif [ -n "${ASTTOPDIR:-}" ]; then cands="$ASTTOPDIR/include"; ASTINCDIR_SRC="ASTTOPDIR override"
    else
        if [ -n "${ASTVERSION:-}" ]; then
            for r in $AST_SRC_ROOTS; do t="$r/asterisk-$ASTVERSION"; [ -f "$t/include/asterisk.h" ] && ad_add "$t/include"; done
            if [ -n "$ASTVERBASE" ]; then
                for r in $AST_SRC_ROOTS; do
                    for t in "$r/asterisk-$ASTVERBASE" "$r"/asterisk-"$ASTVERBASE"-* "$r"/asterisk-certified-"$ASTVERBASE"*; do
                        [ -f "$t/include/asterisk.h" ] && ad_add "$t/include"
                    done
                done
            fi
        else
            for r in $AST_SRC_ROOTS; do
                for t in "$r"/asterisk-[0-9]* "$r"/asterisk-certified-*; do [ -f "$t/include/asterisk.h" ] && ad_add "$t/include"; done
            done
        fi
        case ${ASTERISK:-} in */sbin/asterisk) p=${ASTERISK%/sbin/asterisk}; [ -f "$p/include/asterisk.h" ] && ad_add "$p/include";; esac
        for r in $AST_INC_ROOTS; do [ -f "$r/asterisk.h" ] && ad_add "$r"; done
        cands=${cands# }
    fi
    ok=''; n=0
    for d in $cands; do ast_check_incdir "$d" && { ok="$ok $d"; n=$((n+1)); }; done
    ok=${ok# }
    if [ -n "${ASTINCDIR:-}" ]; then
        [ $n -eq 1 ] || [ "$ASTNOCHECK" = 1 ] || { ad_err "ASTINCDIR=$ASTINCDIR failed validation (ASTNOCHECK=1 forces it)"; return 1; }
        return 0
    fi
    if [ -n "${ASTTOPDIR:-}" ]; then
        [ $n -eq 1 ] || [ "$ASTNOCHECK" = 1 ] || { ad_err "ASTTOPDIR=$ASTTOPDIR failed validation (ASTNOCHECK=1 forces it)"; return 1; }
        ASTINCDIR="$ASTTOPDIR/include"; return 0
    fi
    if [ -z "${ASTVERSION:-}" ]; then
        # unknown version: accept only an unambiguous candidate that is tied to the core by its sum
        if [ $n -eq 1 ] && [ -n "${ASTBUILDSUM:-}" ]; then
            ASTINCDIR=$ok; ASTINCDIR_SRC="only sum-matching candidate (version unknown)"
            ad_warn "Asterisk version unknown; using the only header dir whose AST_BUILDOPT_SUM matches the core: $ASTINCDIR (pass ASTVERSION=... to be sure)"; return 0
        fi
        if [ $n -ge 1 ] && [ "$ASTNOCHECK" = 1 ]; then
            ASTINCDIR=${ok%% *}; ASTINCDIR_SRC="first candidate (version unknown, ASTNOCHECK=1)"
            ad_warn "Asterisk version unknown and ASTNOCHECK=1: using $ASTINCDIR unverified"; return 0
        fi
        ad_err "Asterisk version could not be detected ($n header dir(s) validated: ${ok:-none}) - pass ASTVERSION=<version> or ASTTOPDIR=/path/to/configured+built source tree (ASTNOCHECK=1 forces the first candidate)"
        return 1
    fi
    ASTINCDIR=${ok%% *}; ASTINCDIR_SRC="first validated candidate"
    [ -n "$ASTINCDIR" ] && return 0
    ad_err "no configured+built Asterisk $ASTVERSION headers with AST_BUILDOPT_SUM ${ASTBUILDSUM:-?} found (candidates: ${cands:-none}; roots: $AST_SRC_ROOTS $AST_INC_ROOTS)"
    ast_hint_no_headers
    return 1
}

# next steps when nothing validates (kept in one place so Makefile and installer say the same)
ast_hint_no_headers() {
    v=${ASTVERSION:-<version>}
    case $v in
        *-vici)      tb="https://download.vicidial.com/required-apps/asterisk-$v.tar.gz"; tree="asterisk-$v";;
        certified/*) tb="https://downloads.asterisk.org/pub/telephony/certified-asterisk/releases/asterisk-certified-${v#certified/}.tar.gz"; tree="asterisk-certified-${v#certified/}";;
        *)           tb="https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTVERBASE:-$v}.tar.gz (or old-releases/)"; tree="asterisk-${ASTVERBASE:-$v}";;
    esac
    ad_err "fix one of: (a) run install.sh, which fetches a header bundle or the headers of $tb and synthesises buildopts.h;"
    ad_err "             (b) extract + ./configure + 'make include/asterisk/buildopts.h' that tarball and pass ASTTOPDIR=/path/to/$tree;"
    ad_err "             (c) install the asterisk-devel/asterisk-dev package of EXACTLY the running version (only when Asterisk itself is the distro package);"
    ad_err "             (d) ASTNOCHECK=1 to accept mismatching headers at your own risk (the loader may refuse the module)."
}

# ---------------------------------------------------------------------------------------------
# all-in-one: sets ASTERISK ASTVERSION ASTVERBASE ASTMAJOR ASTBUILDSUM ASTMODDIR ASTINCDIR (+ *_SRC)
# ---------------------------------------------------------------------------------------------
ast_detect_core() {
    ast_find_binary   || ad_warn "no asterisk binary found (pass ASTERISK=/path/to/asterisk)"
    ast_find_version  || ad_warn "cannot determine the Asterisk version${ASTERISK:+ from $ASTERISK}"
    ast_find_moddir   || ad_warn "no Asterisk module directory found (pass ASTMODDIR=/path)"
    ast_find_buildsum || ad_warn "cannot read AST_BUILDOPT_SUM from the core or its modules"
    ad_log "binary   : ${ASTERISK:-none} ($ASTERISK_SRC)"
    ad_log "version  : ${ASTVERSION:-unknown} (base ${ASTVERBASE:-?}, major ${ASTMAJOR:-?}) via $ASTVERSION_SRC"
    ad_log "buildsum : ${ASTBUILDSUM:-unknown} via $ASTBUILDSUM_SRC"
    ad_log "moddir   : ${ASTMODDIR:-unknown} ($ASTMODDIR_SRC)"
}

ast_detect() {
    ast_detect_core
    ast_find_incdir || return 1
    ad_log "headers  : $ASTINCDIR ($ASTINCDIR_SRC)"
    export ASTERISK ASTVERSION ASTVERBASE ASTMAJOR ASTBUILDSUM ASTMODDIR ASTINCDIR
    return 0
}

AST_DETECT_VARS="ASTERISK ASTVERSION ASTVERBASE ASTMAJOR ASTBUILDSUM ASTMODDIR ASTINCDIR ASTERISK_SRC ASTVERSION_SRC ASTBUILDSUM_SRC ASTMODDIR_SRC ASTINCDIR_SRC"

ast_print_vars() {   # $1 = sh | make
    for v in $AST_DETECT_VARS; do
        eval "val=\${$v:-}"
        case $1 in
            make) printf '%s := %s\n' "$v" "$val";;
            *)    printf "%s='%s'\n" "$v" "$(printf '%s' "$val" | sed "s/'/'\\\\''/g")";;
        esac
    done
}

# standalone use (not when sourced as a library)
case ${0##*/} in
    ast-detect.sh)
        case ${1:-} in
            --running) ast_running; exit $?;;
            --make)    ast_detect; rc=$?; printf 'AST_DETECT_RC := %s\n' "$rc"; ast_print_vars make; exit $rc;;
            --help|-h) sed -n '2,32p' "$0"; exit 0;;
            *)         ast_detect; rc=$?; ast_print_vars sh; exit $rc;;
        esac;;
esac
