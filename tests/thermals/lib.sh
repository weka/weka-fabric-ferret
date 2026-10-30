#!/opt/homebrew/bin/bash
# Shared setup for test_thermals.sh's sections (tests/NN_*.sh), run by harness_ferret's run_all.sh (10-26).
# A section starts with: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"   ($1 thermals_capture.sh, $2 fabric_ferret.sh)
# fake/ssh plays each target from $FAKE_TC/case.<target>; see its header for the cases.
[[ -n $1 && -n $2 ]] || { echo "usage: $0 <thermals_capture.sh> <fabric_ferret.sh>" >&2; exit 2; }
TC=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); FF=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
TIER=${TIER:-full}
B=/opt/homebrew/bin/bash; H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # tests/thermals: its fake/ and sections
AWKBIN=$H/../awkbin   # made by tests/lib.sh (the fabric_ferret groups) or tests/run: bsd/mawk/gawk links
W=$(mktemp -d "${TMPDIR:-/tmp}/tc_test.XXXX") || exit 2
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1: $2"; fail=$((fail+1)); }
# a check after a run that hit its timeout reports "TIMEOUT after N s", never what the cut-off run left behind;
# more than 3 arguments is a broken line (two chk calls run together), never a pass
chk() { if (( $# > 3 )); then bad "$1" "chk got $# arguments (a joined line?): '${4:0:60}'"
        elif [[ -s $W/timeout.note ]]; then bad "$1" "$(tail -n 1 "$W/timeout.note") (the run was cut off; check not evaluated)"
        elif eval "$2"; then ok "$1"; else bad "$1" "${3:-check failed}"; fi; }
# run <dir> VAR=... -- args: a capture in $W/<dir> with its own fake state; cases from CASES="target:case ..."; at most 180 s
run() {
    local d=$W/$1 rc; shift; mkdir -p "$d/fake" "$d/out"; rm -f "$W/timeout.note"
    local tc; for tc in $CASES; do echo "${tc#*:}" > "$d/fake/case.${tc%%:*}"; done
    ( cd "$d" && timeout 180 env PATH=$H/fake:${XPATH:+$XPATH:}$PATH FAKE_TC=$d/fake FF_OUT_DIR=$d/out "$@" 2>&1 ); rc=$?
    (( rc == 124 )) && echo "TIMEOUT after 180 s" >> "$W/timeout.note"; return $rc
}
jl() { cat "$W/$1"/out/*.jsonl 2>&1; }
# the reader as each tool ships it, through the fake: reader <script file> <case> <mode>
reader() {
    local d; d=$(mktemp -d "$W/rd.XXXXXX"); echo "$2" > $d/case.198.19.109.9   # mktemp: on 10-26 a $RANDOM-named dir was found already present once; HYPOTHESIS that two groups drew the same name
    ( source "$1"; FAKE_TC=$d $H/fake/ssh -l root 198.19.109.9 bash -s -- "$3" 60 <<<"$TEMP_SCRIPT" 2>&1 )
}
# rx <script> <case> [cached escalator]: the reader through the fake ssh as a non-root login; prints its @@ESC and
# @@IPMI (Inlet or none) lines, then "== esc: <the escalators' argv> secs: <seconds it took>"
rx() { local d s=$SECONDS; d=$(mktemp -d "$W/rx.XXXXXX"); echo "$2" > $d/case.198.19.164.1
       ( source "$1"; printf '%s\n' "$TEMP_SCRIPT" | FAKE_TC=$d $H/fake/ssh -l op 198.19.164.1 bash -s -- ipmi 5 "$3" ) 2>&1 | grep -E '^@@(ESC|IPMI) .* (Inlet_Temp|none) |^@@ESC '
       echo "== esc: $( if [ -e $d/esc_calls.log ]; then tr '\n' ';' < $d/esc_calls.log; else echo '(no escalator run)'; fi) secs: $(( SECONDS - s ))"; }
strip_time() { sed -E 's/"(time|start|end)":"[^"]*"/"\1":"T"/g; s/thermcap_[^ ]*Z\./thermcap_X./g'; }
# ptab <html> <type> <os|bmc>: that source's table on the type's page (10-26: the nav is by type, each type
# page an OS table and a BMC / IPMI table)
ptab() { sed -n "/<section class=\"panel\" id=\"p-$2\">/,/<\/section>/p" <<<"$1" | awk -v g="$3" '/<h3>/ { on = index($0, g == "os" ? "<h3>OS (" : "<h3>BMC / IPMI") > 0 } on'; }
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# finish: the section's total line (run_all.sh needs it); the work dir goes when every check passed
finish() { echo "---- $pass passed, $fail failed ($TIER)  (work dir $W$( (( fail == 0 )) && echo ', removed'))"
    (( fail == 0 )) && { cd "$H" && rm -rf "${W:?}"; }; [ $fail = 0 ]; exit $?; }
