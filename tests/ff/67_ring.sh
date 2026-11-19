#!/opt/homebrew/bin/bash
# the ring (2026-11-19, the operator: "the ring replaces the pairs"): within a rail group, iteration t runs host i -> host
# i+k, k = 1 + t mod (n-1), so every host is tested in every iteration at any host count, every rail NIC sends one run and
# receives one in each phase, and n-1 iterations reach every directed pair. The ring's order is shuffled once per run
# (FF_SHUFFLE=1, the default; lib.sh sets 0 so the other groups stay deterministic).
# checks: 7
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# sr <run>: per iteration and phase, each rail IP's runs sent and received, "<iteration:N phase:P> <ip> <tx> <rx>"
sr() { bfile $1 iperf3_results.txt | awk '/^### / {ph = $2 " " $3; next} /Gbits\/sec/ {split($1, s, ","); k[ph " " s[1]]; k[ph " " s[2]]; tx[ph " " s[1]]++; rx[ph " " s[2]]++} END {for (x in k) print x, tx[x] + 0, rx[x] + 0}' | sort; }
# one1 <run> <ips per phase>: every phase has that many IPs, each sending 1 and receiving 1; prints "ok" or the bad rows
one1() { sr $1 | awk -v want=$2 '{n[$1 " " $2]++} $4 != 1 || $5 != 1 {print "bad:", $0} END {for (p in n) if (n[p] != want) print "phase", p, "has", n[p], "IPs"; if (!length(n)) print "no phases"}' | sort | awk 'END {if (!NR) print "ok"} {print}'; }
# perit <run>: hosts with a result per iteration (198.19.<rail>.<n>: host n)
perit() { bfile $1 iperf3_results.txt | awk '/^### / {split($2, a, ":"); it = a[2]; next} /Gbits\/sec/ {split($1, s, ","); split(s[1], x, "."); split(s[2], y, "."); h[it, x[4]]; h[it, y[4]]} END {for (k in h) {split(k, z, SUBSEP); n[z[1]]++}; for (i in n) print i, n[i]}' | sort; }
# cyc <run> <iteration>: pairs.txt's links in that iteration form one cycle through every host: prints its length or "broken"
cyc() { bfile $1 pairs.txt | awk -v it=$2 '$1 == it {nx[$2] = $3; n++; if (!f) f = $2} END {c = f; for (i = 0; i < n; i++) {c = nx[c]; if (c == f) {print (i + 1 == n) ? n : "broken"; exit}}; print "broken"}'; }

# o3: 3 hosts, one iteration: 3 links per rail per phase, every host and NIC in it
out=$(xrun o3 env FF_HOSTS=198.18.0.21-23 FF_ITER=1 timeout 200 $B $C 1); rc=$?
chk "3 hosts, FF_ITER=1: rc 0, COMPLETE hosts=3/3; pairs.txt 3 links (h21 h22, h22 h23, h23 h21), one cycle through all 3; the log's 'Pairing: a ring' line" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3 ' <<<\"\$out\" && [ \"\$(bfile o3 pairs.txt | tr '\n' '|')\" = '1 h21 h22|1 h22 h23|1 h23 h21|' ] && [ \"\$(cyc o3 1)\" = 3 ] && grep -q 'Pairing: a ring within each of 1 rail group' <<<\"\$out\"" \
    "rc=$rc $(grep -E '^RESULT|Pairing' <<<"$out" | cut -c1-160 | tr '\n' '|') pairs=$(bfile o3 pairs.txt | tr '\n' '|')"
chk "3 hosts: in each phase (1 and 2) each of the 6 rail IPs sends 1 run and receives 1 (no host or NIC sits out; control: the planted run below fails this)" \
    "[ \"\$(one1 o3 6)\" = ok ] && [ \$(sr o3 | awk '{print \$1, \$2}' | sort -u | wc -l) = 2 ]" "$(one1 o3 6 | head -n 4 | tr '\n' '|') phases $(sr o3 | awk '{print $2}' | sort -u | tr '\n' ' ')"
# e4: even count, the same rule
out=$(xrun e4 env FF_HOSTS=198.18.0.21-24 FF_ITER=1 FF_UDP=0 timeout 200 $B $C 1); rc=$?
chk "4 hosts (even): 4 links per iteration, each of the 8 rail IPs sends 1 and receives 1 per phase; COMPLETE 4/4; no wave:odd marker (the odd pass is gone)" \
    "[ $rc = 0 ] && [ \$(bfile e4 pairs.txt | wc -l) = 4 ] && [ \"\$(one1 e4 8)\" = ok ] && ! bfile e4 iperf3_results.txt | grep -q 'wave:odd' && grep -q '^RESULT coverage=COMPLETE hosts=4/4 ' <<<\"\$out\"" \
    "rc=$rc links $(bfile e4 pairs.txt | wc -l | tr -d ' '); $(one1 e4 8 | head -n 3 | tr '\n' '|') $(grep '^RESULT' <<<"$out")"
# f5: five hosts, two iterations: strides 1 and 2 reach all 10 host pairs
out=$(xrun f5 env FF_HOSTS=198.18.0.21-25 FF_ITER=2 FF_UDP=0 timeout 200 $B $C 1); rc=$?
chk "5 hosts, FF_ITER=2: all 5 hosts have a result in iteration 1 and in iteration 2; iteration 2 steps by 2 (h21 h23 first); metadata pairs_covered=10 (every host pair)" \
    "[ \"\$(perit f5 | tr '\n' '|')\" = '1 5|2 5|' ] && bfile f5 pairs.txt | grep -qx '2 h21 h23' && bfile f5 metadata.txt | grep -qx 'pairs_covered=10' && [ \"\$(one1 f5 10)\" = ok ]" \
    "rc=$rc per-iteration hosts: $(perit f5 | tr '\n' '|') $(bfile f5 metadata.txt | grep pairs_covered) $(bfile f5 pairs.txt | grep '^2 ' | tr '\n' '|')"
# sh: FF_SHUFFLE=1 (the default outside the tests): 8 hosts, two runs; the order is one of 5040 rings, so both runs
# matching the given order by chance is 1 in 25 million
for r in sa sb; do xrun $r env FF_SHUFFLE=1 FF_HOSTS=198.18.0.21-28 FF_ITER=1 FF_UDP=0 FF_SKIP_IPERF=1 FF_MESH=0 timeout 200 $B $C 1 > $W/$r.out; done
xrun s0 env FF_SHUFFLE=0 FF_HOSTS=198.18.0.21-28 FF_ITER=1 FF_UDP=0 FF_SKIP_IPERF=1 FF_MESH=0 timeout 200 $B $C 1 > $W/s0.out
given='1 h21 h22|1 h22 h23|1 h23 h24|1 h24 h25|1 h25 h26|1 h26 h27|1 h27 h28|1 h28 h21|'
chk "FF_SHUFFLE=1: each run's 8 links are one cycle through all 8 hosts, and at least one of the two runs is not in the given order; control: FF_SHUFFLE=0 gives the given order" \
    "[ \"\$(cyc sa 1)\" = 8 ] && [ \"\$(cyc sb 1)\" = 8 ] && [ \"\$(bfile s0 pairs.txt | tr '\n' '|')\" = '$given' ] && { [ \"\$(bfile sa pairs.txt | sort | tr '\n' '|')\" != \"\$(sort <<<\"\$(tr '|' '\n' <<<'$given')\" | grep . | tr '\n' '|')\" ] || [ \"\$(bfile sb pairs.txt | sort | tr '\n' '|')\" != \"\$(sort <<<\"\$(tr '|' '\n' <<<'$given')\" | grep . | tr '\n' '|')\" ]; }" \
    "sa: $(cyc sa 1) $(bfile sa pairs.txt | tr '\n' '|'); sb: $(cyc sb 1); s0: $(bfile s0 pairs.txt | tr '\n' '|')"
# s3: no load: the ring's path checks still cover every host
out=$(xrun s3 env FF_HOSTS=198.18.0.21-23 FF_ITER=1 FF_SKIP_IPERF=1 timeout 200 $B $C 1); rc=$?
chk "FF_SKIP_IPERF=1, 3 hosts: COMPLETE hosts=3/3, pairs.txt 3 links" "grep -q '^RESULT coverage=COMPLETE hosts=3/3 ' <<<\"\$out\" && [ \$(bfile s3 pairs.txt | wc -l) = 3 ]" "rc=$rc $(grep -E '^RESULT' <<<"$out")"
# (p) planted: the ring's last link dropped (one line): a host no longer sends in the phase
perl -pe 's/for \(\( i = 0; i < m; i\+\+ \)\); do$/for (( i = 0; i < m - 1; i++ )); do/' $C > $W/x_ring.sh
out=$(xrun po env FF_HOSTS=198.18.0.21-23 FF_ITER=1 timeout 200 $B $W/x_ring.sh 1)
chk "planted (one line: the ring's last link dropped): the send-1/receive-1 check finds IPs that sent nothing" \
    "[ \$(diff $C $W/x_ring.sh | grep -c '^>') = 1 ] && [ \"\$(one1 po 6)\" != ok ] && one1 po 6 | grep -q '^bad: .* 0 1\$'" "$(diff $C $W/x_ring.sh | grep '^>' | head -n 2) | $(one1 po 6 | head -n 3 | tr '\n' '|')"
finish
