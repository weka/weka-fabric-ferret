#!/opt/homebrew/bin/bash
# golden-C: one run with clients and every client fault that does not change another's numbers (10-26 item 7):
# backends h21 h22, clients c1..c4 on both client nets, 2 iterations, FF_CLIENT_RATIO=2:full (waves of share 2, then all
# at once), UDP on (the default), and FAKE_UDP_SOCK, SOFTNET_DROP, BUF_DISCARD, TX_DROP, RETR_SRC on c1, c2 at MTU 1500,
# FAKE_UDP_LOST=600000, temps (h22 hot, c2 no hwmon, c3 no ipmitool, inlet 39) and a dead rail IP 198.19.1.21. Every check
# that only reads a client run reads this one (moved here from 32, 33, 35, 36, 37, 38, 40, 41, 42, names prefixed
# "golden-C:"). Its bundle members are the stored fixtures in fixtures/golden-C/, compared with the fresh ones here
# (FIXTURE_UPDATE=1 rewrites them and says WRITTEN; only a normal run counts).
# checks: 134
# secs: 66
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
FX=$S/fixtures/golden-C
out=$(xrun gc FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=2 FF_CLIENT_RATIO=2:full \
      FAKE_UDP_SOCK=c1 FAKE_SOFTNET_DROP=c1 FAKE_BUF_DISCARD=c1 FAKE_TX_DROP=c1 FAKE_UDP_LOST=600000 FAKE_RETR_SRC=198.19.10.1 \
      FAKE_CLIENT_MTU=c2:1500 FAKE_HOT=h22 FAKE_NO_HWMON=c2 FAKE_NO_IPMI=c3 FAKE_INLET=39 FAKE_MESHFAIL=198.19.1.21 timeout 300 $B $C 1); rc=$?

# --- fixture freshness: the stored members the unit groups read, sorted, timestamps out ---
MEMBERS="iperf3_results.txt client_results.txt iperf3_udp_results.txt host_counters.txt prio_counters.txt packet_drops.txt
 udp_host_counters.txt udp_nic_drops.txt udp_expected.txt udp_tx.txt temps.txt temps_summary.txt host_rx.txt client_rx.txt
 clients.txt client_routes.txt nic_diagnostics.txt lldp_neighbors.txt mesh_failures.txt rails.txt rail_anomalies.txt metadata.txt"
norm() { case $1 in metadata.txt) grep -vE '^(timestamp|end_timestamp)=' ;; *) cat ;; esac | sort; }
if [[ -n $FIXTURE_UPDATE ]]; then
    fxupdate gc "$FX" golden-C $MEMBERS
else
    for m in $MEMBERS; do
        chk "golden-C fixture fresh: $m" "[ -e $FX/$m ] && [ \"\$(bfile gc $m | norm $m)\" = \"\$(norm $m < $FX/$m)\" ]" "$(diff <(norm $m < $FX/$m) <(bfile gc $m | norm $m) 2>&1 | head -n 4)"
    done
fi

# --- from 32_clients.sh ---
chk "golden-C: clients: COMPLETE rc=0 with clients=4/4" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE .*clients=4/4' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
chk "golden-C: clients.txt: header and one row per client NIC (c4 two)" "[ \"\$(bhead gc clients.txt)\" = 'Client Target NIC IP MTU State Speed' ] && [ \$(bfile gc clients.txt | awk 'NR > 1 && NF' | wc -l) = 5 ] && [ \$(bfile gc clients.txt | awk '\$1 == \"c4\"' | wc -l) = 2 ]" "$(bfile gc clients.txt)"
chk "golden-C: clients.txt: c4 ens1f1 198.19.11.4 ok 100000Mb/s, bonds 200000Mb/s" "bfile gc clients.txt | awk '\$1 == \"c4\" && \$3 == \"ens1f1\" && \$4 == \"198.19.11.4\" && \$5 == 9000 && \$6 == \"ok\" && \$7 == \"100000Mb/s\" {a = 1} \$3 == \"bond0\" && \$7 == \"200000Mb/s\" {b++} END {exit !(a && b == 3)}'" "$(bfile gc clients.txt)"
cres=$(bfile gc client_results.txt)
# (32's "C1 and C2 wave markers, no all-at-once (ratio 1)" is not here: golden-C runs 2:full; 33's "ratio 1 (default,
# control): only C1 C2, every share:1" proves the ratio-1 markers)
chk "golden-C: client_results: every result line carries share:K" "[ \$(grep -c 'Gbits/sec' <<<\"\$cres\") -ge 20 ] && ! grep 'Gbits/sec' <<<\"\$cres\" | grep -qv ' share:[0-9]'" "$(grep 'Gbits/sec' <<<"$cres" | head -n 2)"
# 5 client NICs x 2 rails x 2 directions
chk "golden-C: every client NIC to every rail both ways (20 keys)" "[ \$(cflows | wc -l) = 20 ]" "$(cflows | tr '\n' ';')"
meta=$(bfile gc metadata.txt)
chk "golden-C: metadata: clients=1 client_mode=nets spec ratio expected/tested" "grep -qx 'clients=1' <<<\"\$meta\" && grep -qx 'client_mode=nets' <<<\"\$meta\" && grep -qx 'client_spec=$NETS' <<<\"\$meta\" && grep -qx 'client_ratio=2:full' <<<\"\$meta\" && grep -qx 'clients_expected=4' <<<\"\$meta\" && grep -qx 'clients_tested=4' <<<\"\$meta\"" "$(grep '^client' <<<"$meta" | tr '\n' ' ')"
chk "golden-C: metadata: client_paths_ok = client_paths_planned > 0" "awk -F= '\$1 == \"client_paths_planned\" {p = \$2} \$1 == \"client_paths_ok\" {o = \$2} END {exit !(p > 0 && p == o)}' <<<\"\$meta\"" "$(grep '^client_paths' <<<"$meta" | tr '\n' ' ')"
routes=$(bfile gc client_routes.txt)
chk "golden-C: client_routes: every client NIC, all declared; c4 reaches rail B by ens1f1" "awk 'NF == 6 {n++; if (\$6 != \"declared\") b++; if (\$1 == \"c4\" && \$3 == \"B\" && \$5 == \"ens1f1\") c = 1} END {exit !(n >= 5 && !b && c)}' <<<\"\$routes\"" "$routes"
chk "golden-C: no client_route_undeclared anomaly in a clean run" "[ -n \"\$(bundle gc)\" ] && ! bfile gc rail_anomalies.txt | grep -q client_route_undeclared"
chk "golden-C: nic_diagnostics and lldp_neighbors carry the client NICs" "bfile gc nic_diagnostics.txt | grep -q 'c4.*ens1f1' && bfile gc nic_diagnostics.txt | grep -q 'c1.*bond0' && bfile gc lldp_neighbors.txt | grep -q 'cleaf1.example'" "$(bfile gc nic_diagnostics.txt | grep -c c4)"
# drops are recorded only when a counter rose; these hosts never drop, so check the reads: 2 backends x 2 rails + 5 client NICs
chk "golden-C: drop counters read around client phases C1 and C2 (9 NICs each)" "grep -qE '(Drops during client phase C1|No drop counter increases in client phase C1 \\(9 NICs read\\))' <<<\"\$out\" && grep -qE '(Drops during client phase C2|No drop counter increases in client phase C2 \\(9 NICs read\\))' <<<\"\$out\"" "$(grep 'client phase C' <<<"$out" | head -n 4)"
chk "golden-C: clients got iperf3 servers and cleanup (pkill on c1..c4)" "[ -f $FAKE_STATE/pkill.log ] && [ \$(grep -xE 'c[1-4]' $FAKE_STATE/pkill.log | sort -u | wc -l) = 4 ]" "$(sort -u $FAKE_STATE/pkill.log 2>&1 | tr '\n' ' ')"
chk "golden-C: no iperf3 run refused (every ip:port it used was started)" "[ -s $FAKE_STATE/iperf_args.log ] && [ ! -e $FAKE_STATE/iperf_refused.log ]" "$(head -n 3 $FAKE_STATE/iperf_refused.log 2>&1)"
render gc; prc=$?
# (from 14, on a fresh render: golden-C leaves the uplinks undeclared) totals card, no verdict
chk "golden-C: dashboard, uplinks not declared: totals card, no verdict" "grep -q 'Leaf uplink totals (set FF_SPINES' $W/gc.html && ! grep -q -E 'oversubscribed|ECMP is uneven|<th>Busiest' $W/gc.html" "$(grep -oE 'Leaf uplink[^<]*' $W/gc.html | head -n 2)"
chk "golden-C: clients: dashboard renders (rc 0 or 3) and shows the clients" "{ [ $prc = 0 ] || [ $prc = 3 ]; } && grep -q 198.19.11.4 $W/gc.html && grep -qi 'client' $W/gc.html" "rc=$prc $(tail -n 3 $W/gc.pout)"

# --- from 33_client_ratio.sh ---
marks() { bfile $1 client_results.txt | grep -oE '^### client .*phase:[A-Z][0-9]' | grep -oE '[A-Z][0-9]$' | sort -u | tr '\n' ' '; }
chk "golden-C: ratio 2:full: C1 C2 F1 F2 markers" "[ \"\$(marks gc)\" = 'C1 C2 F1 F2 ' ]" "rc=$rc marks=$(marks gc) $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
chk "golden-C: ratio 2:full: share:2 in a wave" "bfile gc client_results.txt | awk '/^### client .*phase:C[12] / {w = 1; next} /^###/ {w = 0} w && / share:2( |\$)/ {f = 1} END {exit !f}'" "$(bfile gc client_results.txt | grep -o 'share:[0-9]*' | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: ratio 2:full: metadata client_ratio=2:full" "bfile gc metadata.txt | grep -qx 'client_ratio=2:full'"

# --- from 35_client_parity.sh ---
chk "golden-C: parity run: COMPLETE, clients=4/4" "grep -qE '^RESULT coverage=COMPLETE .*clients=4/4' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
chk "golden-C: log: more than one wave prints 'N waves each way' (control for item 4)" "grep -qE -- '---- Clients, iteration 1: [2-9][0-9]* waves each way' <<<\"\$out\"" "$(grep -- '---- Clients' <<<"$out")"
hc=$(bfile gc host_counters.txt)
chk "golden-C: host_counters: rows for client phases C1 and C2" "grep -qE '^iter1_clientC1 ' <<<\"\$hc\" && grep -qE '^iter1_clientC2 ' <<<\"\$hc\"" "$(awk '{print $1}' <<<"$hc" | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: host_counters: c1's TCPRcvQDrop rose in client phase C1" "grep -qE '^iter1_clientC1 c1 TCPRcvQDrop [1-9]' <<<\"\$hc\"" "$(grep -E '^iter1_clientC1 c1 ' <<<"$hc")"
chk "golden-C: host_counters: backends read in client phases too" "grep -qE '^iter1_clientC1 h2[12] ' <<<\"\$hc\"" "$(grep -cE '^iter1_clientC1 h2' <<<"$hc")"
chk "golden-C: log: host receive line for each client phase, c1's drops named" "grep -q 'Host receive drops in client phase C1 .*c1 TCPRcvQDrop' <<<\"\$out\" && grep -qE '(Host receive drops|No host receive drop counter rose) in client phase C2' <<<\"\$out\"" "$(grep 'client phase C' <<<"$out" | head -n 6)"
pc=$(bfile gc prio_counters.txt)
chk "golden-C: prio_counters: rows labelled by client phase, client NICs included" "grep -qE '^iter1_clientC1 c1_bond0 rx_prio0_buf_discard [1-9]' <<<\"\$pc\"" "$(awk '{print $1}' <<<"$pc" | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: log: pause/ECN line for each client phase" "grep -qE '(Pause/ECN/discard/RDMA counters that rose|No pause/ECN/discard/RDMA counter rose) in client phase C1' <<<\"\$out\"" "$(grep -i 'pause' <<<"$out" | head -n 4)"
si=$(tar -tzf "$(bundle gc)" | grep -E '/sysinfo/[^/]+/$')
chk "golden-C: sysinfo: a directory per client (and per backend)" "[ \$(grep -cE '/sysinfo/c[1-4]/\$' <<<\"\$si\") = 4 ] && [ \$(grep -cE '/sysinfo/h2[12]/\$' <<<\"\$si\") = 2 ]" "$si"
crx=$(bfile gc client_rx.txt)
chk "golden-C: client_rx.txt: header Client NUMA_1/2 Ring_1 Ring_2 PCIe_1 PCIe_2 ..." "[ \"\$(head -n1 <<<\"\$crx\" | awk '{print \$1, \$2, \$3, \$4, \$5, \$6, \$7}')\" = 'Client NUMA_1/2 Ring_1 Ring_2 PCIe_1 PCIe_2 Governor' ]" "$(head -n1 <<<"$crx")"
chk "golden-C: client_rx.txt: one row per client" "[ \"\$(awk 'NR > 1 {print \$1}' <<<\"\$crx\" | sort -u | tr '\n' ' ')\" = 'c1 c2 c3 c4 ' ]" "$crx"
chk "golden-C: client_rx.txt: c1 flagged tcp_rcv_drop, c2 not" "awk '\$1 == \"c1\" && \$NF ~ /tcp_rcv_drop/ {a = 1} \$1 == \"c2\" && \$NF !~ /tcp_rcv_drop/ {b = 1} END {exit !(a && b)}' <<<\"\$crx\"" "$crx"
chk "golden-C: client_rx.txt: counters read (no counters_unread)" "! grep -q counters_unread <<<\"\$crx\"" "$crx"
chk "golden-C: summary: Client-side receive section names c1" "grep -qE '^Client-side receive: [1-9][0-9]* of 4 clients flagged' <<<\"\$out\" && grep -qE '^ +c1 ' <<<\"\$out\"" "$(grep -A3 '^Client-side receive' <<<"$out")"
chk "golden-C: host_rx.txt: backend rows only, unchanged header" "[ \"\$(bhead gc host_rx.txt | awk '{print \$1, \$2}')\" = 'Host NUMA_A/B' ] && ! bfile gc host_rx.txt | grep -qE '^c[1-4] '" "$(bfile gc host_rx.txt)"
# one table, one row per data NIC (10-25): 4 backend NIC rows and 5 client NIC rows under one header
chk "golden-C: summary: one table, one row per data NIC: header, 4 backend + 5 client rows, no per-host or per-client table" "grep -qE '^ +Role +Host +NIC +IP +Same +Cross +CB_Out +CB_In +All_Out +All_In +Retr +Retr_% +Expect +Status\$' <<<\"\$out\" && [ \$(grep -cE '^ +backend +h2[12] +enp' <<<\"\$out\") = 4 ] && [ \$(grep -cE '^ +client +c[1-4] ' <<<\"\$out\") = 5 ] && ! grep -qE '^ +Host +Avg_Gbps +Rail_A|^ +Client +NIC +IP +C->B' <<<\"\$out\"" "$(grep -E '^ +(Role|backend|client) ' <<<"$out")"
chk "golden-C: summary: backend NIC rows carry client columns (h21 served clients)" "grep -E '^ +backend +h21 ' <<<\"\$out\" | awk '\$7 ~ /^[0-9.]+\$/ && \$8 ~ /^[0-9.]+\$/ {n++} END {exit !n}'" "$(grep -E '^ +backend +h21 ' <<<"$out")"
meta=$(bfile gc metadata.txt)
chk "golden-C: metadata: drop_nics_expected = 2 x 2 rails + 5 client NICs" "grep -qx 'drop_nics_expected=9' <<<\"\$meta\"" "$(grep drop_nics <<<"$meta")"
chk "golden-C: log: iteration drop read covers client NICs (9)" "grep -qE '(Drops during iteration 1|No drop counter increases in iteration 1 \\(9 NICs read\\))' <<<\"\$out\"" "$(grep 'iteration 1' <<<"$out" | grep -i drop)"
chk "golden-C: dashboard renders with client_rx.txt" "{ [ $prc = 0 ] || [ $prc = 3 ]; }" "rc=$prc $(tail -n 3 $W/gc.pout)"
chk "golden-C: dashboard: host-side card counts clients, c1 flagged tcp_rcv_drop" "grep -qE 'Host-side receive: [0-9]+ of 2 hosts flagged; 1 of 4 clients flagged' $W/gc.html && grep -qE '<td>c1</td>.*tcp_rcv_drop' $W/gc.html" "$(grep -oE 'Host-side receive: [^<]*' $W/gc.html)"
chk "golden-C: dashboard: per data NIC view has 4 backend NIC rows and 5 client NIC rows" "[ \$(ROWS=1 node $H/rows.js $W/gc.html | grep -cE '^h2[12](\\(HOT\\))? ') = 4 ] && [ \$(ROWS=1 node $H/rows.js $W/gc.html | grep -cE '^c[1-4](\\(HOT\\))? ') = 5 ]" "$(ROWS=1 node $H/rows.js $W/gc.html)"
chk "golden-C: dashboard: clients card has a Retr column" "grep -q 'Retr<small>TCP retransmits, its runs to the backends' $W/gc.html" "$(grep -c Retr $W/gc.html)"

# Retr is the sender's count: a row's Retr = the sum of retransmits:N over the runs that IP sent, backend and client runs
res=$(bfile gc iperf3_results.txt; bfile gc client_results.txt)
want=$(awk '/Gbits/ {split($1, a, ","); for (i = 1; i <= NF; i++) if ($i ~ /^retransmits:/) s[a[1]] += substr($i, 13)} END {for (ip in s) if (ip ~ /^198\.19\.[12]\.21$/) print ip, s[ip]}' <<<"$res" | sort)
got=$(grep -E '^ +backend +h21 ' <<<"$out" | awk '{print $4, $(NF-3)}' | sort)
chk "golden-C: Retr for each h21 NIC = retransmits summed over the runs that IP sent" "[ -n \"$want\" ] && [ \"$got\" = \"$want\" ]" "want=$want got=$got"

# --- from 36_phase_times.sh ---
TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
chk "golden-C: run: COMPLETE" "grep -qE '^RESULT coverage=COMPLETE' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
pt=$(bfile gc phase_times.txt)
chk "golden-C: phase_times.txt: header Iter Phase Start_UTC End_UTC" "[ \"\$(head -n1 <<<\"\$pt\")\" = 'Iter Phase Start_UTC End_UTC' ]" "$(head -n1 <<<"$pt")"
want='1 1|1 2|1 U1|1 U2|1 C1|1 C2|1 F1|1 F2|1 UC1|1 UC2|1 UF1|1 UF2|2 1|2 2|2 U1|2 U2|2 C1|2 C2|2 F1|2 F2|2 UC1|2 UC2|2 UF1|2 UF2|'
got=$(awk 'NR > 1 {printf "%s %s|", $1, $2}' <<<"$pt")
chk "golden-C: phase_times.txt: one row per phase per iteration, in run order" "[ \"$got\" = \"$want\" ]" "got=$got"
chk "golden-C: phase_times.txt: every start and end is a UTC stamp" "awk -v ts='^$TS\$' 'NR > 1 && !(\$3 ~ ts && \$4 ~ ts) {b++} END {exit !(NR == 25 && !b)}' <<<\"\$pt\"" "$pt"
chk "golden-C: phase_times.txt: start <= end, and no phase starts before the last one ended" "awk 'NR > 1 {if (\$3 > \$4 || \$3 < e) b++; e = \$4} END {exit !(NR > 1 && !b)}' <<<\"\$pt\"" "$pt"
m=$(bfile gc metadata.txt); t0=$(grep '^timestamp=' <<<"$m" | cut -d= -f2); t1=$(grep '^end_timestamp=' <<<"$m" | cut -d= -f2)
f0=$(awk 'NR == 2 {gsub(/[-:]/, "", $3); print $3}' <<<"$pt"); f1=$(awk 'END {gsub(/[-:]/, "", $4); print $4}' <<<"$pt")
chk "golden-C: phase_times.txt: inside the run's metadata start and end" "[ -n \"$t0\" ] && [[ ! \"$f0\" < \"$t0\" ]] && [[ ! \"$t1\" < \"$f1\" ]]" "meta $t0..$t1 phases $f0..$f1"
for p in 'Phase 1' 'Phase 2' 'Phase U1' 'Phase U2' 'Client phase C1' 'Client phase F2'; do
    n=$(grep -cE "^# $p[: (].*start $TS" <<<"$out")
    chk "golden-C: log: '$p' line carries its start, once per iteration" "[ $n = 2 ]" "n=$n $(grep -E "^# $p[: (]" <<<"$out" | head -n 2)"
done
s=$(grep -oE "^# Phase U2: .*start $TS" <<<"$out" | head -n1 | grep -oE "$TS\$"); f=$(awk '$1 == 1 && $2 == "U2" {print $3}' <<<"$pt")
chk "golden-C: log start = phase_times start (iteration 1, U2)" "[ -n \"$s\" ] && [ \"$s\" = \"$f\" ]" "log=$s file=$f"
chk "golden-C: dashboard renders with phase_times.txt" "{ [ $prc = 0 ] || [ $prc = 3 ]; }" "rc=$prc $(tail -n 3 $W/gc.pout)"

# --- from 37_client_udp.sh ---
CIPS='198\.19\.1[01]\.'
chk "golden-C: run: COMPLETE, clients=4/4" "grep -qE '^RESULT coverage=COMPLETE .*clients=4/4' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
ur=$(bfile gc iperf3_udp_results.txt); cr=$(bfile gc client_results.txt)
cnt() { awk -v p="$2" '/^### / {ph = ""; for (i = 2; i <= NF; i++) if ($i ~ /^phase:/) ph = substr($i, 7); next} ph == p && /Gbits/ {n++} END {print n + 0}' <<<"$1"; }
for p in C1 C2 F1 F2; do
    t=$(cnt "$cr" $p); u=$(cnt "$ur" U$p)
    chk "golden-C: U$p: as many UDP runs as TCP phase $p ($t)" "[ $t -gt 0 ] && [ $u = $t ]" "tcp=$t udp=$u"
done
chk "golden-C: UC1/UF1 send from client IPs, UC2/UF2 to them" "awk '/^### / {for (i = 2; i <= NF; i++) if (\$i ~ /^phase:/) ph = substr(\$i, 7); next} /Gbits/ {split(\$1, a, \",\"); c = (ph ~ /1\$/) ? a[1] : a[2]; if (ph ~ /^U[CF]/) {n++; if (c !~ /^$CIPS/) b++}} END {exit !(n > 0 && !b)}' <<<\"\$ur\"" "$(grep -A2 'phase:U[CF]' <<<"$ur" | head -n 8)"
chk "golden-C: backend phases U1/U2 still there" "[ \$(cnt \"\$ur\" U1) -gt 0 ] && [ \$(cnt \"\$ur\" U2) -gt 0 ]" "U1=$(cnt "$ur" U1) U2=$(cnt "$ur" U2)"
nu=$(grep -c "^UDP $CIPS" $FAKE_STATE/iperf_args.log); want=$(( $(cnt "$ur" UC1) + $(cnt "$ur" UF1) ))
chk "golden-C: fake: UDP runs launched from client IPs = UC1 + UF1 ($want)" "[ $want -gt 0 ] && [ $nu = $want ]" "launched=$nu"
uh=$(bfile gc udp_host_counters.txt)
chk "golden-C: udp_host_counters: c1's socket drops rose in UC2" "grep -qE '^iter1 UC2 c1 [1-9][0-9]* ' <<<\"\$uh\"" "$(grep -E '^iter1 U[CF]2 c1 ' <<<"$uh")"
chk "golden-C: udp_host_counters: rows for every twin phase" "[ \"\$(awk '\$1 == \"iter1\" && \$2 ~ /^U[CF][12]\$/ {print \$2}' <<<\"\$uh\" | sort -u | tr '\n' ' ')\" = 'UC1 UC2 UF1 UF2 ' ]" "$(awk '{print $2}' <<<"$uh" | sort | uniq -c | tr '\n' ' ')"
un=$(bfile gc udp_nic_drops.txt)
chk "golden-C: udp_nic_drops: client NICs read in the twin phases" "grep -qE '^iter1 UC2 c1_bond0 ' <<<\"\$un\"" "$(grep -cE '^iter1 UC2 ' <<<"$un")"
chk "golden-C: log: UC2 loss line counts c1's socket drops" "grep -E '^#   UC2 loss: ' <<<\"\$out\" | grep -qE 'receiver socket [1-9][0-9]{3,}'" "$(grep -E 'U[CF][12] loss' <<<"$out")"
chk "golden-C: log: UC1 loss line has no client socket drops (control: backends receive)" "grep -E '^#   UC1 loss: ' <<<\"\$out\" | grep -qE 'receiver socket ([0-9]{1,3}|[0-9]*[02-9][0-9]{3}),'" "$(grep -E 'UC1 loss' <<<"$out")"
chk "golden-C: log: no 'backends only' line; UDP pass names the client twins" "! grep -q 'backends only' <<<\"\$out\" && grep -q 'UDP twin of each client phase' <<<\"\$out\"" "$(grep -i 'udp pass' <<<"$out")"
# (was 37's dd run) UDP is at its default here: on, with clients
chk "golden-C: default: UDP pass on, backends and clients (udp=1 in metadata, UC1 runs)" "bfile gc metadata.txt | grep -qx 'udp=1' && [ \$(cnt \"\$ur\" UC1) -gt 0 ] && [ \$(cnt \"\$ur\" U1) -gt 0 ]" "$(bfile gc metadata.txt | grep udp) UC1=$(cnt "$ur" UC1)"
# (was 37's cm run) datagram size: the smaller MTU of the two ends, minus 28 (c2 at 1500: -l 1472); other clients not
c2ip=$(bfile gc clients.txt | awk '$1 == "c2" {print $4; exit}')
l2=$(awk -v ip="$c2ip" '$1 == "UDP" && ($2 == ip || $3 == ip) {print $7}' $FAKE_STATE/iperf_args.log | sort -u | tr '\n' ' ')
lo=$(awk -v ip="$c2ip" '$1 == "UDP" && $2 ~ /^198\.19\.1[01]\./ && $2 != ip && $3 != ip {print $7}' $FAKE_STATE/iperf_args.log | sort -u | tr '\n' ' ')
chk "golden-C: c2 at MTU 1500: its UDP runs use -l 1472, other clients' do not (control)" "[ -n \"$c2ip\" ] && [ \"$l2\" = '1472 ' ] && [ -n \"$lo\" ] && [ \"$lo\" != '1472 ' ]" "c2=$c2ip c2_len=$l2 others=$lo"
chk "golden-C: summary: UDP by receiving host lists the clients" "[ \$(sed -n '/^UDP (-b 0) by receiving host/,/^  Lost datagrams/p' <<<\"\$out\" | grep -cE '^ +c[1-4] ') = 4 ]" "$(sed -n '/^UDP (-b 0) by receiving host/,/^  Lost datagrams/p' <<<"$out")"
# (37's "phase_times: UC1 UC2 UF1 UF2 rows after F2" is not here: 36's "phase_times.txt: one row per phase per
# iteration, in run order" below checks the same order for both iterations)
chk "golden-C: dashboard renders" "{ [ $prc = 0 ] || [ $prc = 3 ]; }" "rc=$prc $(tail -n 3 $W/gc.pout)"
chk "golden-C: dashboard: UDP card has a UC2 row to c1 with its socket drops" "grep -qE '<td>iter1 UC2</td><td>h2[12] [0-9.]+</td><td>c1 [0-9.]+</td>(<td>[^<]*</td>){3}<td[^>]*>[0-9,]+</td><td>[1-9][0-9,]{3,}</td>' $W/gc.html" "$(grep -oE '<td>iter1 UC2</td><td>[^<]*</td><td>c1[^<]*</td>(<td>[^<]*</td>){4}' $W/gc.html | head -n 2)"

# --- from 38_client_mesh.sh ---
chk "golden-C: dead rail IP: 7 failed, 5 of them from clients" "grep -q 'Mesh: 28 pings, 7 failed (from clients: 5 of 20)' <<<\"\$out\"" "$(grep 'Mesh' <<<"$out")"
mf=$(bfile gc mesh_failures.txt)
chk "golden-C: mesh_failures.txt: 5 client rows (5th column client), 2 backend rows" "[ \$(awk '\$5 == \"client\"' <<<\"\$mf\" | wc -l) = 5 ] && [ \$(awk 'NF == 4' <<<\"\$mf\" | wc -l) = 2 ]" "$mf"
chk "golden-C: finding: h21 rail IP did not answer 5 of 5 client IPs; backend finding kept" "grep -q 'h21 mesh_client_unreachable rail IP 198.19.1.21 did not answer 5 of 5 client IPs' <<<\"\$out\" && grep -q 'h21 mesh_unreachable rail IP 198.19.1.21' <<<\"\$out\"" "$(grep mesh_ <<<"$out")"
chk "golden-C: dashboard: Preflight names the client finding and the client ping count" "grep -q 'Rail IP unreachable from clients in the mesh' $W/gc.html && grep -q 'mesh: 7 of 28 pings failed (from clients: 5 of 20)' $W/gc.html" "rc=$prc $(grep -oE 'mesh: [^<]*' $W/gc.html)"

# --- from 40_sender_tx.sh ---
# golden-C runs 2 iterations: the 500000 shortfall is per phase, so sum iteration 1's UC1
txsum() { awk -v p="$2" -v s="$3" '$1 == "iter1" && $2 == p && $4 ~ s {t += $12} END {print t + 0}' <<<"$1"; }
ue=$(bfile gc udp_expected.txt)
chk "golden-C: c1 NIC drops: c1's runs in iteration 1's UC1 carry 500000 sender TX in total" "[ \$(txsum \"\$ue\" UC1 '^198\\\\.19\\\\.10\\\\.1\$') = 500000 ]" "$(awk '$2 == "UC1"' <<<"$ue")"
chk "golden-C: c1 NIC drops: no other sender charged in UC1 (control)" "[ \$(txsum \"\$ue\" UC1 '^198\\\\.19\\\\.1[01]\\\\.[234]\$') = 0 ]" "$(awk '$2 == "UC1"' <<<"$ue")"
chk "golden-C: c1 NIC drops: runs into c1 (UC2) carry none: the shortfall is the sender's" "[ \$(awk '\$2 == \"UC2\" && \$5 == \"198.19.10.1\" {t += \$12} END {print t + 0}' <<<\"\$ue\") = 0 ]" "$(awk '$2 == "UC2"' <<<"$ue")"
chk "golden-C: log: UC1 loss line names sender TX 500000, unaccounted reduced by it" "grep -qE '^#   UC1 loss: .*: sender TX 500000, receiver socket' <<<\"\$out\"" "$(grep 'UC1 loss' <<<"$out")"
chk "golden-C: dashboard: Sender TX column, header total, a c1 row with sender TX" "grep -q '<th>Sender TX</th>' $W/gc.html && grep -qE 'sender TX [1-9][0-9,]*, receiver socket' $W/gc.html && grep -qE '<td>c1 198\\.19\\.10\\.1</td>(<td>[^<]*</td>){4}<td class=\"text-warning\">[1-9][0-9,]*</td>' $W/gc.html" "rc=$prc $(grep -oE 'sender TX [^,]*' $W/gc.html | head -n 1)"

# --- from 41_retr_and_rows.sh ---
tbl() { grep -E '^ +(Role|backend|client) ' <<<"$1"; }
chk "golden-C: c1 at ~0.45% retransmits: OK(retr), Retr_% above 0.1" "tbl \"\$out\" | awk '\$2 == \"c1\" {f = 1; ok = (\$NF == \"OK(retr)\" && \$(NF-2) > 0.1)} END {exit !(f && ok)}'" "$(tbl "$out")"
chk "golden-C: the other NICs stay OK, no (retr) (control)" "[ \$(tbl \"\$out\" | grep -c '(retr)') = 1 ]" "$(tbl "$out")"
chk "golden-C: the flagged row sorts first among the OK rows" "[ \"\$(tbl \"\$out\" | awk 'NR == 2 {print \$2}')\" = c1 ]" "$(tbl "$out")"
chk "golden-C: metadata: retr_pct=0.1" "bfile gc metadata.txt | grep -qx 'retr_pct=0.1'" "$(bfile gc metadata.txt | grep retr)"
# c1 also carries 42's HOT mark here (inlet 39 on its BMC)
chk "golden-C: dashboard: c1 row OK(retr), header names the threshold" "ROWS=1 node $H/rows.js $W/gc.html | grep -qxE 'c1(\\(HOT\\))? OK\\(retr\\)' && grep -q '(retr) above 0.1%' $W/gc.html" "rc=$prc $(ROWS=1 node $H/rows.js $W/gc.html)"

# --- from 42_temps.sh ---
chk "golden-C: run COMPLETE" "grep -qE '^RESULT coverage=COMPLETE' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
tt=$(bfile gc temps.txt); ts=$(bfile gc temps_summary.txt)
chk "golden-C: temps.txt: header, readings for all 6 hosts, labels iter1_pre .. end" "head -n1 <<<\"\$tt\" | grep -qx 'Label Host Source Chip Dev Sensor Temp_C High_C Crit_C Status' && [ \$(awk 'NR > 1 {print \$2}' <<<\"\$tt\" | sort -u | wc -l) = 6 ] && grep -q '^iter1_pre ' <<<\"\$tt\" && grep -q '^iter2_p1 ' <<<\"\$tt\" && grep -q '^iter1_C2 ' <<<\"\$tt\" && grep -q '^end ' <<<\"\$tt\"" "$(awk 'NR > 1 {print $1}' <<<"$tt" | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: BMC read once per iteration and at the end only (iter1_pre iter2_pre end)" "[ \"\$(awk '\$3 == \"ipmi\" {print \$1}' <<<\"\$tt\" | sort -u | tr '\n' ' ')\" = 'end iter1_pre iter2_pre ' ]" "$(awk '$3 == "ipmi" {print $1}' <<<"$tt" | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: h22 CPU package: crit+rise (climbed past 100 from 70)" "awk '\$1 == \"h22\" && \$6 == \"Package_id_0\" {f = \$12} END {exit !(f == \"crit+rise\")}' <<<\"\$ts\"" "$(grep Package <<<"$ts")"
chk "golden-C: h21 CPU package 60, high 80: no flag (control)" "awk '\$1 == \"h21\" && \$6 == \"Package_id_0\" {f = \$12} END {exit !(f == \"-\")}' <<<\"\$ts\"" "$(grep '^h21 ' <<<"$ts")"
chk "golden-C: inlet 39 (BMC status nc, high 38): high on every host with a BMC; the BMC's Inlet_Temp is typed inlet (thermals_capture.sh's types), 0 rows typed bmc (control: one planted bmc row counts 1)" "[ \$(awk '\$3 == \"inlet\" && \$6 == \"Inlet_Temp\" && \$12 == \"high\"' <<<\"\$ts\" | wc -l) = 5 ] && [ \$(awk '\$3 == \"bmc\"' <<<\"\$ts\" | wc -l) = 0 ] && [ \$({ printf '%s\n' \"\$ts\"; echo 'px ipmi bmc - - Inlet_Temp 1 1 1 - - - 1'; } | awk '\$3 == \"bmc\"' | wc -l) = 1 ]" "$(awk '$2 == "ipmi"' <<<"$ts")"
chk "golden-C: types: cpu inlet nic nvme (the seven-type scheme on this fixture: hwmon coretemp/nvme/mlx5 and the BMC inlet)" "[ \"\$(awk 'NR > 1 && \$3 != \"-\" {print \$3}' <<<\"\$ts\" | sort -u | tr '\n' ' ')\" = 'cpu inlet nic nvme ' ]" "$(awk 'NR > 1 {print $3}' <<<"$ts" | sort | uniq -c | tr '\n' ' ')"
chk "golden-C: the summary header carries Min_C as column 13 and every data row 13 fields (control: one planted 12-field row counts 1)" "[ \"\$(head -n 1 <<<\"\$ts\")\" = 'Host Source Type Chip Dev Sensor First_C Max_C Last_C High_C Crit_C Flag Min_C' ] && [ \$(awk 'NR > 1 && NF != 13' <<<\"\$ts\" | wc -l) = 0 ] && [ \$({ printf '%s\n' \"\$ts\"; echo 'px ipmi bmc - - Inlet_Temp 1 1 1 - - -'; } | awk 'NR > 1 && NF != 13' | wc -l) = 1 ] && [ \$(awk 'NR > 1' <<<\"\$ts\" | wc -l) -gt 10 ]" "$(head -n 1 <<<"$ts"); $(awk 'NR > 1 && NF != 13' <<<"$ts")"
chk "golden-C: c2 no hwmon: nodata row, loud in the summary; c3 no ipmitool: nodata row; nodata rows after the data rows" "grep -qE '^c2 hwmon - - - none .* nodata:no_hwmon_temperature_sensors -\$' <<<\"\$ts\" && grep -qE '^c3 ipmi .* nodata:ipmitool_not_installed -\$' <<<\"\$ts\" && grep -q 'NO TEMPERATURE DATA: c2 hwmon' <<<\"\$out\" && grep -q 'NO TEMPERATURE DATA: c3 ipmi' <<<\"\$out\" && awk 'NR > 1 && \$12 ~ /^nodata/ {d = 1} NR > 1 && d && \$12 !~ /^nodata/ {bad = 1} END {exit bad}' <<<\"\$ts\"" "$(grep nodata <<<"$ts") | $(grep 'NO TEMP' <<<"$out")"
chk "golden-C: summary: the Temperatures section comes before the throughput table" "awk '/^Temperatures \\(/ {t = NR} /^Throughput per data NIC/ {p = NR} END {exit !(t && p && t < p)}' <<<\"\$out\"" "$(grep -nE '^(Temperatures|Throughput per data NIC)' <<<"$out")"
chk "golden-C: summary: h22 listed with cpu:crit+rise, flagged sensors listed" "grep -qE '^ +h22 +.*cpu:crit\\+rise' <<<\"\$out\" && grep -q 'Flagged sensors' <<<\"\$out\"" "$(sed -n '/^Temperatures (/,/^$/p' <<<"$out")"
chk "golden-C: metadata: temps=1 ipmi=1 temp_margin=5 temp_rise=10" "[ \"\$(bfile gc metadata.txt | grep -E '^(temps|ipmi|temp_margin|temp_rise)=' | tr '\n' ' ')\" = 'temps=1 ipmi=1 temp_margin=5 temp_rise=10 ' ]" "$(bfile gc metadata.txt | grep -E 'temp|ipmi')"
# heat first on the page (10-28): the Temperatures tab is third, before NIC / Optics, and holds the card; the heat PROBLEM line points at the tab
chk "golden-C: dashboard: Temperatures tab third, heat first in the banner: the tab after Connection Health and Needs Repair, before NIC / Optics; its card once in the tab-temps pane; the heat PROBLEM line says (Temperatures tab); h22 crit, c2 no data" "[ \"\$(grep -o 'href=\"#tab-[a-z]*\"' $W/gc.html | head -n 4 | tr '\n' ' ')\" = 'href=\"#tab-connections\" href=\"#tab-slow\" href=\"#tab-temps\" href=\"#tab-nic\" ' ] && [ \$(awk '/class=\"tab-pane/ {inp = index(\$0, \"id=\\\"tab-temps\\\"\") > 0} inp && /card-header\">Temperatures/ {n++} END {print n + 0}' $W/gc.html) = 1 ] && grep -q '(Temperatures tab)' $W/gc.html && [ \$(grep -c '(Temperatures card)' $W/gc.html) = 0 ] && grep -qE 'h22.*crit\\+rise' $W/gc.html && grep -q 'c2' $W/gc.html && grep -q 'no temperature data' $W/gc.html" "rc=$prc $(grep -o 'href="#tab-[a-z]*"' $W/gc.html | head -n 4 | tr '\n' ' ') $(grep -o 'Temperatures[^<]*' $W/gc.html | head -n 2)"
# every BMC but c3's reads inlet 39 (high), so every host but c3 is HOT; c3 has no ipmitool and a cool CPU
chk "golden-C: dashboard: h22's two NIC rows carry the HOT mark (cpu crit), c3's row doesn't (control)" "[ \$(ROWS=1 node $H/rows.js $W/gc.html | grep -c '^h22(HOT) ') = 2 ] && [ \$(ROWS=1 node $H/rows.js $W/gc.html | grep -c '^c3 ') = 1 ] && grep -qE '\"heat\": \"cpu Package_id_0 [0-9.]+C crit\\+rise' $W/gc.html" "$(ROWS=1 node $H/rows.js $W/gc.html)"

# --- controls for the assertions made tolerant here (10-26): each must fail on a planted change of its input ---
rows=$(ROWS=1 node $H/rows.js $W/gc.html)
chk "golden-C control: the (HOT)-tolerant row count sees a missing h21 row (3, not 4)" "[ \$(awk '/^h21/ && !d {d = 1; next} {print}' <<<\"\$rows\" | grep -cE '^h2[12](\\(HOT\\))? ') = 3 ]" "$rows"
chk "golden-C control: the c1 OK(retr) match fails when c1 is plain OK" "! sed -E 's/^(c1[^ ]*) OK\\(retr\\)/\\1 OK/' <<<\"\$rows\" | grep -qxE 'c1(\\(HOT\\))? OK\\(retr\\)'" "$rows"
heat=$(grep -oE '\"heat\": \"cpu Package_id_0 [^\"]*' $W/gc.html | head -n 1)
chk "golden-C control: the heat match fails when the flag is high, not crit+rise" "[ -n \"\$heat\" ] && ! sed 's/crit+rise/high/' <<<\"\$heat\" | grep -qE '\"heat\": \"cpu Package_id_0 [0-9.]+C crit\\+rise'" "$heat"
# the fake climbs h22's CPU 6C per read, so the value tracks the tool's read count: pinned to the bundle, not a literal (10-27)
hmax=$(awk '$1 == "h22" && $6 == "Package_id_0" {print $8}' <<<"$ts"); hcpu=${heat%%,*}
chk "golden-C: the dashboard's heat value is h22's max from temps_summary.txt" "[ -n \"\$hmax\" ] && [ \"\$hcpu\" = \"\\\"heat\\\": \\\"cpu Package_id_0 ${hmax}C crit+rise\" ]" "heat='$heat' max='$hmax'"
chk "golden-C control: iteration 1's UC1 sum (500000) is half of both iterations' (1000000), so the iter1 filter matters" "[ \$(awk '\$2 == \"UC1\" && \$4 == \"198.19.10.1\" {t += \$12} END {print t + 0}' <<<\"\$ue\") = 1000000 ]" "$(awk '$2 == "UC1"' <<<"$ue")"

# --- from 27_sysinfo.sh's clean run: golden-C's backends carry no host-side fault ---
chk "golden-C: sysinfo: rail NIC config logged (clean backends)" "grep -q 'Rail NIC receive config: 4 NICs read; rx ring below its maximum on 0, PCIe link below its maximum on 0' <<<\"\$out\"" "$(grep 'receive config' <<<"$out")"
chk "golden-C: clean backends: no host flagged" "grep -q 'Host-side receive: 0 of 2 hosts flagged' <<<\"\$out\" && [ \$(bfile gc host_rx.txt | awk 'NR > 1 && \$NF != \"-\"' | wc -l) = 0 ]" "$(bfile gc host_rx.txt)"
crx() { bfile gc host_rx.txt | awk -v h=$1 -v c="$2" 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == c) k = i} $1 == h {print $k}'; }
chk "golden-C: clean: read counters are numbers, not -" "[ \"\$(crx h21 Softnet_drop) \$(crx h21 AER) \$(crx h21 NIC_discard)\" = '0 0 0' ]" "$(crx h21 Softnet_drop) $(crx h21 AER) $(crx h21 NIC_discard)"
chk "golden-C: receiver CPU is a number" "bfile gc host_rx.txt | awk 'NR == 1 {for (i = 1; i <= NF; i++) if (\$i == \"RcvCPU%\") k = i} \$1 == \"h21\" {print \$k}' | grep -q -E '^[0-9.]+\$'" "$(bfile gc host_rx.txt)"
finish
