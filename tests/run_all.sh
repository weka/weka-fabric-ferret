#!/opt/homebrew/bin/bash
# Run the regression groups (tests/NN_*.sh) N at a time; print each group's PASS/FAIL lines in order, then one total.
# usage: run_all.sh <collector.sh> <parser.py> [--fast|--full] [-j N] [group ...]
#   --fast  only the groups marked "# tier: fast" (no full FF run; every commit); --full (default) every group (before a push)
#   -j N    groups at once (default 8: exec throughput on this Mac tops out there); -j 1 runs them one after another
#   group   a file name or its number (12 or 12_worst_of); default: every group of the tier
# test_thermals.sh runs its sections through this too: RA_TESTS=<its tests dir> RA_RESULTS=<its results dir>, with
# thermals_capture.sh and fabric_ferret.sh as the two files each section gets
# One suite at a time on this Mac (suite_lock.sh, shared with test_thermals.sh). The work dir is removed when every
# check passed, kept otherwise.
# bash 4.3+ (wait -n, declare -A): checked first, in bash 3 syntax
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } || {
    echo "run_all.sh: needs bash 4.3+ (this is bash $BASH_VERSION)" >&2; exit 2; }
B=/opt/homebrew/bin/bash
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # this tests/ dir
S=$H
die() { echo "run_all.sh: $*" >&2; exit 2; }
args=(); j=; tier=full
while (( $# )); do
    case $1 in
        -j) j=$2; shift 2 ;;
        -j*) j=${1#-j}; shift ;;
        --fast) tier=fast; shift ;;
        --full) tier=full; shift ;;
        *) args+=("$1"); shift ;;
    esac
done
(( ${#args[@]} >= 2 )) || die "usage: run_all.sh <collector.sh> <parser.py> [--fast|--full] [-j N] [group ...]"
C=${args[0]}; P=${args[1]}; sel=("${args[@]:2}")
[[ -f $C && -f $P ]] || die "collector or parser not found: $C $P"
: "${j:=8}"
[[ $j =~ ^[1-9][0-9]*$ ]] || die "-j needs a positive integer, got '$j'"
source "$S/suite_lock.sh"; suite_lock "run_all.sh $tier"

files=()
for f in "${RA_TESTS:-$H/ff}"/[0-9]*.sh; do   # RA_TESTS: another suite's group dir (tests/run tc: the thermals sections)
    g=$(basename "$f" .sh)
    [[ $tier == fast ]] && ! grep -qx '# tier: fast' "$f" && continue
    if (( ${#sel[@]} == 0 )); then files+=("$f"); continue; fi
    for s in "${sel[@]}"; do [[ $g == "$s" || $g == "$s"_* || $g.sh == "$s" ]] && { files+=("$f"); break; }; done
done
(( ${#files[@]} )) || die "no group matches: ${sel[*]}"

export RUN_DIR; RUN_DIR=$(mktemp -d "${RA_RESULTS:-$S}/regress.XXXX") || die "mktemp failed"   # RA_RESULTS: where that suite keeps them
# job control: each group runs in its own process group, with SIGINT not ignored; Ctrl-C here is passed on
# by hand. (tests/_signal.sh resets SIGINT itself, for a runner that was started in the background.)
set -m
trap 'for p in $(jobs -p); do kill -TERM -- -$p; done; exit 130' INT TERM HUP
export TIER=$tier   # a fast group may do less under --fast (02: a subset of the site sample); run alone it does the full work
echo "# $(uptime)" | tee "$RUN_DIR/result.txt"   # the load at the start: the cut-offs are 2x figures taken under a 1-minute load below 4
t0=$EPOCHREALTIME
# longest first (10-26): each group's `# secs: N` is its time alone (5 when absent), so the long ones don't start
# late and set the tail; results are still reported in name order
launch=(); while IFS=$'\t' read -r _ f; do launch+=("$f"); done < <(for f in "${files[@]}"; do
    n=$(sed -n 's/^# secs: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1); printf '%s\t%s\n' "${n:-5}" "$f"; done | sort -t $'\t' -k1,1nr -k2,2)
for f in "${launch[@]}"; do
    while (( $(jobs -rp | wc -l) >= j )); do wait -n; done
    g=$(basename "$f" .sh)
    ( s=$EPOCHREALTIME; $B "$f" "$C" "$P" > "$RUN_DIR/$g.out" 2>&1; rc=$?
      e=$EPOCHREALTIME; echo "$rc $(awk -v a=$s -v b=$e 'BEGIN {printf "%.1f", b - a}') $s $e" > "$RUN_DIR/$g.rc" ) &   # rc secs start end
done
wait

pass=0; fail=0; badg=(); hfail=(); written=0; unchanged=0; skipped=()
for f in "${files[@]}"; do
    g=$(basename "$f" .sh); o=$RUN_DIR/$g.out
    read -r rc secs _ < "$RUN_DIR/$g.rc"
    np=$(grep -c '^PASS  ' "$o"); nf=$(grep -c '^FAIL  ' "$o"); nw=$(grep -c '^WRITTEN  ' "$o"); nu=$(grep -c '^UNCHANGED  ' "$o")
    # a group whose "# needs:" is unmet says so as its only line (lib.sh): counted apart, by name, never as passed
    if [ "$rc" = 0 ] && (( np + nf == 0 )) && [ "$(grep -c '' "$o")" = 1 ] && grep -q "^SKIPPED  *$g: needs " "$o"; then
        echo "== $g  SKIPPED: $(sed 's/^SKIPPED  *[^:]*: //' "$o")"; skipped+=("$g"); continue
    fi
    other=$(grep -c -v -E '^(PASS|FAIL|WRITTEN|UNCHANGED)  |^---- ' "$o")
    echo "== $g  ${secs}s  $np passed, $nf failed$( (( nw + nu )) && echo ", $nw fixtures WRITTEN, $nu unchanged")$( (( other )) && echo "  ($other other lines in $o)")"
    grep -E '^(PASS|FAIL|WRITTEN|UNCHANGED)  ' "$o"; written=$(( written + nw )); unchanged=$(( unchanged + nu ))
    # every group states how many checks it runs (# checks: N, 10-26): a check that went silent (joined line,
    # commented out, early exit, empty loop) shows as a count that differs; change N on purpose when a check comes or goes
    want=$(sed -n 's/^# checks: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
    if [ -z "$want" ]; then echo "FAIL  $g: no '# checks: N' line in its header"; nf=$((nf + 1))
    elif (( np + nf != want )); then echo "FAIL  $g: ran $((np + nf)) checks, its header says # checks: $want"; nf=$((nf + 1)); fi
    # a group that died early (no total line, or rc without a FAIL) is a failure too
    if ! grep -q '^---- ' "$o" || { [ "$rc" != 0 ] && [ "$nf" = 0 ]; }; then
        hfail+=("FAIL  $g: group exited rc=$rc without its own total or a FAIL line (see $o)"); echo "${hfail[-1]}"; nf=$((nf + 1))
    fi
    # a shell or awk syntax error anywhere in a group's output is a broken test (a failure message that never
    # rendered, say), even when every check passed
    if grep -q -E 'syntax error|command not found|unbound variable' "$o"; then
        hfail+=("FAIL  $g: errors in the group's own output: $(grep -c -E 'syntax error|command not found|unbound variable' "$o") line(s), first: $(grep -m1 -E 'syntax error|command not found|unbound variable' "$o")"); echo "${hfail[-1]}"; nf=$((nf + 1))
    fi
    pass=$((pass + np)); fail=$((fail + nf)); (( nf )) && badg+=("$g")
done
wall=$(awk -v a=$t0 -v b=$EPOCHREALTIME 'BEGIN {printf "%.1f", b - a}')
# result.txt carries the harness's own FAIL lines too (a group without a total, errors in its output), so its FAIL
# lines plus the groups' .out FAIL lines account for every failure the total counts
{ (( ${#hfail[@]} )) && printf '%s\n' "${hfail[@]}"
  for g in "${skipped[@]}"; do grep "^SKIPPED " "$RUN_DIR/$g.out"; done
  echo "# ${#files[@]} groups ($tier), -j $j, wall ${wall}s$( (( ${#badg[@]} )) && echo "; failed groups: ${badg[*]}")"
  echo "---- $pass passed, $fail failed$( (( ${#skipped[@]} )) && echo ", ${#skipped[@]} skipped (${skipped[*]})")$( (( written + unchanged )) && echo ", $written FIXTURES WRITTEN, $unchanged unchanged: a regeneration run, not a passing one")  (results $RUN_DIR: <group>.out, <group>.rc = rc secs start end)"; } | tee -a "$RUN_DIR/result.txt"
# every check passed: the groups' work dirs go (bundles, fake state), the .out/.rc results stay
if (( fail == 0 )); then for w in "$RUN_DIR"/*/; do rm -rf "${w:?}"; done; fi
(( written + unchanged )) && exit 3   # a regeneration run skips the freshness checks, so it never passes
[ $fail = 0 ]
