#!/opt/homebrew/bin/bash
# FF_SKIP_IPERF=1 runs every check but the bandwidth runs (a cluster whose WEKA I/O can't stop):
# no iperf3 started or killed, busy hosts and hosts without iperf3 allowed, every planned path checked,
# counters over one no-load window, system info kept, and the parser treats no throughput as by design.
# checks: 14
# secs: 29
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
tgz() { ls $W/$1/fabric_ferret_*.tgz | head -n1; }
member() { tar -xzOf $(tgz $1) --include="*/$2" 2>&1; }

xrun live FF_HOSTS=198.18.0.1-5 FF_ITER=2 FF_SKIP_IPERF=1 FAKE_BUSY=h3 FAKE_NO_IPERF=h2 timeout 120 $B $C 1 > $W/live.out; rc=$?
chk "live: busy host reported, run goes on" "grep -q '1 hosts in use per FF_BUSY_CHECK: fine with FF_SKIP_IPERF=1' $W/live.out && grep -q '^RESULT ' $W/live.out" "$(grep -i -m1 busy $W/live.out)"
chk "live: a host without iperf3 is still tested" "! grep -q 'iperf3 missing' $W/live.out && grep -q '^h2 ' <<<\"\$(member live host_list.txt)\""
chk "live: no iperf3 run, no server started or killed (in a run that finished)" "grep -q '^RESULT coverage=PARTIAL' $W/live.out && [ ! -e $FAKE_STATE/iperf_args.log ] && [ ! -e $FAKE_STATE/pkill.log ] && ! grep -q 'starting servers' $W/live.out"
chk "live: one observation window, in the last iteration" "[ \$(grep -c 'Observation window: 1s with no test load' $W/live.out) = 1 ] && grep -B30 'Observation window' $W/live.out | grep -q 'Iteration 2 of 2'"
chk "live: failed path checks recorded per phase" "member live paths_excluded.txt | awk '\$2 == 1 || \$2 == 2' | grep -q 'DOWN h4'" "$(member live paths_excluded.txt | head -n 3)"
chk "live: RESULT says iperf skipped, paths = checks passed" "grep -E '^RESULT coverage=PARTIAL hosts=5/5 paths=10/16 skipped=6 .* iperf=skipped' $W/live.out | grep -q ." "$(grep '^RESULT' $W/live.out)"
chk "live: summary says bandwidth not tested" "grep -q 'Bandwidth not tested (FF_SKIP_IPERF=1). Path checks (route, ping, MTU no-fragment): 10 of 16 planned OK' $W/live.out && grep -q 'with a passed path check: 5' $W/live.out"
chk "live: counters and system info still collected" "member live metadata.txt | grep -q -x 'iperf=skipped' && member live metadata.txt | grep -q -x 'sysinfo_hosts=5' && [ -n \"\$(member live host_counters.txt)\" ] && [ -n \"\$(member live fec_rates.txt)\" ]"
chk "live: host_rx has every host, CPU '-'" "[ \$(member live host_rx.txt | awk 'NR > 1 && \$9 == \"-\"' | wc -l) = 5 ]" "$(member live host_rx.txt | head -n 3)"

# a clean fleet, every directed path: COMPLETE and rc 0, and the parser renders it without a throughput problem
xrun clean FF_HOSTS=198.18.0.21-26 FF_ITER=all FF_SKIP_IPERF=1 timeout 120 $B $C 1 > $W/clean.out; rc=$?
chk "clean: FF_ITER=all COMPLETE rc=0" "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=6/6 paths=120/120 .*iperf=skipped' $W/clean.out" "rc=$rc $(grep '^RESULT' $W/clean.out)"
python3 $P $(tgz clean) $W/clean.html > $W/pc.out 2>&1; prc=$?
chk "parser: no-load bundle renders rc=0 with a note, no throughput problem" "[ $prc = 0 ] && grep -q 'NOTE: Bandwidth not tested (FF_SKIP_IPERF=1' $W/pc.out && ! grep -q 'PROBLEM' $W/pc.out" "rc=$prc $(grep -E 'PROBLEM|NOTE|Error' $W/pc.out | head -n 3)"

out=$(cd $W && FF_HOSTS=198.18.0.1 FF_SKIP_IPERF=1 FF_UDP=1 $B $C 2>&1); chk "FF_UDP=1 with FF_SKIP_IPERF=1 stops" "grep -q 'FF_UDP=1 is a load test; FF_SKIP_IPERF=1 sends no load' <<<\"\$out\"" "$out"
out=$(cd $W && FF_HOSTS=198.18.0.1 FF_SKIP_IPERF=yes $B $C 2>&1); chk "FF_SKIP_IPERF must be 0 or 1" "grep -q \"FF_SKIP_IPERF must be 0 or 1, got 'yes'\" <<<\"\$out\"" "$out"
out=$(PATH=$S/fake:$PATH FAKE_BUSY=h3 FF_HOSTS=198.18.0.1-5 FF_RAILS='198.19.1.0/24;198.19.2.0/24' timeout 60 $B $C 1 2>&1)
chk "load run: the busy stop names FF_SKIP_IPERF=1" "grep -q 'or set FF_SKIP_IPERF=1 to run every check but the bandwidth runs' <<<\"\$out\""
finish
