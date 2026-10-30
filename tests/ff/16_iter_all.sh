#!/opt/homebrew/bin/bash
# FF_ITER=all: every directed NIC path once; repeat and partial-coverage messages
# checks: 9
# secs: 204
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# the smallest fleets that show each case (10-26: was 6 and 5 hosts, 10 iterations each, and 7 iterations of 4)
# each run's cut-off = 2x the run's time in a full `tests/run --full all` (a fresh clone at a machine load of ~10: ia 73 s,
# io 69 s, i5 31 s, i2 31 s; alone they take 24, 14, 6 and 7 s), rounded up to a ten, so a hang is reported at twice
# the expected, not at an arbitrary multiple. Sizing them on a lighter run (six groups) cut i2 off at 30 s.
out=$(xrun ia FF_HOSTS=198.18.0.21-24 FF_ITER=all timeout 150 $B $C 1)
chk "FF_ITER=all, 4 hosts: 6 iterations, 48 of 48 directed paths, each once" "grep -q 'Iteration 6 of 6' <<<\"\$out\" && grep -q 'Directed NIC paths: 48 of 48 planned' <<<\"\$out\" && grep -q 'Directed NIC paths planned: 48 of 48\$' <<<\"\$out\" && onceeach 48" "$(tcpflows | sort | uniq -c | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')"
chk "FF_ITER=all: second cycle logged as swapped" "grep -q 'Iterations 4-6 repeat the pairings with client and server swapped' <<<\"\$out\""
out=$(xrun io FF_HOSTS=198.18.0.21-23 FF_ITER=all timeout 140 $B $C 1)
chk "FF_ITER=all, 3 hosts (bye): 24 of 24 directed paths, each once" "grep -q 'Iteration 6 of 6' <<<\"\$out\" && onceeach 24" "$(tcpflows | wc -l)"
out=$(xrun i5 FF_HOSTS=198.18.0.21-22 FF_ITER=3 timeout 70 $B $C 1)
chk "past 2 x rounds: repeat logged (2 hosts, 3 iterations)" "grep -q 'Iterations past 2 repeat the pairings from the start' <<<\"\$out\""
out=$(xrun i2 FF_HOSTS=198.18.0.21-24 FF_ITER=2 timeout 70 $B $C 1)
chk "FF_ITER below 2 x rounds: partial directed coverage said" "grep -q 'Directed NIC paths: 16 of 48 planned (every direction on every NIC pair needs FF_ITER=6, or FF_ITER=all)' <<<\"\$out\""
# (was 12 (c)) the same 4-host, 2-iteration run: phase 2 direction per iteration A->B = B->A and one each way per pair;
# over 2 iterations the fixed host uses both NICs
r=$(bfile i2 iperf3_results.txt)
x=$(awk -F'[, ]+' '/^### / {split($2, a, ":"); split($3, b, ":"); it = a[2]; ph = b[2]; next} ph == 2 && /Gbits/ {
        s = substr($1, 1, 9); d = substr($2, 1, 9); split($1, p, "."); split($2, q, ".")
        k = p[4] < q[4] ? p[4] "-" q[4] : q[4] "-" p[4]; print it, (s == "198.19.1." ? "AB" : "BA"), k, p[4] (s == "198.19.1." ? "A" : "B") }' <<<"$r")
chk "phase 2: per iteration A->B = B->A (2+2)" "[ \"\$(awk '{print \$1, \$2}' <<<\"\$x\" | sort | uniq -c | awk '{print \$1}' | tr '\\n' ' ')\" = '2 2 2 2 ' ]" "$x"
chk "phase 2: per pair one each way" "[ \"\$(awk '{print \$1, \$3, \$2}' <<<\"\$x\" | sort -u | awk '{print \$1, \$2}' | uniq -c | awk '{print \$1}' | sort -u)\" = 2 ]" "$x"
chk "phase 2: fixed host sends from both NICs over 2 iterations" "[ \"\$(awk '\$4 ~ /^21/ {print \$4}' <<<\"\$x\" | sort -u | tr '\\n' ' ')\" = '21A 21B ' ]" "$x"
chk "phase 2 log line" "grep -q 'Phase 2: cross-rail, A->B and B->A at once' <<<\"\$out\""
finish
