#!/opt/homebrew/bin/bash
# rails not routed to each other; FF_CROSS_RAIL
# checks: 7
# secs: 55
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# rails not routed to each other: counted by default (missing routes can be the fault); only FF_CROSS_RAIL=0 drops phase 2
fresh; mkdir -p $W/xr; out=$(cd $W/xr && PATH=$S/fake:$PATH FAKE_NOXROUTE=1 FF_HOSTS=198.18.0.1-3 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=3 timeout 120 $B $C 1 2>&1); rc=$?
chk "unrouted rails: warning logged" "grep -q 'WARNING: rails are not routed to each other (all 2 A<->B path checks failed on routing' <<<\"\$out\""
chk "unrouted rails by default: still PARTIAL rc 3, cross_rail=unrouted" "[ $rc = 3 ] && grep -q '^RESULT coverage=PARTIAL hosts=3/3 paths=6/12 skipped=6 no_result=0 cross_rail=unrouted' <<<\"\$out\"" "rc=$rc $(grep '^RESULT' <<<"$out")"
t=$(ls $W/xr/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/xr.html > $W/p.out 2>&1; rc=$?
chk "unrouted rails: parser rc 3 + note" "[ $rc = 3 ] && grep -q 'Rails not routed to each other' $W/xr.html" "rc=$rc"
out=$(cd $W/xr && PATH=$S/fake:$PATH FAKE_NOXROUTE=1 FF_CROSS_RAIL=1 FF_HOSTS=198.18.0.1-3 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=3 timeout 120 $B $C 1 2>&1); rc=$?
chk "FF_CROSS_RAIL=1: unrouted counts, PARTIAL rc 3" "[ $rc = 3 ] && grep -q '^RESULT coverage=PARTIAL hosts=3/3 paths=6/12 skipped=6' <<<\"\$out\"" "rc=$rc"
out=$(cd $W/xr && PATH=$S/fake:$PATH FF_CROSS_RAIL=0 FF_HOSTS=198.18.0.1-3 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=3 timeout 120 $B $C 1 2>&1); rc=$?
chk "FF_CROSS_RAIL=0: phase 2 off, COMPLETE" "[ $rc = 0 ] && grep -q 'cross_rail=off' <<<\"\$out\" && ! grep -q 'Phase 2: cross-rail' <<<\"\$out\" && grep -q 'Phase 2: skipped' <<<\"\$out\"" "rc=$rc"
# its positive control (a cross-on run prints 'Cross-rail total') is in 50_golden_B.sh
chk "FF_CROSS_RAIL=0: no cross-rail total (was 12)" "! grep -q 'Cross-rail total' <<<\"\$out\" && grep -q 'Phase 2: skipped' <<<\"\$out\""
out=$(FF_CROSS_RAIL=2 FF_HOSTS=198.18.0.1 $B $C 1 2>&1); chk "FF_CROSS_RAIL=2 rejected" "grep -q 'FF_CROSS_RAIL must be 0 or 1' <<<\"\$out\""
finish
