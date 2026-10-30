#!/opt/homebrew/bin/bash
# fake cluster end to end under mawk and gawk, then the parser on that run
# checks: 16
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# --- fake cluster end to end under mawk and gawk; the bsd-awk run is golden-B (50), with the same checks (10-26) ---
for v in mawk gawk; do
    fresh; cd $W && rm -f fabric_ferret_*.tgz
    out=$(PATH=$S/awkbin/$v:$S/fake:$PATH FF_UDP=1 FF_UDP_DURATION=1 FF_TOS=106 FF_HOSTS=198.18.0.1-8 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=2 timeout 180 $B $C 1 2>&1); rc=$?
    chk "fake run awk=$v rc ok" "[ $rc = 3 ]" "rc=$rc"
    chk "fake awk=$v run.log in tarball" "tar xzf \"\$(ls $W/fabric_ferret_*.tgz | head -n1)\" -O --include='*/run.log' | grep -q '# Begin'"
    # 232 (was 189): a phase 2 pair now uses one NIC per host, so h4 (B down) and h5 (A MTU 1500) still run cross on the other NIC
    chk "fake awk=$v unaccounted 232" "grep -q 'unaccounted 232' <<<\"\$out\" && grep -q 'unaccounted beyond it (likely fabric): 232' <<<\"\$out\"" "$(grep 'Lost datagrams' <<<"$out")"
    chk "fake awk=$v pause counter seen" "grep -q 'rx_prio3_pause' <<<\"\$out\""
    chk "fake awk=$v traffic by priority per rail" "grep -q 'Traffic by priority in iteration 1 (rx+tx bytes): rail A: prio3 42.0GB' <<<\"\$out\"" "$(grep 'Traffic by priority' <<<"$out" | head -n1)"
    chk "fake awk=$v RDMA counter rose (packets name kept)" "grep -q -E 'h1_enp5s0np0 +rdma:np_ecn_marked_roce_packets +42' <<<\"\$out\""
    t=$(ls $W/fabric_ferret_*.tgz 2>&1 | head -n1)
    chk "fake awk=$v tarball" "[ -s \"$t\" ]"
done
out=$(cd $W && python3 $P "$t" "$W/fake.html" 2>&1); rc=$?
chk "parser on fake run" "{ [ $rc = 3 ]; } && grep -q 'unaccounted beyond expected (likely fabric) 232' $W/fake.html" "rc=$rc $out"
# moved here from the mixed-rails block: it reads this group's fake.html
chk "uniform rails: no per-rail note" "! grep -q 'rails differ' $W/fake.html"
finish
