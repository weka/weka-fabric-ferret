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
chk "FF_ITER=all, 4 hosts: 3 iterations (the ring's n-1 strides), 48 of 48 directed paths, each once" "grep -q 'Iteration 3 of 3' <<<\"\$out\" && grep -q 'Directed NIC paths: 48 of 48 planned' <<<\"\$out\" && grep -q 'Directed NIC paths planned: 48 of 48\$' <<<\"\$out\" && onceeach 48" "$(tcpflows | sort | uniq -c | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')"
chk "FF_ITER=all, 4 hosts: in every iteration's phase 1 every host sends one flow and receives one on each rail (the ring)" "[ -z \"\$(bfile ia iperf3_results.txt | awk '/^### / {split(\$2, a, \":\"); split(\$3, b, \":\"); k = a[2] \" \" b[2]; next} k ~ / 1\$/ && /Gbits/ {split(\$1, s, \",\"); t[k \" \" s[1] \" tx\"]++; t[k \" \" s[2] \" rx\"]++} END {for (x in t) if (t[x] != 1) print x, t[x]}')\" ] && [ \$(bfile ia iperf3_results.txt | awk '/^### iteration:[0-9]+ phase:1\$/ {f = 1; next} /^### / {f = 0} f && /Gbits/' | wc -l) = 24 ]" "$(bfile ia iperf3_results.txt | grep -c Gbits)"
out=$(xrun io FF_HOSTS=198.18.0.21-23 FF_ITER=all timeout 140 $B $C 1)
chk "FF_ITER=all, 3 hosts (odd: nobody sits out): 2 iterations, 24 of 24 directed paths, each once" "grep -q 'Iteration 2 of 2' <<<\"\$out\" && onceeach 24" "$(tcpflows | wc -l)"
out=$(xrun i5 FF_HOSTS=198.18.0.21-22 FF_ITER=3 timeout 70 $B $C 1)
chk "past n-1 strides: repeat logged (2 hosts, 3 iterations)" "grep -q 'Iterations past 1 repeat the ring.s strides from the start' <<<\"\$out\""
out=$(xrun i2 FF_HOSTS=198.18.0.21-24 FF_ITER=2 timeout 70 $B $C 1)
chk "FF_ITER below n-1: partial directed coverage said" "grep -q 'Directed NIC paths: 32 of 48 planned (every direction on every NIC pair needs FF_ITER=3, or FF_ITER=all)' <<<\"\$out\""
# the ring (2026-11-19): all = n-1 iterations, every host sends and receives on each rail in every iteration
# (was 12 (c)) the same 4-host, 2-iteration run: phase 2 direction per iteration A->B = B->A and one each way per pair;
# over 2 iterations the fixed host uses both NICs
r=$(bfile i2 iperf3_results.txt)
x=$(awk -F'[, ]+' '/^### / {split($2, a, ":"); split($3, b, ":"); it = a[2]; ph = b[2]; next} ph == 2 && /Gbits/ {
        s = substr($1, 1, 9); d = substr($2, 1, 9); split($1, p, "."); split($2, q, ".")
        k = p[4] < q[4] ? p[4] "-" q[4] : q[4] "-" p[4]; print it, (s == "198.19.1." ? "AB" : "BA"), k, p[4] (s == "198.19.1." ? "A" : "B") }' <<<"$r")
chk "phase 2: per iteration A->B = B->A (4+4, the ring's 4 links)" "[ \"\$(awk '{print \$1, \$2}' <<<\"\$x\" | sort | uniq -c | awk '{print \$1}' | tr '\\n' ' ')\" = '4 4 4 4 ' ]" "$x"
chk "phase 2: per pair one each way" "[ \"\$(awk '{print \$1, \$3, \$2}' <<<\"\$x\" | sort -u | awk '{print \$1, \$2}' | uniq -c | awk '{print \$1}' | sort -u)\" = 2 ]" "$x"
chk "phase 2: fixed host sends from both NICs over 2 iterations" "[ \"\$(awk '\$4 ~ /^21/ {print \$4}' <<<\"\$x\" | sort -u | tr '\\n' ' ')\" = '21A 21B ' ]" "$x"
chk "phase 2 log line" "grep -q 'Phase 2: cross-rail, A->B and B->A at once' <<<\"\$out\""
finish
