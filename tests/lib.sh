#!/opt/homebrew/bin/bash
# Shared setup and helpers for tests/*.sh. A group starts with: source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# Each group gets its own work dir W and fake state dir FAKE_STATE, so groups can run at once.
[[ -n $1 && -n $2 ]] || { echo "usage: $0 <collector.sh> <parser.py>" >&2; exit 2; }
C=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); P=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
S=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # this tests/ dir: fake/, fixtures/, rows.js, the unit drivers
B=/opt/homebrew/bin/bash
H=$S
G=$(basename "$0" .sh)
# Site data (a real cluster's sample, never in the repo): the groups that read it say "# needs: site-data" and take it from
# FFT_SITE_DATA; absent, they are SKIPPED by name (never silently green). Other "# needs:" words are commands on PATH.
SITE=${FFT_SITE_DATA:-$HOME/claude/fsLab/harness_ferret}
# the site's names, subnets, file names and counts live in its own site_vars.sh (exported: the unit drivers read them too)
if [[ -r $SITE/site_vars.sh ]]; then set -a; source "$SITE/site_vars.sh"; set +a; fi
for need in $(sed -n 's/^# needs: //p' "$0"); do
    case $need in site-data) [[ -d $SITE/base ]] ;; lab-runs) [[ -d ${FFT_LAB_RUNS:-$HOME/claude/fsLab/runs} ]] ;; *) [[ -n $(command -v "$need") ]] ;; esac || { echo "SKIPPED $G: needs $need"; exit 0; }
done
# awkbin/<name>/awk: the three awks by one name each, made here when the awk exists (not tracked)
for a in bsd:/usr/bin/awk mawk:"$(command -v mawk)" gawk:"$(command -v gawk)"; do
    [[ -x ${a#*:} && ! -e $S/awkbin/${a%%:*}/awk ]] && { mkdir -p "$S/awkbin/${a%%:*}" && ln -s "${a#*:}" "$S/awkbin/${a%%:*}/awk"; }
done
# RUN_DIR: set by run_all.sh, so one run's groups share a parent dir. The work dir carries only the group
# number: the collector prints the bundle's absolute path, and a word like "uplinks" there trips negative greps.
if [[ -n $RUN_DIR ]]; then W=$(mktemp -d "$RUN_DIR/${G%%_*}.XXXX"); else W=$(mktemp -d "$S/regress.${G%%_*}.XXXX"); fi || exit 2
export FAKE_STATE=$W/fake; mkdir -p "$FAKE_STATE" || exit 2
cd "$W" || exit 2
d=$(ls -d $SITE/base/dp_validation_* 2>&1 | head -n 1)   # the site sample's extracted dir (site-data groups only)
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1: $2"; fail=$((fail+1)); }
# a check after a run that hit its timeout reports "TIMEOUT after N s", never what the cut-off run left behind
# chk <name> <test> [detail]: more than 3 arguments is a broken line (two chk calls run together), never a pass
chk() { if (( $# > 3 )); then bad "$1" "chk got $# arguments (a joined line?): '${4:0:60}'"
        elif [[ -s $W/timeout.note ]]; then bad "$1" "$(tail -n 1 "$W/timeout.note") (the run was cut off; check not evaluated)"
        elif eval "$2"; then ok "$1"; else bad "$1" "${3:-check failed}"; fi; }
# timeout N cmd...: the real timeout; a cut-off (rc 124) is noted for chk. xrun notes its own (env runs the binary).
timeout() { rm -f "$W/timeout.note"; command timeout "$@"; local rc=$?; (( rc == 124 )) && echo "TIMEOUT after $1 s" >> "$W/timeout.note"; return $rc; }
tnote() { local rc=$1 n=; shift; (( rc == 124 )) || return 0; while (( $# )); do [[ $1 == timeout ]] && { n=$2; break; }; shift; done; echo "TIMEOUT after ${n:-?} s" >> "$W/timeout.note"; }
fresh() { rm -f "$W/timeout.note" $FAKE_STATE/drops.* $FAKE_STATE/carrier.* $FAKE_STATE/prio.* $FAKE_STATE/udph.* $FAKE_STATE/hostctr.* $FAKE_STATE/bufd.* $FAKE_STATE/tx.* $FAKE_STATE/temp.* $FAKE_STATE/pkill.log $FAKE_STATE/iperf_args.log $FAKE_STATE/listen.* $FAKE_STATE/iperf_refused.log; }
# run alone (no run_all.sh): the work dir goes when every check passed
finish() { echo "---- $pass passed, $fail failed  (work dir $W$( [[ -z $RUN_DIR && $fail = 0 ]] && echo ', removed'))"
           [[ -z $RUN_DIR && $fail = 0 ]] && { cd "$S" && rm -rf "${W:?}"; }; [ $fail = 0 ]; exit; }

# run the collector (or $O) in $W/<dir> on the fake rails: xrun <dir> VAR=... cmd...
xrun() { fresh; mkdir -p $W/$1; ( cd $W/$1 && rm -f fabric_ferret_*; shift; env PATH=$S/fake:$PATH FF_RAILS='198.19.1.0/24;198.19.2.0/24' "$@" 2>&1 ); local rc=$?; tnote $rc "$@"; return $rc; }
hrows() { node $H/rows.js "$1" 2>&1; }
# the collector at ec6addf (before worst-of Status and two-way phase 2): positive control, as $O
# $O predates FF_RAILS 'a;b': every run of $O passes FF_RAILS=a,b itself
tcpflows() { grep -v '^UDP' $FAKE_STATE/iperf_args.log | awk '{print $1, $2}'; }
onceeach() { tcpflows | sort | uniq -c | awk -v n=$1 '$1 != 1 {bad++} END {exit !(NR == n && !bad)}'; }
wavebal() { tar -xzOf $(ls $W/$1/fabric_ferret_*.tgz | head -n1) --include='*iperf3_results.txt' 2>&1 | awk -v m=$2 '
    /^### / { w = ($4 ~ /^wave:/) ? $2 $4 : ""; next }
    w != "" { split($1, f, ","); split(f[1], s, "."); split(f[2], d, "."); if (s[3] != d[3]) { n[w, s[3] d[3]]++; ws[w] = 1 } }
    END { for (w in ws) { k++; if (n[w, "12"] != n[w, "21"] || n[w, "12"] + n[w, "21"] > m) bad++ } print k + 0, bad + 0 }'; }
# frun/frunfull run in $W itself: frunfull prints the whole log, frun its last line plus rc=
frunfull() { fresh; cd $W && rm -f fabric_ferret_*.tgz; PATH=$S/fake:$PATH FF_ITER=${FF_ITER:-2} FF_RAILS='198.19.1.0/24;198.19.2.0/24' timeout 180 $B $C 1 2>&1; }
frun() { fresh; cd $W && rm -f fabric_ferret_*.tgz; PATH=$S/fake:$PATH FF_ITER=2 FF_RAILS='198.19.1.0/24;198.19.2.0/24' timeout 120 $B $C 1 2>&1 | tail -n 1; echo "rc=${PIPESTATUS[0]}"; }
# v3 groups: a run dir's bundle, one bundle member, a member's non-blank header line, the parser on a run dir's bundle
bundle() { local f=( $W/$1/fabric_ferret_*.tgz ); [[ -f ${f[0]} ]] && echo "${f[0]}"; }
bfile() { local t; t=$(bundle $1) || { echo "no bundle in $W/$1"; return 1; }; tar -xzOf "$t" --include="*/$2" 2>&1; }
bhead() { bfile $1 $2 | awk 'NF {$1 = $1; print; exit}'; }
# FIXTURE_UPDATE: fxupdate <run> <fixture dir> <label> <member...> writes a member (raw, as the bundle has it) only when
# the group's norm() of it differs from the stored one, so order and timing alone never churn a fixture (10-26)
fxupdate() { local r=$1 fx=$2 l=$3 m; shift 3; mkdir -p "$fx"
    for m; do
        if [ -e "$fx/$m" ] && [ "$(bfile $r $m | norm $m)" = "$(norm $m < "$fx/$m")" ]; then echo "UNCHANGED  $l fixture $fx/$m (order/timing only)"
        else bfile $r $m > "$fx/$m"; echo "WRITTEN  $l fixture $fx/$m ($(wc -l < "$fx/$m" | tr -d ' ') lines)"; fi
    done; }
render() { local t; t=$(bundle $1) || { echo "no bundle in $W/$1" > $W/$1.pout; return 9; }; python3 $P "$t" $W/$1.html > $W/$1.pout 2>&1; }
# distinct client flow keys from iperf_args.log: "<client_ip> <backend rail octet> c2b|b2c"
cflows() { grep -v '^UDP' $FAKE_STATE/iperf_args.log 2>&1 | awk '$1 ~ /^198\.19\.1[01]\./ {split($2, d, "."); print $1, d[3], "c2b"} $2 ~ /^198\.19\.1[01]\./ {split($1, s, "."); print $2, s[3], "b2c"}' | sort -u; }
