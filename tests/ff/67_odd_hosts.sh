#!/opt/homebrew/bin/bash
# odd host count (2026-11-19, Frank: "An iteration isn't done if one host gets left out."): an odd group's left-over
# host no longer sits the iteration out; it runs last, alone, with the group's first host (already tested), over the
# iteration's phases, its marker lines "wave:odd" and its phase_times rows <phase>-odd.
# checks: 7
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# hosts with a result per iteration, from the results' IPs (198.19.<rail>.<n>: host n)
perit() { bfile $1 iperf3_results.txt | awk '/^### / {split($2, a, ":"); it = a[2]; next} /Gbits\/sec/ {split($1, s, ","); split(s[1], x, "."); split(s[2], y, "."); h[it, x[4]]; h[it, y[4]]} END {for (k in h) {split(k, z, SUBSEP); n[z[1]]++}; for (i in n) print i, n[i]}' | sort; }

out=$(xrun o3 env FF_HOSTS=198.18.0.21-23 FF_ITER=1 timeout 200 $B $C 1); rc=$?
chk "3 hosts, FF_ITER=1: rc 0, COMPLETE hosts=3/3; the log names h21 running last with h22; pairs.txt 2 rows (h22 h23, h22 h21)" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3 ' <<<\"\$out\" && grep -q 'the left-over host runs last, alone, with a host this iteration already tested: h21 with h22' <<<\"\$out\" && [ \"\$(bfile o3 pairs.txt | tr '\n' '|')\" = '1 h22 h23|1 h22 h21|' ]" \
    "rc=$rc $(grep -E '^RESULT|left-over' <<<"$out" | tr '\n' '|') pairs=$(bfile o3 pairs.txt | tr '\n' '|')"
chk "results: phase:1 wave:odd and phase:2 wave:odd marker lines, each with h21's two runs; UDP results phase:U1 wave:odd" \
    "[ \$(bfile o3 iperf3_results.txt | awk '/^### iteration:1 phase:1 wave:odd\$/ {f = 1; next} /^### / {f = 0} f && /198\.19\.[12]\.21/' | wc -l) = 2 ] && [ \$(bfile o3 iperf3_results.txt | awk '/^### iteration:1 phase:2 wave:odd\$/ {f = 1; next} /^### / {f = 0} f && /198\.19\.[12]\.21/' | wc -l) = 2 ] && bfile o3 iperf3_udp_results.txt | grep -qx '### iteration:1 phase:U1 wave:odd'" \
    "$(bfile o3 iperf3_results.txt | grep '^###' | tr '\n' '|')"
pt=$(bfile o3 phase_times.txt)
chk "phase_times: the odd rows 1-odd 2-odd U1-odd U2-odd come after the main ones, the first odd start not before the last main end" \
    "[ \"\$(awk 'NR > 1 {print \$2}' <<<\"\$pt\" | tr '\n' ' ')\" = '1 2 U1 U2 1-odd 2-odd U1-odd U2-odd ' ] && [ \"\$(awk 'NR > 1 && \$2 !~ /odd/ {e = \$4} NR > 1 && \$2 ~ /odd/ && !s {s = \$3} END {print (s >= e) ? \"ok\" : \"no\"}' <<<\"\$pt\")\" = ok ]" "$(tr '\n' '|' <<<"$pt")"
# (e) even count: nothing changes
out=$(xrun e4 env FF_HOSTS=198.18.0.21-24 FF_ITER=1 FF_UDP=0 timeout 200 $B $C 1); rc=$?
chk "4 hosts (even): no odd line, no wave:odd marker, pairs.txt 2 rows, COMPLETE 4/4" \
    "[ $rc = 0 ] && ! grep -q 'Odd host count' <<<\"\$out\" && ! bfile e4 iperf3_results.txt | grep -q 'wave:odd' && [ \$(bfile e4 pairs.txt | wc -l) = 2 ] && grep -q '^RESULT coverage=COMPLETE hosts=4/4 ' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|Odd' <<<"$out" | tr '\n' '|')"
# (5) five hosts, two iterations: every host has a result in each iteration
out=$(xrun f5 env FF_HOSTS=198.18.0.21-25 FF_ITER=2 FF_UDP=0 timeout 200 $B $C 1); rc=$?
chk "5 hosts, FF_ITER=2: all 5 hosts have a result in iteration 1 and in iteration 2; 2 odd lines" \
    "[ \"\$(perit f5 | tr '\n' '|')\" = '1 5|2 5|' ] && [ \$(grep -c 'the left-over host runs last' <<<\"\$out\") = 2 ]" "rc=$rc per-iteration hosts: $(perit f5 | tr '\n' '|')"
# (s) no load: the left-over host's path checks run too
out=$(xrun s3 env FF_HOSTS=198.18.0.21-23 FF_ITER=1 FF_SKIP_IPERF=1 timeout 200 $B $C 1); rc=$?
chk "FF_SKIP_IPERF=1, 3 hosts: 'Path checks, odd host' line; COMPLETE hosts=3/3" "grep -q 'Path checks, odd host (egress route, ping, MTU no-fragment): 4 OK, 0 excluded' <<<\"\$out\" && grep -q '^RESULT coverage=COMPLETE hosts=3/3 ' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|odd host' <<<"$out" | tr '\n' '|')"
# (p) planted: the odd pass not called after the load phases (one line): the left-over host has no result again
perl -pe 's/^(\s*)odd_pass   # an odd group.s left-over host runs last.*$/$1:/' $C > $W/x_odd.sh
out=$(xrun po env FF_HOSTS=198.18.0.21-23 FF_ITER=1 timeout 200 $B $W/x_odd.sh 1)
chk "planted (one line: no odd pass after the phases): PARTIAL hosts=2/3, no wave:odd" "[ \$(diff $C $W/x_odd.sh | grep -c '^>') = 1 ] && grep -q '^RESULT coverage=PARTIAL hosts=2/3 ' <<<\"\$out\" && ! bfile po iperf3_results.txt | grep -q 'wave:odd'" "$(diff $C $W/x_odd.sh | head -n 3) $(grep '^RESULT' <<<"$out")"
finish
