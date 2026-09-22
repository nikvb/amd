#!/bin/bash
# test/run.sh - end-to-end test harness for app_amd_ws (SPEC section 9).
#
# Runs as an unprivileged user against the real Asterisk binary on this box,
# with every file under test/run/ (gitignored).  See test/README.md.
#
#   test/run.sh                 build ../app_amd_ws.so, run every scenario
#   test/run.sh --selftest      plumbing only (no module needed): originate,
#                               playback capture, results file, mock server, timing
#   test/run.sh --only NAME[,NAME]   run selected scenarios/checks
#   test/run.sh --keep          leave Asterisk + mock running afterwards
#   test/run.sh --list          list scenarios and exit
#
# Exit status: 0 all PASS, 1 any FAIL, 2 harness/infrastructure problem.
set -u -o pipefail

# ---------------------------------------------------------------------------
# locations / knobs (env overridable)
# ---------------------------------------------------------------------------
TESTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TESTDIR/.." && pwd)
RUN=$TESTDIR/run
AST_RUN=$RUN/ast
LOGROOT=$RUN/logs
REC=$RUN/rec
TS=$(date +%Y%m%d-%H%M%S)
LOGDIR=$LOGROOT/run-$TS

ASTERISK_BIN=${ASTERISK_BIN:-/usr/sbin/asterisk}
AST_LD_LIBRARY_PATH=${AST_LD_LIBRARY_PATH:-/usr/lib64}
AST_MODULES_DIR=${AST_MODULES_DIR:-/usr/lib64/asterisk/modules}
AST_DATA_DIR=${AST_DATA_DIR:-/var/lib/asterisk}
MODULE_SO=${MODULE_SO:-}
SCENARIOS=${SCENARIOS:-$TESTDIR/scenarios.txt}
PYTHON=${PYTHON:-python3}
MAKE_ARGS=${MAKE_ARGS:-}
# MariaDB client staged without root (SPEC section 1); used when the system has no MySQL dev files
MYSQL_ROOT=${MYSQL_ROOT:-/tmp/claude-1000/-home-na/ba3f2cc5-ea24-44ec-aebc-c050b41abe5d/scratchpad/mariadb/usr}
SUITE_BUDGET_S=${SUITE_BUDGET_S:-240}

MODE=full           # full | selftest
ONLY=""
KEEP=0
NO_BUILD=0
LIST=0
VERBOSE=0

usage() { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

while [ $# -gt 0 ]; do
	case "$1" in
	--selftest) MODE=selftest ;;
	--only) ONLY=$2; shift ;;
	--only=*) ONLY=${1#--only=} ;;
	--keep) KEEP=1 ;;
	--no-build) NO_BUILD=1 ;;
	--module) MODULE_SO=$2; shift ;;
	--module=*) MODULE_SO=${1#--module=} ;;
	--scenarios) SCENARIOS=$2; shift ;;
	--list) LIST=1 ;;
	-v|--verbose) VERBOSE=1 ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done
[ -n "$MODULE_SO" ] && NO_BUILD=1
: "${MODULE_SO:=$REPO/app_amd_ws.so}"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
SUITE_T0=$(date +%s)
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
vlog() { [ "$VERBOSE" = 1 ] && log "$@"; return 0; }
die()  { log "ERROR: $*"; FINAL_RC=2; exit 2; }
now_ms() { date +%s%3N; }

ROWS=()          # "RESULT|name|status/cause|wall|elapsed|detail"
N_PASS=0; N_FAIL=0; N_SKIP=0
FINAL_RC=0
row() {  # result name statuscause wall elapsed detail
	local r=$1
	ROWS+=("$1|$2|$3|$4|$5|$6")
	case "$r" in
	PASS) N_PASS=$((N_PASS + 1)) ;;
	FAIL) N_FAIL=$((N_FAIL + 1)) ;;
	SKIP) N_SKIP=$((N_SKIP + 1)) ;;
	esac
	printf '  %-4s %-20s %-24s %7s %7s  %s\n' "$1" "$2" "$3" "$4" "$5" "${6:0:110}"
}

print_table() {
	{
		echo
		echo "=================================================================================================="
		printf '%-4s %-20s %-24s %7s %7s  %s\n' RESULT SCENARIO STATUS/CAUSE WALLms AMDms DETAIL
		echo "--------------------------------------------------------------------------------------------------"
		local r
		for r in "${ROWS[@]}"; do
			IFS='|' read -r a b c d e f <<<"$r"
			printf '%-4s %-20s %-24s %7s %7s  %s\n' "$a" "$b" "$c" "$d" "$e" "$f"
		done
		echo "--------------------------------------------------------------------------------------------------"
		printf 'PASS %d  FAIL %d  SKIP %d   (mode=%s, %ds, logs: %s)\n' "$N_PASS" "$N_FAIL" "$N_SKIP" "$MODE" "$(($(date +%s) - SUITE_T0))" "$LOGDIR"
		echo "=================================================================================================="
	} | tee "$LOGDIR/summary.txt"
}

# ---------------------------------------------------------------------------
# asterisk helpers
# ---------------------------------------------------------------------------
AST_CONF=$AST_RUN/etc/asterisk.conf
AST_PID=""
MOCK_PID=""
MOCK_PORT=""
DEAD_PORT=""
DB_PORT=""
FULL_LOG=""
RESULTS=$RUN/results.txt
CONTROL=$RUN/mock.control

ast_bin() { LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH "$ASTERISK_BIN" "$@"; }
ast_cli() { LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH timeout 15 "$ASTERISK_BIN" -C "$AST_CONF" -rx "$*" 2>&1; }
# NOTE: never pipe a live command into 'grep -q' here: with pipefail the SIGPIPE
# on early exit makes a matching pipeline report failure.  Capture, then test.
has() { grep -q -- "$2" <<<"$1"; }       # has "$haystack" 'regex'
hasi() { grep -qi -- "$2" <<<"$1"; }
ast_alive() { local o; o=$(ast_cli 'core show version' 2>/dev/null); has "$o" '^Asterisk'; }

our_asterisk_pids() { # daemons (not -r consoles) started with our asterisk.conf
	local p cl
	for p in $(pgrep -u "$(id -u)" -x asterisk 2>/dev/null); do
		cl=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) || continue
		case "$cl" in *"-C $AST_CONF "*) case "$cl" in *" -r"*) ;; *) echo "$p" ;; esac ;; esac
	done
}

free_port() {
	"$PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

port_listening() { # port
	"$PYTHON" -c 'import socket,sys
s=socket.socket(); s.settimeout(0.3)
try:
    s.connect(("127.0.0.1",int(sys.argv[1]))); sys.exit(0)
except Exception:
    sys.exit(1)' "$1"
}

# ---------------------------------------------------------------------------
# scenario table
# ---------------------------------------------------------------------------
trim() { local s=$*; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

S_NAME=(); S_TAGS=(); S_COUNT=(); S_FAR=(); S_MOCK=(); S_AMD=(); S_POST=(); S_STATUS=(); S_CAUSE=(); S_MIN=(); S_MAX=(); S_ASSERTS=()
load_scenarios() {
	[ -f "$SCENARIOS" ] || die "scenario table not found: $SCENARIOS"
	local line f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%$'\r'}
		case "$(trim "$line")" in ''|'#'*) continue ;; esac
		IFS='|' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 <<<"$line"
		f1=$(trim "$f1")
		case "$f1" in *[!a-z0-9_]*) die "scenario name '$f1' must match [a-z0-9_]+" ;; esac
		local i; for i in "${!S_NAME[@]}"; do [ "${S_NAME[$i]}" = "$f1" ] && die "duplicate scenario name $f1"; done
		S_NAME+=("$f1"); S_TAGS+=("$(trim "$f2")"); S_COUNT+=("$(trim "$f3")"); S_FAR+=("$(trim "$f4")")
		S_MOCK+=("$(trim "$f5")"); S_AMD+=("$(trim "$f6")"); S_POST+=("$(trim "$f7")"); S_STATUS+=("$(trim "$f8")")
		S_CAUSE+=("$(trim "$f9")"); S_MIN+=("$(trim "$f10")"); S_MAX+=("$(trim "$f11")"); S_ASSERTS+=("$(trim "${f12:-}")")
	done <"$SCENARIOS"
	[ ${#S_NAME[@]} -gt 0 ] || die "no scenarios in $SCENARIOS"
}

scenario_index() { local i; for i in "${!S_NAME[@]}"; do [ "${S_NAME[$i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }

has_tag() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

selected() { # name -> 0 if selected by --only (or no --only)
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

# dialplan generation --------------------------------------------------------
emit_apps() { # "App1(a) && App2(b)" -> ' same => n,App1(a)' lines
	local chain=$1 rest
	while :; do
		rest=${chain#* && }
		if [ "$rest" = "$chain" ]; then
			printf ' same => n,%s\n' "$(trim "$chain")"
			break
		fi
		printf ' same => n,%s\n' "$(trim "${chain%% && *}")"
		chain=$rest
	done
}

gen_dialplan() { # appends per-scenario [farside-<name>] / [amdside-<name>] contexts to $1
	# The scenario travels in the CONTEXT name (exact match); the extension is the
	# 4-digit call counter matched by _XXXX.  Never put the scenario name into a
	# pattern: pbx.c matches N/X/Z case-insensitively, so "hangup" would be a pattern.
	local out=$1 i name far amd post
	{
		echo
		echo "; ---- generated from $SCENARIOS at $TS ----"
		for i in "${!S_NAME[@]}"; do
			name=${S_NAME[$i]}; far=${S_FAR[$i]}; amd=${S_AMD[$i]}; post=${S_POST[$i]}
			echo
			echo "[farside-${name}]"
			echo "exten => _XXXX,1,NoOp(farside \${EXTEN}_${name} behaviour=${far})"
			echo " same => n,Gosub(fs-${far},s,1(\${EXTEN}_${name},${name},\${EXTEN}))"
			echo " same => n,Hangup()"
			echo
			echo "[amdside-${name}]"
			echo "exten => h,1,Gosub(write-result,s,1)"
			echo "exten => _XXXX,1,NoOp(amdside \${EXTEN}_${name})"
			echo " same => n,Set(VID=\${EXTEN}_${name})"
			echo " same => n,Set(SCENARIO=${name})"
			echo " same => n,Set(T0=\${STRFTIME(,,%s%3q)})"
			case "$amd" in
			ws:*)     echo " same => n,AMD_WS(127.0.0.1,\${MOCK_PORT},\${VID},${amd#ws:})" ;;
			wsdead:*) echo " same => n,AMD_WS(127.0.0.1,\${DEAD_PORT},\${VID},${amd#wsdead:})" ;;
			wsraw:*)  echo " same => n,AMD_WS(${amd#wsraw:})" ;;
			app:*)    emit_apps "${amd#app:}" ;;
			*) die "scenario $name: bad amdside spec '$amd'" ;;
			esac
			echo " same => n,Set(T1=\${STRFTIME(,,%s%3q)})"
			[ "$post" != "-" ] && [ -n "$post" ] && emit_apps "$post"
			echo " same => n,Hangup()"
		done
	} >>"$out"
}

# ---------------------------------------------------------------------------
# sounds (sox, 8 kHz mono 16-bit)
# ---------------------------------------------------------------------------
gen_sounds() { # dir
	local d=$1 sx="sox -D -n -r 8000 -c 1 -b 16 -e signed-integer"
	mkdir -p "$d"
	[ -s "$d/amd-speech8.wav" ]      || $sx "$d/amd-speech8.wav"      synth 8 sine 200-2600 sine mix 350-1900 tremolo 3.3 70 vol 0.45
	[ -s "$d/amd-speech1500.wav" ]   || $sx "$d/amd-speech1500.wav"   synth 1.5 sine 200-2600 sine mix 350-1900 tremolo 3.3 70 vol 0.45
	[ -s "$d/amd-beep.wav" ]         || $sx "$d/amd-beep.wav"         synth 0.5 sine 1000 vol 0.4
	[ -s "$d/amd-silence8.wav" ]     || $sx "$d/amd-silence8.wav"     trim 0 8
	[ -s "$d/amd-prompt.wav" ]       || $sx "$d/amd-prompt.wav"       synth 6 square 440 tremolo 2 90 vol 0.35
	[ -s "$d/amd-prompt-short.wav" ] || $sx "$d/amd-prompt-short.wav" synth 1 sine 660 vol 0.35
}

rms_of() { # file [start len] -> RMS amplitude (0 when unreadable/empty)
	local f=$1 v
	[ -s "$f" ] || { echo 0; return; }
	if [ $# -ge 3 ]; then
		v=$(sox "$f" -n trim "$2" "$3" stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
	else
		v=$(sox "$f" -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
	fi
	case "$v" in ''|*nan*|*inf*) v=0 ;; esac
	echo "$v"
}
dur_of() { local f=$1; [ -s "$f" ] && soxi -D "$f" 2>/dev/null || echo 0; }
fcmp() { awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN { if (op==">") exit !(a+0 > b+0); if (op=="<") exit !(a+0 < b+0); if (op==">=") exit !(a+0 >= b+0); if (op=="<=") exit !(a+0 <= b+0); exit 1 }'; }

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
MODULE_AVAILABLE=0
EXTRA_LD=""
mysql_flavour() {
	if pkg-config --exists libmariadb 2>/dev/null || pkg-config --exists mariadb 2>/dev/null || pkg-config --exists mysqlclient 2>/dev/null \
	   || command -v mariadb_config >/dev/null 2>&1 || command -v mysql_config >/dev/null 2>&1; then
		echo system
	elif [ -d "$MYSQL_ROOT/include/mariadb" ] && [ -d "$MYSQL_ROOT/lib/x86_64-linux-gnu" ]; then
		echo staged
	else
		echo none
	fi
}

build_module() {
	if [ "$NO_BUILD" = 1 ]; then
		if [ -f "$MODULE_SO" ]; then MODULE_AVAILABLE=1; log "using module $MODULE_SO (no build)"; else log "module $MODULE_SO not found"; fi
		return
	fi
	if [ ! -f "$REPO/Makefile" ] || [ ! -f "$REPO/app_amd_ws.c" ]; then
		row SKIP build_module - - - "no Makefile/app_amd_ws.c in $REPO"; return
	fi
	if ! grep -q 'http_websocket.h' "$REPO/app_amd_ws.c"; then
		row SKIP build_module - - - "app_amd_ws.c is not the v2 (res_http_websocket) module yet"; return
	fi
	local flav; flav=$(mysql_flavour)
	local blog=$LOGDIR/build.log
	export LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH
	log "build 1/2: make MYSQL=0 (flavour=$flav)"
	if (cd "$REPO" && make clean >/dev/null 2>&1; make MYSQL=0 $MAKE_ARGS) >"$blog.nomysql" 2>&1 && [ -f "$REPO/app_amd_ws.so" ]; then
		row PASS build_nomysql - - - "make MYSQL=0 ok ($(stat -c %s "$REPO/app_amd_ws.so") bytes)"
	else
		row FAIL build_nomysql - - - "make MYSQL=0 failed, see $blog.nomysql"; tail -20 "$blog.nomysql"; return
	fi
	local margs=()
	case "$flav" in
	system) margs=(MYSQL=1) ;;
	staged) margs=(MYSQL=1 "MYSQL_CFLAGS=-I$MYSQL_ROOT/include/mariadb -I$MYSQL_ROOT/include" "MYSQL_LIBS=-L$MYSQL_ROOT/lib/x86_64-linux-gnu -lmariadb")
	        EXTRA_LD=$MYSQL_ROOT/lib/x86_64-linux-gnu ;;
	none) row SKIP build_mysql - - - "no MySQL/MariaDB client dev files (system or $MYSQL_ROOT)"; MODULE_AVAILABLE=1; return ;;
	esac
	log "build 2/2: make ${margs[*]}"
	if (cd "$REPO" && make clean >/dev/null 2>&1; make "${margs[@]}" $MAKE_ARGS) >"$blog" 2>&1 && [ -f "$REPO/app_amd_ws.so" ]; then
		local und
		und=$(ldd -r "$REPO/app_amd_ws.so" 2>&1 | grep 'undefined symbol' | grep -vE 'symbol: (_?_?ast_|__ao2_|ao2_|pbx_)' || true)
		if [ -n "$und" ]; then
			row FAIL build_mysql - - - "unresolved non-Asterisk symbols: $(echo "$und" | awk '{print $3}' | tr '\n' ' ')"
		elif grep -qi 'mysql: *yes\|HAVE_MYSQL' "$blog"; then
			row PASS build_mysql - - - "make MYSQL=1 ($flav) ok, no undefined non-ast symbols"
		else
			row PASS build_mysql - - - "make ${margs[0]} ok (could not confirm 'MySQL: yes' in build log)"
		fi
		MODULE_AVAILABLE=1
	else
		row FAIL build_mysql - - - "make MYSQL=1 failed, see $blog"; tail -20 "$blog"
		# fall back to the MYSQL=0 object so the rest of the suite can still run
		(cd "$REPO" && make clean >/dev/null 2>&1; make MYSQL=0 $MAKE_ARGS) >/dev/null 2>&1 && MODULE_AVAILABLE=1
	fi
	unset LD_LIBRARY_PATH
}

# ---------------------------------------------------------------------------
# environment: run dir, configs, mock, asterisk
# ---------------------------------------------------------------------------
prepare_rundir() {
	mkdir -p "$LOGDIR" "$REC"
	ln -sfn "run-$TS" "$LOGROOT/latest"
	rm -rf "$AST_RUN"
	mkdir -p "$AST_RUN/etc" "$AST_RUN/modules" "$AST_RUN/var/lib/sounds/en" "$AST_RUN/var/lib/agi-bin" \
	         "$AST_RUN/var/spool/monitor" "$AST_RUN/var/run" "$AST_RUN/var/lib/keys"
	rm -f "$RESULTS"; : >"$RESULTS"
	rm -f "$REC"/*.wav 2>/dev/null
	: >"$CONTROL"

	# module dir: symlink farm to the system modules + our freshly built .so
	local f
	for f in "$AST_MODULES_DIR"/*.so; do
		[ "$(basename "$f")" = app_amd_ws.so ] && continue
		ln -s "$f" "$AST_RUN/modules/"
	done
	if [ "$MODE" = full ] && [ "$MODULE_AVAILABLE" = 1 ]; then
		cp "$MODULE_SO" "$AST_RUN/modules/app_amd_ws.so"
		echo "load => app_amd_ws.so" >"$AST_RUN/etc/modules.conf.amd"
	else
		echo "; app_amd_ws.so not loaded (selftest or module unavailable)" >"$AST_RUN/etc/modules.conf.amd"
	fi

	# the core refuses to start without its XML documentation (stasis aco options need it)
	local docs
	for docs in "$AST_DATA_DIR/documentation" /var/lib/asterisk/documentation /usr/share/asterisk/documentation; do
		[ -f "$docs/core-en_US.xml" ] && { ln -s "$docs" "$AST_RUN/var/lib/documentation"; break; }
	done
	[ -e "$AST_RUN/var/lib/documentation" ] || die "no Asterisk XML documentation dir found (core-en_US.xml); set AST_DATA_DIR"

	gen_sounds "$RUN/sounds"
	cp "$RUN/sounds"/*.wav "$AST_RUN/var/lib/sounds/en/"

	DEAD_PORT=$(free_port)
	DB_PORT=3306
	port_listening 3306 && DB_PORT=$(free_port)

	cp "$TESTDIR/asterisk/modules.conf" "$TESTDIR/asterisk/logger.conf" "$TESTDIR/asterisk/http.conf" "$TESTDIR/asterisk/indications.conf" "$AST_RUN/etc/"
	# empty stubs so the core does not log "Unable to load config file" for optional subsystems
	for f in cdr cel features acl udptl ccss manager rtp stasis codecs cli_permissions; do
		printf '; stub written by test/run.sh\n[general]\n' >"$AST_RUN/etc/$f.conf"
	done
	printf '; manager (AMI) stays off: no network listeners in the test instance\n[general]\nenabled = no\n' >"$AST_RUN/etc/manager.conf"
	sed -e "s|@RUN@|$AST_RUN|g" -e "s|@LOGDIR@|$LOGDIR|g" "$TESTDIR/asterisk/asterisk.conf.in" >"$AST_CONF"
	sed -e "s|@DBPORT@|$DB_PORT|g" "$TESTDIR/asterisk/astguiclient.conf.in" >"$AST_RUN/etc/astguiclient.conf"
	FULL_LOG=$LOGDIR/full
}

render_dialplan() { # needs MOCK_PORT
	sed -e "s|@RESULTS@|$RESULTS|g" -e "s|@REC@|$REC|g" -e "s|@MOCK_PORT@|$MOCK_PORT|g" -e "s|@DEAD_PORT@|$DEAD_PORT|g" \
		"$TESTDIR/asterisk/extensions.conf.in" >"$AST_RUN/etc/extensions.conf"
	gen_dialplan "$AST_RUN/etc/extensions.conf"
	sed -e "s|@RUN@|$AST_RUN|g" -e "s|@MOCK_PORT@|$MOCK_PORT|g" -e "s|@DBPORT@|$DB_PORT|g" "$TESTDIR/asterisk/amd_ws.conf.in" >"$AST_RUN/etc/amd_ws.conf"
}

start_mock() {
	rm -f "$RUN/mock.port"
	"$PYTHON" "$TESTDIR/mock_amd_server.py" --port 0 --record "$LOGDIR/mock-record.jsonl" --control "$CONTROL" \
		--port-file "$RUN/mock.port" -v >"$LOGDIR/mock.out" 2>"$LOGDIR/mock.log" &
	MOCK_PID=$!
	local i
	for i in $(seq 1 100); do [ -s "$RUN/mock.port" ] && break; sleep 0.1; done
	[ -s "$RUN/mock.port" ] || die "mock server did not start (see $LOGDIR/mock.log)"
	MOCK_PORT=$(cat "$RUN/mock.port")
	log "mock server pid=$MOCK_PID port=$MOCK_PORT dead_port=$DEAD_PORT db_port=$DB_PORT"
}

stop_stale_asterisk() {
	local p
	for p in $(our_asterisk_pids); do
		log "stopping stale test asterisk pid $p"
		kill "$p" 2>/dev/null || true
	done
	sleep 0.5
}

start_asterisk() {
	local i
	stop_stale_asterisk
	log "starting asterisk: LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH${EXTRA_LD:+:$EXTRA_LD} $ASTERISK_BIN -C $AST_CONF -F -mq"
	LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH${EXTRA_LD:+:$EXTRA_LD} "$ASTERISK_BIN" -C "$AST_CONF" -F -mq >"$LOGDIR/asterisk-console.log" 2>&1
	for i in $(seq 1 100); do
		[ -S "$AST_RUN/var/run/asterisk.ctl" ] && break
		sleep 0.1
	done
	[ -S "$AST_RUN/var/run/asterisk.ctl" ] || die "asterisk control socket did not appear (see $LOGDIR/asterisk-console.log, $FULL_LOG)"
	for i in $(seq 1 150); do
		local o; o=$(ast_cli 'core waitfullybooted'); has "$o" 'fully booted' && break
		[ -n "$(our_asterisk_pids)" ] || die "asterisk exited during startup (see $LOGDIR/asterisk-console.log, $FULL_LOG)"
		sleep 0.2
	done
	ast_alive || die "asterisk did not boot within 30 s"
	AST_PID=$(cat "$AST_RUN/var/run/asterisk.pid" 2>/dev/null || our_asterisk_pids | head -1)
	log "asterisk pid=$AST_PID booted ($(ast_cli 'core show version' | head -1))"
}

stop_asterisk() {
	[ -n "$AST_PID" ] || return 0
	local i
	ast_cli 'core stop now' >/dev/null 2>&1 || true
	for i in $(seq 1 150); do
		kill -0 "$AST_PID" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$AST_PID" 2>/dev/null; then
		row FAIL shutdown_clean - - - "'core stop now' left pid $AST_PID alive after 15 s; killing it"
		kill -9 "$AST_PID" 2>/dev/null || true
		sleep 0.5
	else
		local left; left=$(our_asterisk_pids | tr '\n' ' ')
		if [ -n "$left" ]; then
			row FAIL shutdown_clean - - - "asterisk processes with our config still running: $left"
		else
			row PASS shutdown_clean - - - "core stop now -> pid $AST_PID gone in $((i * 100)) ms; pgrep -u $(id -un) -f '-C $AST_CONF' empty (all asterisk of user: $(pgrep -u "$(id -u)" -x asterisk | wc -l))"
		fi
	fi
	AST_PID=""
}

stop_mock() {
	[ -n "$MOCK_PID" ] || return 0
	kill "$MOCK_PID" 2>/dev/null || true
	wait "$MOCK_PID" 2>/dev/null || true
	MOCK_PID=""
}

cleanup() {
	local rc=$?
	trap - EXIT
	if [ "$KEEP" = 1 ] && [ -n "$AST_PID" ]; then
		log "--keep: asterisk pid $AST_PID and mock pid $MOCK_PID left running"
		log "  console: LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH $ASTERISK_BIN -C $AST_CONF -r"
		log "  stop:    LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH $ASTERISK_BIN -C $AST_CONF -rx 'core stop now'; kill $MOCK_PID"
		log "  mock control file: $CONTROL (write e.g. /human?after=2), results: $RESULTS"
	else
		stop_asterisk
		stop_mock
	fi
	[ -n "${LOGDIR:-}" ] && [ -d "$LOGDIR" ] && [ ${#ROWS[@]} -gt 0 ] && print_table
	[ "$FINAL_RC" != 0 ] && exit "$FINAL_RC"
	[ "$N_FAIL" -gt 0 ] && exit 1
	exit "$rc"
}

# ---------------------------------------------------------------------------
# calls
# ---------------------------------------------------------------------------
CALL_NO=0
VID=""; VID_NUM=""
next_vid() { # name -> sets VID (NNNN_name) and VID_NUM (NNNN)
	CALL_NO=$((CALL_NO + 1))
	VID_NUM=$(printf '%04d' "$CALL_NO")
	VID=${VID_NUM}_$1
}

set_control() { # mock path or '-'
	[ "$1" = "-" ] && return 0
	printf '%s\n' "$1" >"$CONTROL.tmp" && mv "$CONTROL.tmp" "$CONTROL"
}

originate() { # vid (NNNN_name)
	local num=${1%%_*} name=${1#*_}
	ast_cli "channel originate Local/$num@farside-$name/n extension $num@amdside-$name"
}

wait_result() { # vid deadline_s -> prints the result line, rc 1 on timeout
	local vid=$1 deadline=$(( $(date +%s) + $2 )) line
	while :; do
		line=$(grep -m1 -F -- "$vid|" "$RESULTS" 2>/dev/null | grep -- "^$vid|" || true)
		[ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
		[ "$(date +%s)" -ge "$deadline" ] && return 1
		sleep 0.1
	done
}

wait_quiet() { # vid: wait until no channel of this call exists (max 8 s)
	local i o num=${1%%_*} name=${1#*_}
	for i in $(seq 1 80); do
		o=$(ast_cli 'core show channels concise'); grep -q -F -- "/$num@farside-$name" <<<"$o" || return 0
		sleep 0.1
	done
	return 1
}

wait_file_stable() { # file: wait until size stops changing (recording finalised)
	local f=$1 s1 s2 i
	for i in $(seq 1 30); do
		[ -s "$f" ] || { sleep 0.1; continue; }
		s1=$(stat -c %s "$f"); sleep 0.15; s2=$(stat -c %s "$f")
		[ "$s1" = "$s2" ] && return 0
	done
	return 1
}

# result line: VID|AMDSTATUS|AMDCAUSE|AMDELAPSED|T0|T1|TA|R64|CHANNEL
parse_result() {
	IFS='|' read -r R_VID R_STATUS R_CAUSE R_ELAPSED R_T0 R_T1 R_TA R_R64 R_CHAN <<<"$1"
	R_RESP=$(printf '%s' "$R_R64" | base64 -d 2>/dev/null | cut -c2- || true)
	R_WALL=""; R_AUDIO=""
	[[ $R_T0 =~ ^[0-9]+$ && $R_T1 =~ ^[0-9]+$ ]] && R_WALL=$((R_T1 - R_T0))
	[[ $R_TA =~ ^[0-9]+$ && $R_T1 =~ ^[0-9]+$ ]] && R_AUDIO=$((R_T1 - R_TA))
}

mock_chunks() { # vid -> number of chunks in the mock record (or "none")
	"$PYTHON" - "$LOGDIR/mock-record.jsonl" "$1" <<'EOF'
import json, sys
n = "none"
try:
    for line in open(sys.argv[1]):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("event") == "connection" and r.get("vid") == sys.argv[2]:
            n = len(r.get("chunks") or [])
except OSError:
    pass
print(n)
EOF
}

check_asserts() { # vid asserts -> appends failures to A_FAIL, notes to A_NOTE
	local vid=$1 list=$2 tok checks extra phone country v thr seg st ln pat rc
	A_FAIL=""; A_NOTE=""
	[ -z "$list" ] && return 0
	local IFS=','
	for tok in $list; do
		unset IFS
		tok=$(trim "$tok")
		[ -z "$tok" ] && continue
		case "$tok" in
		proto)
			v=$("$PYTHON" "$TESTDIR/protocol_test.py" --record "$LOGDIR/mock-record.jsonl" --vid "$vid" --checks config,schedule,bytes,eof,close --no-phone 2>&1); rc=$?
			printf '%s\n' "$v" >>"$LOGDIR/scenario-$vid.log"
			[ $rc = 0 ] || A_FAIL+="proto[$(printf '%s' "$v" | grep '^FAIL' | cut -d: -f1 | sed 's/FAIL //' | tr '\n' ' ')] "
			A_NOTE+="$(printf '%s' "$v" | awk '/^PASS schedule/ {sub(/^PASS schedule: chunks at /,""); sub(/ ms after config/,""); print "sched " $0}' | head -1) "
			;;
		proto:*)
			checks=""; extra=()
			local IFS=';'
			for v in ${tok#proto:}; do
				case "$v" in
				phone=*) extra+=(--phone "${v#phone=}") ;;
				country=*) extra+=(--country "${v#country=}") ;;
				*) checks+="$v," ;;
				esac
			done
			unset IFS
			[ ${#extra[@]} = 0 ] && extra=(--no-phone)
			v=$("$PYTHON" "$TESTDIR/protocol_test.py" --record "$LOGDIR/mock-record.jsonl" --vid "$vid" --checks "${checks%,}" "${extra[@]}" 2>&1); rc=$?
			printf '%s\n' "$v" >>"$LOGDIR/scenario-$vid.log"
			[ $rc = 0 ] || A_FAIL+="proto[$(printf '%s' "$v" | grep '^FAIL' | cut -d: -f1 | sed 's/FAIL //' | tr '\n' ' ')] "
			;;
		chunks=*|chunks\>=*|chunks\<=*)
			v=$(mock_chunks "$vid")
			case "$tok" in
			chunks\>=*) [ "$v" != none ] && [ "$v" -ge "${tok#chunks>=}" ] || A_FAIL+="chunks=$v(want>=${tok#chunks>=}) " ;;
			chunks\<=*) [ "$v" != none ] && [ "$v" -le "${tok#chunks<=}" ] || A_FAIL+="chunks=$v(want<=${tok#chunks<=}) " ;;
			*)          [ "$v" = "${tok#chunks=}" ] || A_FAIL+="chunks=$v(want ${tok#chunks=}) " ;;
			esac
			A_NOTE+="chunks=$v "
			;;
		noconn)
			v=$(mock_chunks "$vid")
			[ "$v" = none ] || A_FAIL+="mock has a connection for $vid ($v chunks) "
			;;
		resp~*) [[ $R_RESP == *"${tok#resp~}"* ]] || A_FAIL+="resp='$R_RESP'(want ~'${tok#resp~}') " ;;
		resp=*) [ "$R_RESP" = "${tok#resp=}" ] || A_FAIL+="resp='$R_RESP'(want '${tok#resp=}') " ;;
		elapsed\>=*) [[ $R_ELAPSED =~ ^[0-9]+$ ]] && [ "$R_ELAPSED" -ge "${tok#elapsed>=}" ] || A_FAIL+="AMDELAPSED=$R_ELAPSED(want>=${tok#elapsed>=}) " ;;
		elapsed\<=*) [[ $R_ELAPSED =~ ^[0-9]+$ ]] && [ "$R_ELAPSED" -le "${tok#elapsed<=}" ] || A_FAIL+="AMDELAPSED=$R_ELAPSED(want<=${tok#elapsed<=}) " ;;
		heard_dur\<*|heard_dur\>*)
			wait_file_stable "$REC/$vid-heard.wav" || true
			v=$(dur_of "$REC/$vid-heard.wav")
			case "$tok" in
			heard_dur\<*) fcmp "$v" "<" "${tok#heard_dur<}" || A_FAIL+="heard_dur=${v}s(want<${tok#heard_dur<}) " ;;
			*)            fcmp "$v" ">" "${tok#heard_dur>}" || A_FAIL+="heard_dur=${v}s(want>${tok#heard_dur>}) " ;;
			esac
			A_NOTE+="heard_dur=${v}s "
			;;
		heard\[*)
			seg=${tok#heard[}; seg=${seg%%]*}; st=${seg%%:*}; ln=${seg#*:}
			rest=${tok#*]}; thr=${rest#?}
			wait_file_stable "$REC/$vid-heard.wav" || true
			v=$(rms_of "$REC/$vid-heard.wav" "$st" "$ln")
			fcmp "$v" "${rest:0:1}" "$thr" || A_FAIL+="heard[$st:$ln]rms=$v(want${rest:0:1}$thr) "
			A_NOTE+="heard[$st:$ln]=$v "
			;;
		heard\>*|heard\<*)
			wait_file_stable "$REC/$vid-heard.wav" || true
			v=$(rms_of "$REC/$vid-heard.wav")
			fcmp "$v" "${tok:5:1}" "${tok:6}" || A_FAIL+="heard_rms=$v(want${tok:5}) "
			A_NOTE+="heard_rms=$v "
			;;
		mix\>*)
			wait_file_stable "$REC/$vid-mix.wav" || true
			v=$(rms_of "$REC/$vid-mix.wav")
			fcmp "$v" ">" "${tok#mix>}" || A_FAIL+="mix_rms=$v(want>${tok#mix>}) "
			A_NOTE+="mix_rms=$v "
			;;
		log~*)
			pat=${tok#log~}; pat=${pat//%VID%/$vid}; pat=${pat//%NUM%/${vid%%_*}}; pat=${pat//%NAME%/${vid#*_}}
			grep -qE -- "$pat" "$FULL_LOG" 2>/dev/null || A_FAIL+="log lacks /$pat/ "
			;;
		nolog~*)
			pat=${tok#nolog~}; pat=${pat//%VID%/$vid}; pat=${pat//%NUM%/${vid%%_*}}; pat=${pat//%NAME%/${vid#*_}}
			! grep -qE -- "$pat" "$FULL_LOG" 2>/dev/null || A_FAIL+="log has /$pat/ "
			;;
		alive) ast_alive || A_FAIL+="asterisk not answering CLI " ;;
		*) A_FAIL+="unknown assert '$tok' " ;;
		esac
	done
	unset IFS
	return 0
}

run_call_scenario() { # index [mock-override]
	local i=$1 name=${S_NAME[$1]} count=${S_COUNT[$1]} mock=${2:-${S_MOCK[$1]}}
	local exp_s=${S_STATUS[$i]} exp_c=${S_CAUSE[$i]} min=${S_MIN[$i]} max=${S_MAX[$i]}
	local vids=() vid line fail="" note="" t_launch0 t_launch1 deadline=$(( max / 1000 + 12 ))
	set_control "$mock"
	local scen_log
	if [ "$count" -le 1 ]; then
		next_vid "$name"; vid=$VID; vids=("$vid")
		scen_log=$LOGDIR/scenario-$vid.log
		{ echo "scenario=$name vid=$vid mock=$mock amdside=${S_AMD[$i]} farside=${S_FAR[$i]}"; } >"$scen_log"
		t_launch0=$(now_ms)
		originate "$vid" >>"$scen_log" 2>&1
		t_launch1=$(now_ms)
	else
		local k
		for k in $(seq 1 "$count"); do next_vid "$name"; vids+=("$VID"); done
		scen_log=$LOGDIR/scenario-${vids[0]}.log
		{ echo "scenario=$name burst of $count: ${vids[*]} mock=$mock"; } >"$scen_log"
		local pids=()
		t_launch0=$(now_ms)
		for vid in "${vids[@]}"; do originate "$vid" >>"$scen_log" 2>&1 & pids+=($!); done
		wait "${pids[@]}"
		t_launch1=$(now_ms)
		note+="launched $count in $((t_launch1 - t_launch0))ms "
		[ $((t_launch1 - t_launch0)) -le 1000 ] || fail+="originates took $((t_launch1 - t_launch0))ms (>1000) "
	fi
	local got=0 wall_max="" el_show="" sc_show="" first_line=""
	for vid in "${vids[@]}"; do
		if line=$(wait_result "$vid" "$deadline"); then
			got=$((got + 1))
			printf '%s\n' "$line" >>"$scen_log"
			parse_result "$line"
			[ -z "$first_line" ] && first_line=$line
			[ "$exp_s" != '*' ] && [ "$R_STATUS" != "$exp_s" ] && fail+="$vid status=${R_STATUS:-<empty>} "
			[ "$exp_c" != '*' ] && [ "$R_CAUSE" != "$exp_c" ] && fail+="$vid cause=${R_CAUSE:-<empty>} "
			if [ -n "$R_WALL" ]; then
				[ "$R_WALL" -ge "$min" ] && [ "$R_WALL" -le "$max" ] || fail+="$vid wall=${R_WALL}ms(not in $min..$max) "
				[ -z "$wall_max" ] || [ "$R_WALL" -gt "$wall_max" ] && wall_max=$R_WALL
			else
				fail+="$vid no T0/T1 timestamps "
			fi
		else
			fail+="$vid no result within ${deadline}s "
		fi
	done
	if [ -n "$first_line" ]; then
		parse_result "$first_line"
		sc_show="${R_STATUS:-?}/${R_CAUSE:-?}"; el_show=${R_ELAPSED:--}
		[ -n "$R_AUDIO" ] && note+="audio->end=${R_AUDIO}ms "
		[ -n "$R_RESP" ] && note+="resp='${R_RESP:0:40}' "
	fi
	[ "$count" -gt 1 ] && note+="results=$got/$count "
	# only single calls get the per-VID assertions; bursts get alive + count
	if [ "$count" -le 1 ] && [ "$got" = 1 ]; then
		check_asserts "${vids[0]}" "${S_ASSERTS[$i]}"
		fail+=$A_FAIL; note+=$A_NOTE
	elif [ "$count" -gt 1 ]; then
		ast_alive || fail+="asterisk not alive after burst "
		[ "$got" = "$count" ] || fail+="only $got/$count results "
	fi
	for vid in "${vids[@]}"; do wait_quiet "$vid" || note+="(channels of $vid lingered) "; done
	ast_alive || fail+="asterisk died "
	[ ${#vids[@]} -gt 0 ] && cp "$RESULTS" "$LOGDIR/results.txt" 2>/dev/null
	if [ -z "$fail" ]; then
		row PASS "$name" "$sc_show" "${wall_max:--}" "$el_show" "$(trim "$note")"
	else
		row FAIL "$name" "$sc_show" "${wall_max:--}" "$el_show" "$(trim "$fail") | $(trim "$note")"
	fi
	printf 'RESULT %s fail="%s" note="%s"\n' "$name" "$fail" "$note" >>"$scen_log"
}

# ---------------------------------------------------------------------------
# non-call checks
# ---------------------------------------------------------------------------
check_sounds() {
	local f missing="" d
	for f in amd-speech8 amd-speech1500 amd-beep amd-silence8 amd-prompt amd-prompt-short; do
		[ -s "$AST_RUN/var/lib/sounds/en/$f.wav" ] || missing+="$f "
	done
	d=$(dur_of "$AST_RUN/var/lib/sounds/en/amd-speech8.wav")
	if [ -n "$missing" ]; then row FAIL sounds - - - "missing: $missing"
	elif ! fcmp "$(rms_of "$AST_RUN/var/lib/sounds/en/amd-speech8.wav")" ">" 0.05; then row FAIL sounds - - - "amd-speech8.wav is silent"
	elif ! fcmp "$(rms_of "$AST_RUN/var/lib/sounds/en/amd-silence8.wav")" "<" 0.001; then row FAIL sounds - - - "amd-silence8.wav is not silent"
	else row PASS sounds - - - "6 wavs 8 kHz/16-bit, speech8 ${d}s rms=$(rms_of "$AST_RUN/var/lib/sounds/en/amd-speech8.wav"), sox RMS assertion works"
	fi
}

check_no_listeners() {
	command -v ss >/dev/null 2>&1 || { row SKIP no_listeners - - - "ss(8) not available"; return; }
	local l
	l=$(ss -Hltnup 2>/dev/null | grep -F "pid=$AST_PID," || true)
	if [ -n "$l" ]; then row FAIL no_listeners - - - "asterisk pid $AST_PID listens: $(echo "$l" | awk '{print $1, $5}' | tr '\n' ' ')"
	else row PASS no_listeners - - - "asterisk pid $AST_PID has no TCP/UDP listeners (only the CLI unix socket)"
	fi
}

check_mock_paths() {
	# every mock behaviour exercised with the amd.py-like client, in parallel, then protocol_test on the records
	local rec=$LOGDIR/mock-selftest.jsonl base="ws://127.0.0.1:$MOCK_PORT" out=$LOGDIR/mock-selftest.out fail="" pids=() n=0
	local -a specs=(
		"mc_human|/human?after=3|HUMAN|--timeout 6000|config,schedule,bytes,eof,close,result,chunks|--expect-chunks 4"
		"mc_machine|/machine?after=2|MACHINE||config,schedule,bytes,eof,close,result,chunks|--expect-chunks 3"
		"mc_amd|/amd?after=1|MACHINE||config,eof,close,result|"
		"mc_honeypot|/honeypot?after=1|HONEYPOT||config,eof,close,result|"
		"mc_json|/json?after=1|HUMAN||config,eof,close,result|"
		"mc_amdy|/amdy?after=3|HUMAN||config,schedule,bytes,eof,close,chunks|--expect-chunks 4"
		"mc_nothuman|/nothuman?after=2|MACHINE||config,schedule,eof,close,chunks|--expect-chunks 3"
		"mc_silent|/silent|NOTSURE|--timeout 1500 --grace 300|config,schedule,bytes,eof,close,noresult,chunks|--min-chunks 3"
		"mc_slow|/slow?handshake=2500|NOTSURE|--connect-timeout 800|-|"
		"mc_reject|/reject|NOTSURE||-|"
		"mc_close|/close?after=2|NOTSURE||config,close,noresult,chunks|--close-code 1011 --expect-chunks 2"
		"mc_big|/big?after=1|HUMAN||config,eof,close,result|"
		"mc_fragmented|/fragmented?after=1|HUMAN||config,eof,close,result|"
		"mc_ping|/ping?after=1|HUMAN||config,eof,close,result|"
		"mc_delay|/delay?reply=300&after=1|HUMAN||config,eof,close,result|"
		"mc_control|/|HUMAN||config,eof,close,result|"
		"mc_abort|/human?after=9|NOTSURE|--abort-after 2|config,close,chunks|--close-code 1006 --expect-chunks 2"
		"mc_phone|/human?after=0|HUMAN|--phone 3135551212 --country 1|config,chunks|--phone 3135551212 --country 1 --expect-chunks 1"
		"mc_noaudio|/human?after=0|NOTSURE|--no-audio --timeout 800|config,eof,close,chunks|--expect-chunks 0"
	)
	set_control "/human?after=1"      # for mc_control (path "/")
	# the selftest records go to their own file: restart-free by pointing the client at the same server and filtering by vid
	: >"$out"
	local spec name path exp copts checks popts t0; t0=$(now_ms)
	for spec in "${specs[@]}"; do
		IFS='|' read -r name path exp copts checks popts <<<"$spec"
		# shellcheck disable=SC2086
		"$PYTHON" "$TESTDIR/mock_client.py" --url "$base$path" --vid "$name" $copts >>"$out" 2>&1 &
		pids+=($!)
	done
	wait "${pids[@]}" 2>/dev/null || true
	sleep 0.5
	for spec in "${specs[@]}"; do
		IFS='|' read -r name path exp copts checks popts <<<"$spec"
		n=$((n + 1))
		local got; got=$(grep -F "\"vid\": \"$name\"" "$out" | "$PYTHON" -c 'import json,sys; l=sys.stdin.readline(); print(json.loads(l)["status"] if l.strip() else "?")' 2>/dev/null)
		[ "$got" = "$exp" ] || fail+="$name:client=$got(want $exp) "
		if [ "$checks" != "-" ]; then
			local v rc
			# shellcheck disable=SC2086
			v=$("$PYTHON" "$TESTDIR/protocol_test.py" --record "$LOGDIR/mock-record.jsonl" --vid "$name" --checks "$checks" $popts 2>&1); rc=$?
			printf '== %s\n%s\n' "$name" "$v" >>"$LOGDIR/mock-selftest.protocol.log"
			[ $rc = 0 ] || fail+="$name:proto[$(printf '%s' "$v" | grep '^FAIL' | cut -d: -f1 | sed 's/FAIL //' | tr '\n' ' ')] "
		fi
	done
	# handshake-only events for slow/reject must have been recorded
	grep -q '"event":"handshake".*"delay_ms":2500' "$LOGDIR/mock-record.jsonl" || fail+="no handshake record for /slow "
	grep -q '"event":"handshake".*"rejected":403' "$LOGDIR/mock-record.jsonl" || fail+="no handshake record for /reject "
	cp "$LOGDIR/mock-record.jsonl" "$rec" 2>/dev/null
	if [ -z "$fail" ]; then row PASS mock_paths - "$(( $(now_ms) - t0 ))" - "$n client runs (all paths, control file, abort->1006, phone/country) + protocol_test on every record"
	else row FAIL mock_paths - "$(( $(now_ms) - t0 ))" - "$fail"
	fi
}

check_cli_application() {
	local out; out=$(ast_cli 'core show application AMD_WS')
	printf '%s\n' "$out" >"$LOGDIR/cli-show-application.txt"
	if hasi "$out" 'No such application\|is not registered'; then
		row FAIL cli_show_application - - - "AMD_WS not registered: $(echo "$out" | head -1)"
	elif has "$out" 'AMD_WS' && [ "$(printf '%s\n' "$out" | wc -l)" -ge 5 ]; then
		row PASS cli_show_application - - - "$(printf '%s\n' "$out" | wc -l) lines; synopsis: $(printf '%s\n' "$out" | grep -A1 -i 'synopsis' | tail -1 | tr -s ' ' | cut -c1-60)"
	else
		row FAIL cli_show_application - - - "unexpected output ($(printf '%s\n' "$out" | wc -l) lines): $(echo "$out" | head -1)"
	fi
}

check_cli_settings() {
	local out; out=$(ast_cli 'amd_ws show settings')
	printf '%s\n' "$out" >"$LOGDIR/cli-show-settings.txt"
	if hasi "$out" 'No such command'; then
		row FAIL cli_show_settings - - - "'amd_ws show settings' is not a CLI command"
	elif hasi "$out" 'host' && hasi "$out" 'timeout'; then
		row PASS cli_show_settings - - - "$(printf '%s\n' "$out" | wc -l) lines, mentions host/timeout; db: $(printf '%s\n' "$out" | grep -i '^ *db' | head -1 | tr -s ' ')"
	else
		row FAIL cli_show_settings - - - "output lacks host/timeout: $(echo "$out" | head -2 | tr '\n' ' ')"
	fi
}

check_unload_cycle() {
	local pi; pi=$(scenario_index unload_probe) || { row SKIP unload_busy - - - "no unload_probe row in $SCENARIOS"; return; }
	local vid out line
	# 1. refused while a call is inside AMD_WS
	set_control "/silent"
	next_vid unload_probe; vid=$VID
	originate "$vid" >"$LOGDIR/scenario-$vid.log" 2>&1
	sleep 1.5
	out=$(ast_cli 'module unload app_amd_ws.so')
	if has "$out" 'Unable to unload'; then
		row PASS unload_busy_refused - - - "while $vid runs: '$(echo "$out" | head -1)'"
	else
		row FAIL unload_busy_refused - - - "expected 'Unable to unload resource', got '$(echo "$out" | head -1)'"
	fi
	if line=$(wait_result "$vid" 12); then
		parse_result "$line"
		printf '%s\n' "$line" >>"$LOGDIR/scenario-$vid.log"
		[ "$R_CAUSE" = AUDIO_TIMEOUT ] && [ "$R_STATUS" = NOTSURE ] || row FAIL unload_probe_result "$R_STATUS/$R_CAUSE" "$R_WALL" "$R_ELAPSED" "probe call did not finish with NOTSURE/AUDIO_TIMEOUT after the refused unload"
	else
		row FAIL unload_probe_result - - - "probe call $vid produced no result"
	fi
	wait_quiet "$vid" || true
	# 2. idle unload succeeds
	out=$(ast_cli 'module unload app_amd_ws.so')
	if has "$out" '^Unloaded'; then
		row PASS unload_idle - - - "'$(echo "$out" | head -1)'"
	else
		row FAIL unload_idle - - - "expected 'Unloaded app_amd_ws.so', got '$(echo "$out" | head -1)'"
	fi
	sleep 0.3
	out=$(ast_cli 'core show application AMD_WS')
	hasi "$out" 'No such application\|not registered' || row FAIL unload_unregistered - - - "AMD_WS still registered after unload"
	# 3. load again and make a call through it
	out=$(ast_cli 'module load app_amd_ws.so')
	if has "$out" '^Loaded'; then
		set_control "/human?after=1"
		next_vid unload_probe; vid=$VID
		originate "$vid" >"$LOGDIR/scenario-$vid.log" 2>&1
		if line=$(wait_result "$vid" 12); then
			parse_result "$line"
			if [ "$R_STATUS" = HUMAN ]; then row PASS load_again "$R_STATUS/$R_CAUSE" "$R_WALL" "$R_ELAPSED" "'$(echo "$out" | head -1)' then $vid -> HUMAN"
			else row FAIL load_again "$R_STATUS/$R_CAUSE" "$R_WALL" "$R_ELAPSED" "call after reload did not give HUMAN"; fi
		else
			row FAIL load_again - - - "no result for $vid after module load"
		fi
		wait_quiet "$vid" || true
	else
		row FAIL load_again - - - "expected 'Loaded app_amd_ws.so', got '$(echo "$out" | head -1)'"
	fi
	# 4. reload re-reads the config
	out=$(ast_cli 'module reload app_amd_ws.so')
	hasi "$out" 'error\|No such' && row FAIL module_reload - - - "'$(echo "$out" | head -1)'" || row PASS module_reload - - - "'$(echo "$out" | head -1 | tr -s ' ')'"
}

check_log_lines() { # the two mandatory ast_verb lines exist for AMD calls
	local n1 n2
	n1=$(grep -cE 'AMD_WS: .* vid=[0-9]{4}_[a-z0-9_]+ host=' "$FULL_LOG" 2>/dev/null || true)
	n2=$(grep -cE 'AMD_WS: .* status=[A-Z_]+ cause=[A-Z_]+ elapsed=[0-9]+ sent=[0-9]+ chunks=[0-9]+' "$FULL_LOG" 2>/dev/null || true)
	if [ "${n1:-0}" -gt 0 ] && [ "${n2:-0}" -gt 0 ]; then row PASS log_lines - - - "$n1 start lines, $n2 end lines (SPEC section 6 format)"
	else row FAIL log_lines - - - "start lines: ${n1:-0}, end lines: ${n2:-0} (expected the SPEC section 6 ast_verb lines)"
	fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	load_scenarios
	if [ "$LIST" = 1 ]; then
		printf '%-20s %-6s %-5s %-18s %-24s %s\n' NAME TAGS COUNT FARSIDE MOCK AMDSIDE
		local i; for i in "${!S_NAME[@]}"; do printf '%-20s %-6s %-5s %-18s %-24s %s\n' "${S_NAME[$i]}" "${S_TAGS[$i]}" "${S_COUNT[$i]}" "${S_FAR[$i]}" "${S_MOCK[$i]}" "${S_AMD[$i]}"; done
		echo "checks: sounds no_listeners mock_paths shutdown_clean (self); build_nomysql build_mysql cli_show_application cli_show_settings unload_busy_refused unload_idle load_again module_reload log_lines (amd)"
		exit 0
	fi
	mkdir -p "$LOGDIR"
	trap cleanup EXIT
	trap 'FINAL_RC=2; exit 2' INT TERM

	# preflight
	[ -x "$ASTERISK_BIN" ] || die "asterisk binary not found: $ASTERISK_BIN"
	ast_bin -V >/dev/null 2>&1 || die "$ASTERISK_BIN does not run (LD_LIBRARY_PATH=$AST_LD_LIBRARY_PATH?)"
	command -v sox >/dev/null || die "sox not installed"
	"$PYTHON" -c 'import websockets' 2>/dev/null || die "python websockets module missing"
	[ -d "$AST_MODULES_DIR" ] || die "module dir $AST_MODULES_DIR missing"
	log "asterisk: $(ast_bin -V) | modules: $AST_MODULES_DIR | mode=$MODE | logs: $LOGDIR"

	if [ "$MODE" = full ]; then
		build_module
		if [ "$MODULE_AVAILABLE" != 1 ]; then
			log "module unavailable: AMD_WS scenarios will be SKIPped (build it or run --selftest)"
			FINAL_RC=2
		fi
	fi

	prepare_rundir
	start_mock
	render_dialplan
	start_asterisk

	# environment checks
	local o
	selected sounds && check_sounds
	selected no_listeners && check_no_listeners
	if [ "$MODE" = full ] && [ "$MODULE_AVAILABLE" = 1 ]; then
		o=$(ast_cli 'module show like app_amd_ws'); has "$o" '1 modules loaded' || { row FAIL module_loaded - - - "app_amd_ws.so not loaded: $(grep -i 'app_amd_ws' "$FULL_LOG" | grep -iE 'error|undefined|refus|decline' | head -2 | tr '\n' ' ')"; }
		selected cli_show_application && check_cli_application
		selected cli_show_settings && check_cli_settings
	fi
	o=$(ast_cli 'module show like res_http_websocket'); has "$o" '1 modules loaded' || row FAIL res_http_websocket - - - "res_http_websocket.so not loaded"
	selected mock_paths && check_mock_paths

	# call scenarios
	local i tags
	for i in "${!S_NAME[@]}"; do
		tags=${S_TAGS[$i]}
		has_tag "$tags" probe && continue
		selected "${S_NAME[$i]}" || continue
		if has_tag "$tags" amd; then
			if [ "$MODE" = selftest ]; then continue; fi
			if [ "$MODULE_AVAILABLE" != 1 ]; then row SKIP "${S_NAME[$i]}" - - - "needs app_amd_ws.so"; continue; fi
		fi
		[ "$(($(date +%s) - SUITE_T0))" -gt "$SUITE_BUDGET_S" ] && { row FAIL suite_budget - - - "suite exceeded ${SUITE_BUDGET_S}s before ${S_NAME[$i]}"; break; }
		log "scenario ${S_NAME[$i]} (${S_FAR[$i]} -> ${S_AMD[$i]}; mock ${S_MOCK[$i]})"
		run_call_scenario "$i"
	done

	if [ "$MODE" = full ] && [ "$MODULE_AVAILABLE" = 1 ]; then
		selected log_lines && check_log_lines
		selected unload_busy && check_unload_cycle
	fi
	[ "$KEEP" = 1 ] || stop_asterisk
	local dt=$(($(date +%s) - SUITE_T0))
	[ "$dt" -le "$SUITE_BUDGET_S" ] || row FAIL suite_budget - - - "suite took ${dt}s > ${SUITE_BUDGET_S}s"
	log "done in ${dt}s"
}

main "$@"
