#!/opt/homebrew/bin/bash
# a rail a host lacks or does not address (FF_NICS mode: no NIC x, no IPv4 on x) is a host property (10-27
# fleet: 112 GPU hosts with bond0 only made 224 rail rows and 113 "Rails not usable" lines): one counted line per
# rail and state in the log, no per-NIC row for it (table and dashboard); rails.txt keeps every host's row; any
# other bad rail (h4's B is link DOWN in the fake) keeps its full line and its row
# checks: 34
# secs: 95
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
tbl() { grep -E '^ +(Role|backend|client) ' <<<"$1"; }

out=$(xrun ab env FF_RAILS= FF_NICS=enp5s0np0,enp196s0np0 FAKE_NOIP_B=h2 FAKE_NONIC_B=h3 FF_HOSTS=198.18.0.1-4 FF_ITER=1 timeout 120 $B $C 1); rc=$?
chk "absent rails: one counted line each under Rails not usable (h2 no IPv4 on B, h3 no NIC B); h4's link DOWN keeps its full row" \
    "grep -q '^# Rails not usable (paths through them are skipped):' <<<\"\$out\" && grep -qx '#   1 host: rail B no IPv4 on enp196s0np0: h2' <<<\"\$out\" && grep -qx '#   1 host: rail B no NIC enp196s0np0: h3' <<<\"\$out\" && grep -qE '^#   h4 +198\.18\.0\.4 +enp5s0np0 .* link_DOWN_on_enp196s0np0$' <<<\"\$out\"" "rc=$rc $(grep -A4 'Rails not usable' <<<"$out" | tr '\n' '|')"
chk "per-NIC table: 6 backend rows (h1, h4 both rails; h2, h3 rail A; h4's B row with its state), none for an absent rail" \
    "[ \$(tbl \"\$out\" | grep -c '^ *backend ') = 6 ] && ! tbl \"\$out\" | grep -qE 'no_IPv4_on|no_NIC_' && tbl \"\$out\" | grep -qE '^ +backend +h4 +enp196s0np0 +198\.19\.2\.4 .* link_DOWN_on_enp196s0np0$'" "$(tbl "$out" | tr '\n' '|')"
chk "rails.txt keeps every host's row with the state (h2 no_IPv4_on_enp196s0np0, h3 no_NIC_enp196s0np0)" \
    "[ \$(bfile ab rails.txt | grep -c '^h[1-4] ') = 4 ] && bfile ab rails.txt | grep -qE '^h2 .* no_IPv4_on_enp196s0np0' && bfile ab rails.txt | grep -qE '^h3 .* - +none +- +no_NIC_enp196s0np0'" "$(bfile ab rails.txt)"
chk "the counts: Rails unusable 3 (h2 B, h3 B, h4 B) and skipped paths > 0, as before the collapse" \
    "grep -qE 'Rails unusable: 3 \(rails.txt\) \| TCP paths skipped: [1-9][0-9]* \(paths_excluded.txt\)' <<<\"\$out\"" "$(grep 'Rails unusable' <<<"$out")"
t=$(bundle ab); python3 $P "$t" $W/ab.html > $W/ab.out 2>&1
chk "dashboard: the same 6 backend rows, none for an absent rail; h4's B row carries its state" \
    "[ \$(ROWS=1 hrows $W/ab.html | grep -c '^h[1-4] ') = 6 ] && ! ROWS=1 hrows $W/ab.html | grep -qE 'no IPv4 on|no NIC ' && ROWS=1 hrows $W/ab.html | grep -q '^h4 DOWN'" "$(ROWS=1 hrows $W/ab.html | tr '\n' '|')"
chk "dashboard Not tested card: one counted rail row per rail and state (h2 no IPv4, h3 no NIC), h4's link-DOWN rail row kept, no per-host absent-rail row" \
    "grep -q '<tr><td>rail</td><td>1 host: rail B</td><td>no IPv4 on enp196s0np0: h2</td></tr>' $W/ab.html && grep -q '<tr><td>rail</td><td>1 host: rail B</td><td>no NIC enp196s0np0: h3</td></tr>' $W/ab.html && grep -q '<tr><td>rail</td><td>h4 rail B enp196s0np0 198.19.2.4</td><td>link DOWN on enp196s0np0</td></tr>' $W/ab.html && ! grep -qE '<td>h[23] rail B' $W/ab.html" "$(grep -o '<tr><td>rail</td><td>[^<]*</td><td>[^<]*</td></tr>' $W/ab.html | tr '\n' '|')"
chk "control: a planted 'no_NIC_' state in a rails.txt copy is collapsed by the awk alone (3 hosts: rail A no NIC x: a b c)" \
    "[ \"\$(printf 'Host Target Rail_A_NIC Rail_A_IP MTU_A State_A\na 1 - none - no_NIC_x\nb 2 - none - no_NIC_x\nc 3 - none - no_NIC_x\nd 4 - none - link_DOWN_on_x\n' | awk -f $(dirname $C)/src/awk/ff_main.bad_rails.awk | tr '\n' '|')\" = '3 hosts: rail A no NIC x: a b c|d 4 - none - link_DOWN_on_x|' ]"
# rail groups on that run: h1 and h4 hold A,B (h4's B is DOWN: it stays in the group, its B paths skip), h2 and h3 hold A only
chk "rail groups: h1 pairs with h4 (A,B), h2 with h3 (A); no pair across the groups" \
    "[ \"\$(bfile ab pairs.txt | tr '\n' '|')\" = '1 h1 h4|1 h2 h3|' ] && grep -q '^# Pairing: round-robin within 2 rail groups: AB 2 hosts, 1 pair/iteration; A 2 hosts, 1 pair/iteration; 1 iteration covers 2 of 2 host pairs$' <<<\"\$out\"" "$(bfile ab pairs.txt | tr '\n' '|') $(grep '^# Pairing' <<<"$out")"
skip1=$(grep -c '^#   skip ' <<<"$out")

# --- rail-aware pairing (a 10-27 field run: 24 storage hosts on A,B and 215 GPU hosts on C were paired across the
# groups in 24 of 119 pairs every iteration, every path in those pairs skipped, phase 2 and U2 ran nothing): three
# rails, h21-h24 hold A,B (no C NIC), h25-h30 hold C only, h32 holds A only (no C NIC, no IPv4 on B: it joins the A,B
# group, planned on A only), h31 holds A,C (no B NIC: no group has both, no partner); h21's rail A NIC is a bond whose
# two members see leaf1 (the bond itself reports no neighbour) ---
out=$(xrun rg env FF_RAILS= FAKE_RAILS=3 FF_NICS=enp5s0np0,enp196s0np0,enp65s0np0 FAKE_NO_C=h21,h22,h23,h24,h32 FAKE_NONIC_B=h31 FAKE_NOIP_B=h32 \
      FAKE_ONLY_C=h25,h26,h27,h28,h29,h30 FAKE_BOND_LLDP=h21 FF_HOSTS=198.18.0.21-32 FF_ITER=2 timeout 120 $B $C 1); rc=$?
chk "rail groups: PARTIAL rc=3 (h31 untested), hosts 11/12, every planned path ran (60/60: 16 in the groups, 44 across them), nothing skipped" \
    "[ $rc = 3 ] && grep -q '^RESULT coverage=PARTIAL hosts=11/12 paths=60/60 skipped=0 no_result=0 cross_rail=on' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
chk "rail groups: the planning lines name each group, its hosts and pairs per iteration, the joined host and its untested rail, and the lone host" \
    "grep -q '^# Pairing: round-robin within 3 rail groups: AB 5 hosts, 2 pairs/iteration, 1 sits out; C 6 hosts, 3 pairs/iteration; AC 1 host, no partner; 2 iterations cover 22 of 55 host pairs (all pairs need FF_ITER=5)$' <<<\"\$out\" && grep -q '^# 1 host lacks a rail and pairs within the hosts holding the rails it has: h32: rail B not addressed, tested on A only$' <<<\"\$out\" && grep -q '^# 1 host has no partner sharing its rails (not tested): h31$' <<<\"\$out\"" "$(grep -E '^# (Pairing|1 host)' <<<"$out")"
# cross-group (phase 3, 10-27): C (6) and AB (5) share no rail: 6 pairs per iteration, the C hosts rotating through
# the AB hosts (one AB host serves two pairs: its flows expected at 400/2); AC's h31 shares A with AB and C with C: no pair
chk "cross-group: the planning line names the group pair, its pairs per iteration, the rail pairs, the rounds to meet every pair and the partners covered" \
    "grep -q '^# Cross-group: C (6 hosts) <-> AB (5 hosts): 6 pairs/iteration, rails C<->A C<->B, every host pair after 5 iterations; 2 of 5 partners per host at FF_ITER=2 (phase 3: the groups share no rail, so the runs are routed; judged at the slower rail, shared NICs divided by their flows)$' <<<\"\$out\"" "$(grep '^# Cross-group' <<<"$out")"
pr=$(bfile rg pairs.txt)
grp() { awk '{g1 = ($2 ~ /^h(2[1-4]|32)$/) ? "AB" : "C"; g2 = ($3 ~ /^h(2[1-4]|32)$/) ? "AB" : "C"; print (g1 == g2 ? g1 : "cross")}' <<<"$1" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
chk "rail groups: pairs.txt has 22 rows: 4 within A,B (h32 among them), 6 within C, 12 across (a C host first, an A,B host second), none with h31; 22 distinct host pairs over the 2 iterations" \
    "[ \"\$(grp \"\$pr\")\" = 'AB=4 C=6 cross=12 ' ] && [ \$(awk '{print (\$2 < \$3 ? \$2 \" \" \$3 : \$3 \" \" \$2)}' <<<\"\$pr\" | sort -u | wc -l) = 22 ] && ! grep -q 'h31' <<<\"\$pr\" && [ \$(awk '\$2 ~ /^h(2[5-9]|30)$/ && \$3 ~ /^h(2[1-4]|32)$/' <<<\"\$pr\" | wc -l) = 12 ]" "$(grp "$pr") $(tr '\n' '|' <<<"$pr")"
p3=$(bfile rg iperf3_results.txt | awk '/^### / {ph = $3; next} /Gbits/ && ph == "phase:3"')
chk "cross-group: phase 3 ran, 44 result rows (per iteration: 5 pairs x 2 rail pairs x 2 ways + h32's pair x 1 x 2), every one between a C IP and an A or B IP, under 'rails:C-A' / 'rails:C-B' markers" \
    "[ \$(grep -c . <<<\"\$p3\") = 44 ] && [ \$(grep -c -E '^198\.19\.3\.[0-9]+,198\.19\.[12]\.[0-9]+,|^198\.19\.[12]\.[0-9]+,198\.19\.3\.[0-9]+,' <<<\"\$p3\") = 44 ] && [ \$(bfile rg iperf3_results.txt | grep -c '^### iteration:[12] phase:3 rails:C-[AB]$') = 4 ]" "$(head -n 2 <<<"$p3") markers: $(bfile rg iperf3_results.txt | grep -c 'phase:3')"
chk "cross-group: every phase 3 row carries exp:400 or exp:200 (the A,B host serving two pairs that iteration: 8 rows at 200 per iteration), judged in the XGrp column" \
    "[ \$(grep -c ' exp:400$' <<<\"\$p3\") = 28 ] && [ \$(grep -c ' exp:200$' <<<\"\$p3\") = 16 ] && grep -qE '^ +Role +Host +NIC +IP +Same +Cross +XGrp +Retr' <<<\"\$out\" && grep -qE '^ +backend +h25 +enp65s0np0 +198\.19\.3\.25 +[0-9.]+ +- +[0-9.]+ ' <<<\"\$out\"" "$(grep -c 'exp:' <<<"$p3") exp rows; $(grep -E '^ +backend +h25 ' <<<"$out")"
chk "cross-group: the summary lines per rail pair (C-A 24 flows, C-B 20 flows, all OK), U3 ran 44 UDP rows" \
    "grep -qE '^  Cross-group C-A: 24 flows, [0-9.]+ Gbps on average \(median [0-9.]+ Gbps per flow, expected 200 at the slower rail shared by its flows\): 24 OK, 0 SLOW, 0 CRITICAL$' <<<\"\$out\" && grep -qE '^  Cross-group C-B: 20 flows, .*: 20 OK, 0 SLOW, 0 CRITICAL$' <<<\"\$out\" && [ \$(bfile rg iperf3_udp_results.txt | awk '/^### / {ph = \$3; next} ph == \"phase:U3\" && /^198/' | wc -l) = 44 ]" "$(grep 'Cross-group' <<<"$out" | tr '\n' '|')"
chk "cross-group UDP: the loss accounting takes the third phase: a 'U3 loss:' line per iteration, 44 U3 rows in udp_expected.txt, U3 rows in udp_host_counters.txt" \
    "[ \$(grep -c '^#   U3 loss: ' <<<\"\$out\") = 2 ] && [ \$(bfile rg udp_expected.txt | awk '\$2 == \"U3\"' | wc -l) = 44 ] && [ \$(bfile rg udp_host_counters.txt | awk '\$2 == \"U3\"' | wc -l) -gt 0 ]" "$(grep 'U3 loss' <<<"$out" | tr '\n' '|') $(bfile rg udp_expected.txt | awk '$2 == "U3"' | wc -l) expected rows"
p2=$(bfile rg iperf3_results.txt | awk '/^### / {ph = $3; next} /Gbits/ && ph == "phase:2"')
chk "rail groups: phase 2 ran, 4 result rows (2 per pair of A,B hosts; h32's pairs have no cross-rail paths), every one between h21-h24" \
    "[ \$(grep -c . <<<\"\$p2\") = 4 ] && [ \$(grep -c -E '^198\.19\.[12]\.2[1-4],198\.19\.[12]\.2[1-4],' <<<\"\$p2\") = 4 ]" "$(head -n 3 <<<"$p2")"
chk "rail groups: U2 ran, 4 UDP rows, every one between h21-h24" \
    "[ \$(bfile rg iperf3_udp_results.txt | awk '/^### / {ph = \$3; next} ph == \"phase:U2\" && /^198/' | grep -c -E '^198\.19\.[12]\.2[1-4],198\.19\.[12]\.2[1-4],') = 4 ]" "$(bfile rg iperf3_udp_results.txt | grep -c '^198')"
chk "joined host: h32 runs on rail A only (2 phase-1 rows and 4 cross-group rows on 198.19.1.32, none on 198.19.2.32), no skip for its missing rail; no exp: token outside phase 3" \
    "[ \$(bfile rg iperf3_results.txt | awk '/^### / {ph = \$3; next} ph == \"phase:1\" && /198\.19\.1\.32/' | wc -l) = 2 ] && [ \$(grep -c '198\.19\.1\.32' <<<\"\$p3\") = 4 ] && [ \$(bfile rg iperf3_results.txt | grep -c '198\.19\.2\.32') = 0 ] && [ \$(bfile rg iperf3_results.txt | awk '/^### / {ph = \$3; next} ph != \"phase:3\" && / exp:/' | wc -l) = 0 ]" "$(bfile rg iperf3_results.txt | grep '\.32' | tr '\n' '|')"
chk "rail groups: no path skipped for a rail its pair lacks: 0 skip lines, paths_excluded.txt empty (control: the h1-h4 run above had $skip1 skip lines, h4's DOWN rail)" \
    "[ \$(grep -c '^#   skip ' <<<\"\$out\") = 0 ] && [ -z \"\$(bfile rg paths_excluded.txt)\" ] && [ $skip1 -gt 0 ]" "skip lines: $(grep -c '^#   skip ' <<<"$out"), control $skip1"
meta=$(bfile rg metadata.txt)
chk "rail groups: directed paths per host pair over the rails both hold (in the groups 86; across them 4 A,B hosts x 6 C x 4 + h32 x 6 x 2 = 108: 194, 60 planned), pairs_total 55, cross_group=on with 12 of 30 pairs covered" \
    "grep -q '^# Directed NIC paths: 60 of 194 planned (every direction on every NIC pair needs FF_ITER=10, or FF_ITER=all)$' <<<\"\$out\" && grep -qx 'directed_paths_total=194' <<<\"\$meta\" && grep -qx 'pairs_total=55' <<<\"\$meta\" && grep -qx 'cross_group=on' <<<\"\$meta\" && grep -qx 'cross_group_pairs_total=30' <<<\"\$meta\" && grep -qx 'cross_group_pairs_covered=12' <<<\"\$meta\"" "$(grep -E '^(directed|pairs|cross_group)' <<<"$meta" | tr '\n' ' ')"
chk "rail groups: each group's own circle: iteration 2 pairs differ from iteration 1 in both groups" \
    "[ \"\$(awk '\$1 == 1 && \$2 == \"h22\" {print \$3}' <<<\"\$pr\")\" != \"\$(awk '\$1 == 2 && \$2 == \"h22\" {print \$3}' <<<\"\$pr\")\" ] && [ \"\$(awk '\$1 == 1 && \$2 == \"h25\" {print \$3}' <<<\"\$pr\")\" != \"\$(awk '\$1 == 2 && \$2 == \"h25\" {print \$3}' <<<\"\$pr\")\" ]" "$(tr '\n' '|' <<<"$pr")"
# the bond's LLDP: one row per member with the bond's IP; the uplink summary counts the bond's runs under the members' leaf
chk "bond LLDP: h21's rail A has the bond row (unknown) and one row per member naming leaf1, all on the bond's IP" \
    "[ \"\$(bfile rg lldp_neighbors.txt | grep '^h21 ' | awk '{print \$2, \$3, \$4}' | tr '\n' '|')\" = 'enp5s0np0 198.19.1.21 unknown|ens1np0 198.19.1.21 leaf1.example|ens3np0 198.19.1.21 leaf1.example|enp196s0np0 198.19.2.21 leaf2.example|' ]" "$(bfile rg lldp_neighbors.txt | grep '^h21 ' | tr '\n' '|')"
chk "bond LLDP: the uplink summary has leaf1's phase 2 totals and no NIC left out for want of a neighbour (the bond's runs count under leaf1)" \
    "grep -q '^  Uplinks leaf1.example phase 2: out [0-9.]* [GT] / in ' <<<\"\$out\" && ! grep -q 'have no LLDP neighbour' <<<\"\$out\"" "$(grep -i uplink <<<"$out" | tr '\n' '|')"
render rg; prc=$?
# the hosts the pairing could not test in full: pairing.txt, and the dashboard's Not tested card from it
chk "pairing.txt: h32 tested on A only (rail B not addressed), h31 no partner sharing its rails; nothing else" \
    "[ \"\$(bfile rg pairing.txt | tr '\t' '=' | tr '\n' '|')\" = 'h32=rail B not addressed, tested on A only|h31=no partner sharing its rails|' ]" "$(bfile rg pairing.txt | tr '\n' '|')"
chk "dashboard Not tested card: a host row for h32 (tested on A only) and one for h31 (no partner); the 4 rail rows as before" \
    "grep -q '<tr><td>host</td><td>h32</td><td>rail B not addressed, tested on A only</td></tr>' $W/rg.html && grep -q '<tr><td>host</td><td>h31</td><td>no partner sharing its rails</td></tr>' $W/rg.html && grep -q 'Not tested — 6 rows' $W/rg.html" "$(grep -o 'Not tested — [0-9]* rows' $W/rg.html) $(grep -o '<tr><td>host</td><td>[^<]*</td><td>[^<]*</td></tr>' $W/rg.html | tr '\n' '|')"
# drop counters: expected = the rail NICs that exist (h21-h24 2 each, h25-h30 1, h31 2, h32 2 = 18), not hosts x rails (36)
chk "metadata: drop_nics_expected=18 (the NICs that exist, not 12 hosts x 3 rails = 36) = drop_nics_read_min; the dashboard has no 'Drop counters read on' note" \
    "grep -qx 'drop_nics_expected=18' <<<\"\$meta\" && grep -qx 'drop_nics_read_min=18' <<<\"\$meta\" && ! grep -q 'Drop counters read on' $W/rg.html" "$(grep drop_nics <<<"$meta" | tr '\n' ' ') $(grep -o 'Drop counters read on [^<]*' $W/rg.html)"
chk "cross-group: the dashboard note says 12 of 30 host pairs covered with the per-rail-pair flows, and the XGrp column is there" \
    "grep -q 'Cross-group runs (phase 3, between rail groups that share no rail, routed): 12 of 30 host pairs covered; C-A: 24 flows, median [0-9.]* Gbps, 24 OK; C-B: 20 flows, median [0-9.]* Gbps, 20 OK\.' $W/rg.html && grep -q 'XGrp<small>' $W/rg.html" "$(grep -o 'Cross-group runs[^<]*' $W/rg.html | head -n 1)"
chk "bond LLDP: the dashboard renders (rc 3: PARTIAL) and its topology links h21 to leaf1 through a bond node and both members (ens1np0 on swp21, ens3np0 on swp121; no bonds.txt row, so 2 of 2 up)" \
    "[ $prc = 3 ] && [ \"\$(grep '^    var topoEdgesData = ' $W/rg.html | sed 's/^    var topoEdgesData = //; s/;\$//' | jq -c '[.[] | select(.from == \"h21|enp5s0np0\") | [.to, .label, .panel.kind, .panel.port_id, .panel.member_down]] | sort')\" = '[[\"leaf1.example\",\"ens1np0\",\"member\",\"swp21\",false],[\"leaf1.example\",\"ens3np0\",\"member\",\"swp121\",false]]' ] && grep -q '\"from\": \"h21\", \"to\": \"h21|enp5s0np0\"' $W/rg.html" "rc=$prc $(tail -n 2 $W/rg.pout)"
# --- cross-group under waves, unrouted, and without load (the same fixture; FF_UDP=0 to keep them short) ---
XG='FF_RAILS= FAKE_RAILS=3 FF_NICS=enp5s0np0,enp196s0np0,enp65s0np0 FAKE_NO_C=h21,h22,h23,h24,h32 FAKE_NONIC_B=h31 FAKE_NOIP_B=h32 FAKE_ONLY_C=h25,h26,h27,h28,h29,h30 FF_HOSTS=198.18.0.21-32'
# FF_CROSS_MAX=6: 12 flows per rail pair run in 2 waves; a smaller-group host's share is the flows its NIC carries in ITS
# wave (on the committed build before this check the share was counted over the iteration: 16 rows at exp:200 under
# waves; per wave it is exactly the rows whose A,B IP appears twice in that wave's block)
out=$(xrun xw env $XG FF_ITER=2 FF_CROSS_MAX=6 FF_UDP=0 timeout 180 $B $C 1); rc=$?
r3=$(bfile xw iperf3_results.txt)
bad=$(awk -F'[, ]+' '/^### / { ph = $3; blk++; next } ph != "phase:3" { next }
    { for (i = 1; i <= NF; i++) if ($i ~ /^exp:/) e[blk, NR] = substr($i, 5)
      ip = ($1 ~ /^198\.19\.[12]\./) ? $1 : $2; if ($2 == ip) n[blk, ip]++; k[NR] = blk SUBSEP ip; rows[NR] = 1 }
    END { for (r in rows) { split(k[r], q, SUBSEP); want = 400 / n[q[1], q[2]]; got = e[q[1], r] + 0; if (got != want) b++ }; print b + 0 }' <<<"$r3")
chk "cross-group in waves (FF_CROSS_MAX=6): 8 wave markers, 44 rows; every row's exp: is 400 / (pairs its A,B host serves in that wave, counted as flows into it): 0 rows off" \
    "[ $rc = 3 ] && [ \$(grep -c '^### iteration:[12] phase:3 rails:C-[AB] wave:[12]/2$' <<<\"\$r3\") = 8 ] && [ \$(awk '/^### / {ph = \$3; next} ph == \"phase:3\" && /Gbits/' <<<\"\$r3\" | wc -l) = 44 ] && [ \"\$bad\" = 0 ]" "rc=$rc off=$bad $(grep 'phase:3' <<<"$r3" | head -n 2 | tr '\n' '|')"
chk "control: with the share counted over the iteration (the committed build's rule) 16 of the 44 rows would say exp:200; per wave 8 do" \
    "[ \$(awk '/^### / {ph = \$3; next} ph == \"phase:3\" && / exp:200$/' <<<\"\$r3\" | wc -l) = 8 ]" "$(awk '/^### / {ph = $3; next} ph == "phase:3" && / exp:200$/' <<<"$r3" | wc -l) at 200"
# FAKE_NOXROUTE: no route between different /24s, so every cross-rail and every cross-group check fails on routing
out=$(xrun xu env $XG FF_ITER=1 FAKE_NOXROUTE=1 FF_UDP=0 timeout 120 $B $C 1); rc=$?
meta=$(bfile xu metadata.txt); render xu; prc=$?
chk "cross-group unrouted: the WARNING names all 22 checks, cross_group=unrouted beside cross_rail=unrouted, the 22 phase-3 skips in paths_excluded.txt (of 24), the dashboard's problem line" \
    "[ $rc = 3 ] && grep -q '^# WARNING: the rail groups are not routed to each other (all 22 cross-group path checks failed on routing, no same-rail one did): either separate fabrics by design (rerun with FF_CROSS_RAIL=0) or routing between the groups missing on every host. The skips count until you say which.$' <<<\"\$out\" && grep -qx 'cross_group=unrouted' <<<\"\$meta\" && grep -qx 'cross_rail=unrouted' <<<\"\$meta\" && [ \$(bfile xu paths_excluded.txt | awk '\$2 == 3' | wc -l) = 22 ] && [ \$(bfile xu paths_excluded.txt | wc -l) = 24 ] && [ $prc = 3 ] && grep -q 'Rail groups not routed to each other: every cross-group path check failed on routing, no same-rail one did\.' $W/xu.html" "rc=$rc prc=$prc $(grep -E 'cross_|^RESULT' <<<"$meta $out" | tr '\n' '|')"
# FF_SKIP_IPERF=1: the phase-3 path checks count as paths (30 = 8 in the groups + 22 across), nothing judged, no exp: token
out=$(xrun xs env $XG FF_ITER=1 FF_SKIP_IPERF=1 timeout 120 $B $C 1); rc=$?
meta=$(bfile xs metadata.txt)
chk "cross-group without load (FF_SKIP_IPERF=1): 30 of 30 path checks OK (22 of them phase 3), paths_ok=30, cross_group=on, no exp: token and no result row anywhere" \
    "[ $rc = 3 ] && grep -q 'Path checks (route, ping, MTU no-fragment): 30 of 30 planned OK' <<<\"\$out\" && grep -qx 'paths_ok=30' <<<\"\$meta\" && grep -qx 'paths_planned=30' <<<\"\$meta\" && grep -qx 'cross_group=on' <<<\"\$meta\" && [ \$(bfile xs iperf3_results.txt | grep -c 'exp:\|Gbits') = 0 ]" "rc=$rc $(grep -E 'paths|cross_group' <<<"$meta" | tr '\n' ' ')"

# no LLDP anywhere and no uplinks declared (the 10-27 field run): the NICs left out are still said, in the log and the dashboard
out=$(xrun nl FAKE_NO_LLDP=all FF_HOSTS=198.18.0.21-22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
render nl; prc=$?
chk "no LLDP, nothing declared: the log says 4 of 4 rail NICs have no LLDP neighbour and 4 runs are left out; the dashboard note says the same (control: the run above printed no such line)" \
    "grep -qx '  Uplinks: 4 of 4 rail NICs have no LLDP neighbour; their 4 runs are left out of the leaf totals.' <<<\"\$out\" && grep -q '4 of 4 rail NICs have no LLDP neighbour; their 4 runs are left out of the leaf totals.' $W/nl.html && [ $prc = 0 ]" "rc=$rc prc=$prc $(grep -i 'lldp' <<<"$out" | tr '\n' '|')"
finish
