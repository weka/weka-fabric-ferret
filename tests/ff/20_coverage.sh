#!/opt/homebrew/bin/bash
# coverage verdicts (COMPLETE/PARTIAL/NONE) and the fail-loud parser
# checks: 11
# secs: 90
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FF_HOSTS=198.18.0.1,198.18.0.2 frun); chk "clean pair COMPLETE rc=0" "grep -q 'coverage=COMPLETE hosts=2/2' <<<\"\$out\" && grep -q 'rc=0' <<<\"\$out\"" "$out"
t=$(ls $W/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/v2c.html > $W/p.out 2>&1; rc=$?; chk "parser clean rc=0" "[ $rc = 0 ]" "rc=$rc"
out=$(FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3,198.18.0.6 frun); chk "explicit list w/ unreachable PARTIAL rc=3" "grep -q 'coverage=PARTIAL hosts=3/4' <<<\"\$out\" && grep -q 'rc=3' <<<\"\$out\"" "$out"
# the range-with-a-down-rail PARTIAL run (198.18.0.1-8) and its parser banner moved to 50_golden_B.sh (10-26)
out=$(FAKE_IPERF_FAIL=1 FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 frunfull); rc=$?
chk "all runs fail NONE rc=4" "grep -q 'coverage=NONE' <<<\"\$out\" && [ $rc = 4 ]" "rc=$rc $(tail -n 1 <<<"$out")"
# the failed runs grouped by iperf3's reason (10-27 run: 138 "No route to host" to 48 destinations, read by hand):
# after the phase, a WARNING with the count and one line per reason; the summary repeats it over the whole run
n=$(grep -oE '^# WARNING: [0-9]+ runs in phase 1 returned no result \(lines with ERROR above\):$' <<<"$out" | grep -oE '[0-9]+' | head -n 1)
h=$(grep -E '^#   [0-9]+ x "unable to connect to server: Connection refused" to [0-9]+ destinations? \(198\.19\.[12]\.[12]( 198\.19\.[12]\.[12])*\)$' <<<"$out" | head -n 1)
chk "phase 1: the WARNING ends with a colon and the next line groups its $n runs under iperf3's reason with the destinations" \
    "[ -n \"\$n\" ] && [ \"\$(grep -A1 'runs in phase 1 returned no result' <<<\"\$out\" | tail -n 1)\" = \"\$h\" ] && [ \"\$(awk '{print \$2}' <<<\"\$h\")\" = \"\$n\" ]" "n=$n h=$h"
t=$(ls $W/fabric_ferret_*.tgz | head -n 1); te=$(tar -xzOf "$t" --include='*/iperf3_results.txt' | grep -c ',ERROR')
chk "summary: 'Runs with no result: $te' (= the ERROR rows of iperf3_results.txt) carries the same histogram, indented" \
    "grep -q \"^  Runs with no result: $te (iperf3's reason, runs, destinations):\$\" <<<\"\$out\" && grep -qE '^    $te x \"unable to connect to server: Connection refused\" to [0-9]+ destinations? \(' <<<\"\$out\"" "$(grep -A1 'Runs with no result' <<<"$out")"
python3 $P $t $W/fail.html > $W/pf.out 2>&1
chk "dashboard: a 'Runs with no result' card with the same count and reason (the parser reads iperf3_results.txt, not run.log)" \
    "grep -q \"Runs with no result — $te runs, by iperf3's reason\" $W/fail.html && grep -q '<td>unable to connect to server: Connection refused</td>' $W/fail.html" "$(grep -o 'Runs with no result[^<]*' $W/fail.html | head -n 1)"
# one destination refuses (as a host firewall does: No route to host), TCP and UDP; the other runs still count
out=$(FAKE_IPERF_NOROUTE=198.19.1.2 FF_UDP=1 FF_UDP_DURATION=1 FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3 FF_ITER=1 frunfull); rc=$?
chk "one destination unreachable: PARTIAL rc=3, the reason line names it as the only destination" \
    "[ $rc = 3 ] && grep -q 'coverage=PARTIAL' <<<\"\$out\" && grep -qE '^#   [0-9]+ x \"unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: No route to host\" to 1 destination \(198\.19\.1\.2\)$' <<<\"\$out\"" "rc=$rc $(grep -E 'No route|RESULT' <<<"$out" | head -n 3)"
t=$(ls $W/fabric_ferret_*.tgz | head -n 1); ok=$(tar -xzOf "$t" --include='*/iperf3_results.txt' | grep -c 'Gbits/sec'); ne=$(tar -xzOf "$t" --include='*/iperf3_results.txt' | grep -c ',ERROR')
chk "control: the other runs have results ($ok Gbits/sec rows beside $ne ERROR rows) and the summary count is the ERROR rows" "[ $ok -gt 0 ] && [ $ne -gt 0 ] && grep -q \"^  Runs with no result: $ne (iperf3's reason\" <<<\"\$out\"" "ok=$ok ne=$ne"
ue=$(tar -xzOf "$t" --include='*/iperf3_udp_results.txt' | grep -c ',ERROR')
chk "UDP phase (U1 or U2, whichever pairs to 198.19.1.2): the same WARNING, the reason line after it, the UDP summary count = $ue" \
    "[ $ue -gt 0 ] && grep -A1 -E '^# WARNING: [0-9]+ UDP runs in phase U[12] returned no result \(lines with ERROR above\):$' <<<\"\$out\" | tail -n 1 | grep -q '^#   1 x \"unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: No route to host\" to 1 destination (198\.19\.1\.2)$' && grep -q \"^  UDP runs with no result: $ue (iperf3's reason, runs, destinations):\$\" <<<\"\$out\"" "ue=$ue $(grep -E -A1 'UDP runs' <<<"$out" | cut -c1-120 | tr '\n' '|')"
out=$(FAKE_NO_DROPS=1 FF_HOSTS=198.18.0.1,198.18.0.2 frun); t=$(ls $W/fabric_ferret_*.tgz | head -n1)
python3 $P $t $W/v2d.html > $W/p.out 2>&1; rc=$?
chk "unread drops -> unknown + rc=3" "[ $rc = 3 ] && grep -q 'unknown, not zero' $W/v2d.html" "rc=$rc"
finish
