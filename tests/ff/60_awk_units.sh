#!/opt/homebrew/bin/bash
# src/awk programs fed fixture files directly: no collector run, no fake ssh (10-26 restructure). Each driver
# passes the call site's -F/-v list (the comment above it maps it) and runs under bsd, mawk and gawk; the three must
# agree. Each group of checks has a planted-bug control: a copy of the program with one line changed must fail them.
# Fixtures: fixtures/units/ (hand-written, small; FF's own work files never reach a bundle, so their format is guarded
# by the golden groups' end-to-end checks) and fixtures/golden-B|C/ (bundle members, compared fresh in 50 and 52).
# tier: fast
# checks: 77
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
A=$(cd "$(dirname "$C")" && pwd)/src/awk; U=$S/fixtures/units; AWKBIN=$S/awkbin
# uf <name> <program file> awk-options... -- files...: runs it under the three awks and prints bsd's output; an awk
# that differs is noted for awkagree "<name>"
uf() { local n=$1 prog=$2 v o b=; shift 2; local -a opts=() files=(); local sep=0 a
    for a in "$@"; do if [[ $a == -- ]]; then sep=1; elif (( sep )); then files+=("$a"); else opts+=("$a"); fi; done
    for v in bsd mawk gawk; do o=$(PATH=$AWKBIN/$v:$PATH awk "${opts[@]}" -f "$prog" "${files[@]}" 2>&1); [[ $v == bsd ]] && b=$o
        [[ $o == "$b" ]] || echo "$n ($v)" >> $W/awkdiff; done
    printf '%s\n' "$b"; }
awkagree() { chk "$1: bsd, mawk and gawk give the same output" "! grep -qF -- '$1' $W/awkdiff 2>&1" "$(grep -F -- "$1" $W/awkdiff 2>&1)"; }
: > $W/awkdiff
# control for awkagree (10-26: an empty awkdiff proves nothing alone): a program whose output differs by awk
# (PROCINFO is gawk's) must land in awkdiff and fail awkagree's test
echo 'BEGIN { print PROCINFO["version"] }' > $W/differs.awk; uf "awkagree control" $W/differs.awk -- > $W/differs.out
chk "awkagree control: an awk-dependent program is caught (gawk differs)" "grep -qF 'awkagree control (gawk)' $W/awkdiff && ! grep -qF 'awkagree control (mawk)' $W/awkdiff" "$(cat $W/awkdiff)"
: > $W/awkdiff   # the control's lines out, so the real checks start from an empty list

# --- ff_nic_sum (was 11, 12): Status = the worst column's share of expected; (cross) when only Cross is that bad ---
# call site src/fabric_ferret.sh: awk -F'[, ]+' -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT"
#   -v rl="$FF_RETR_PCT" -v cl=${#CLI[@]} "$NIC_SUM_AWK" "$WORK/dnmap" "$RESULTS" <client results | cres0>
nicsum() { local prog=$1 lines=$2 res=$3; uf "nic_sum $res" "$prog" -F'[, ]+' -v lines="$lines" -v ok=75 -v slow=50 -v rl=0.1 -v cl=0 -- $U/dnmap_2x2.txt $U/$res $U/empty.txt; }
st() { awk -v ip=$2 '$6 == ip {print $NF}' <<<"$1"; }   # a row's Status by IP (col 1-2 sort key, 3 Role, 4 Host, 5 NIC, 6 IP)
for prog in $A/ff_nic_sum.awk bug; do
    if [[ $prog == bug ]]; then sed 's/if (lv > w) w = lv/if (w < 0 || lv < w) w = lv/' $A/ff_nic_sum.awk > $W/nic_sum.bug.awk; prog=$W/nic_sum.bug.awk; tag="planted bug (best column, not worst): "; else tag=; fi
    # phase 3 (cross-group) rows carry exp:; judged in the XGrp column (-v xg=1), suffix (xgrp) when only that column is bad
    o=$(uf "nic_sum res_xgrp.txt" "$prog" -F'[, ]+' -v lines="A=400 B=400 C=400" -v ok=75 -v slow=50 -v rl=0.1 -v cl=0 -v xg=1 -- $U/dnmap_xgrp.txt $U/res_xgrp.txt $U/empty.txt)
    cols=$(awk '$6 == "198.19.1.21" {print $7, $8, $9}' <<<"$o")
    r="[ \"$(st "$o" 198.19.1.21)\" = 'SLOW(xgrp)' ] && grep -qE '^0 0 Role Host NIC IP Same Cross XGrp Retr' <<<\"\$o\" && [ \"$cols\" = '380.0 - 200.0' ]"
    if [[ -n $tag ]]; then chk "${tag}nic_sum unit: a slow cross-group run must not pass" "! $r" "$o"; else
        chk "nic_sum unit: h21-A at 200 of exp:400 in phase 3, Same OK: SLOW(xgrp), XGrp column 200.0" "$r" "$o"
        chk "nic_sum unit: h22-B slow in Cross (240/400) and in XGrp (200/400): SLOW(cross,xgrp); h22-A cross only: SLOW(cross)" "[ \"$(st "$o" 198.19.2.22) $(st "$o" 198.19.1.22)\" = 'SLOW(cross,xgrp) SLOW(cross)' ]" "$o"
        chk "nic_sum unit: control: h21-B at 390 of exp:400 in phase 3 and Same OK carries no suffix: OK" "[ \"$(st "$o" 198.19.2.21)\" = OK ]" "$o"; fi
    o=$(nicsum $prog "A=400 B=400" res_slowcross.txt)
    r="[ \"$(st "$o" 198.19.1.21) $(st "$o" 198.19.2.22) $(st "$o" 198.19.2.21) $(st "$o" 198.19.1.22)\" = 'SLOW(cross) SLOW(cross) OK OK' ]"
    if [[ -n $tag ]]; then chk "${tag}nic_sum unit: slow cross must not pass" "! $r" "$o"; continue; fi
    chk "nic_sum unit: slow cross only (A 360, B 380, cross 240): the cross NICs SLOW(cross), the other two OK" "$r" "$o"
    o=$(nicsum $prog "A=400 B=400" res_bslow.txt)
    chk "nic_sum unit: B at 52%: both rail B NICs SLOW, no (cross); rail A NICs OK" "[ \"$(st "$o" 198.19.2.21) $(st "$o" 198.19.2.22) $(st "$o" 198.19.1.21) $(st "$o" 198.19.1.22)\" = 'SLOW SLOW OK OK' ]" "$o"
    o=$(nicsum $prog "A=400 B=50" res_routed32.txt)
    chk "nic_sum unit: cross runs kept out of rail B's Same (48.0), own Cross column, judged at the slower rail: all OK" "[ \"$(awk '$6 ~ /^198\.19\.2\./ {print $7}' <<<"$o" | tr '\n' ' ')\" = '48.0 48.0 ' ] && [ \"$(awk 'NR > 1 {print $NF}' <<<"$o" | sort -u)\" = OK ]" "$o"
    o=$(nicsum $prog "A=400 B=400" res_xcrit.txt)
    chk "nic_sum unit: every cross run at 40: the two NICs on it CRITICAL(cross), the other two OK" "[ \"$(st "$o" 198.19.1.21) $(st "$o" 198.19.2.22) $(st "$o" 198.19.2.21) $(st "$o" 198.19.1.22)\" = 'CRITICAL(cross) CRITICAL(cross) OK OK' ]" "$o"
done
awkagree "nic_sum res_slowcross.txt"; awkagree "nic_sum res_bslow.txt"; awkagree "nic_sum res_routed32.txt"; awkagree "nic_sum res_xcrit.txt"; awkagree "nic_sum res_xgrp.txt"

# --- ff_cross_summary(.flows) (was 12): the inter-rail total and the shared-path line ---
# call sites src/sh/ff_results.sh cross_summary: x=$(awk -F'[, ]+' '#@awk ff_cross_summary.flows' ipmap results)
#   then awk -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v cm="${FF_CROSS_MAX:-0}" '#@awk ff_cross_summary' <<<"$x"
xs() { uf "cross_summary.flows $2" $A/ff_cross_summary.flows.awk -F'[, ]+' -- $U/ipmap_2x2.txt $U/$2 > $W/x.$2
       uf "cross_summary $2" "$1" -v lines="A=400 B=400" -v ok=75 -v cm=0 -- $W/x.$2; }
o=$(xs $A/ff_cross_summary.awk res_slowcross.txt)
chk "cross_summary unit: slow cross: total 480 over 2 flows, one each way, median 240" "grep -qE '^  Cross-rail total: 480\.0 Gbps over 2 flows run at once \(A->B 1, B->A 1\); median 240\.0 Gbps per flow; retransmits [0-9]+ cross-rail vs [0-9]+ same-rail\$' <<<\"\$o\"" "$o"
chk "cross_summary unit: slow cross, same-rail OK: the shared-path line" "grep -qE '^  Same-rail runs are OK, cross-rail runs are not: cross-rail median 240\.0 Gbps per flow \(OK >= 300\), same-rail median 360\.0 \(A\) / 380\.0 \(B\) Gbps\. .*shared path between the rails' <<<\"\$o\"" "$o"
o=$(xs $A/ff_cross_summary.awk res_bslow.txt)
chk "cross_summary unit: cross at line rate: total 800, no shared-path line" "grep -q '^  Cross-rail total: 800.0 Gbps over 2 flows' <<<\"\$o\" && ! grep -q 'Same-rail runs are OK, cross-rail' <<<\"\$o\"" "$o"
sed 's/xm + 0 < cx \&\& any \&\& allok/xm + 0 > cx \&\& any \&\& allok/' $A/ff_cross_summary.awk > $W/cross_summary.bug.awk
o=$(xs $W/cross_summary.bug.awk res_slowcross.txt)
chk "planted bug (shared-path test inverted): cross_summary unit's shared-path check must not pass" "! grep -q 'Same-rail runs are OK, cross-rail runs are not' <<<\"\$o\"" "$o"
awkagree "cross_summary.flows res_slowcross.txt"; awkagree "cross_summary res_slowcross.txt"

# --- ff_main.rail_speed (was 06's tie loop): a speed tie on one rail takes the higher speed, under every awk ---
# call site src/fabric_ferret.sh: read -r -a MODE <<<"$(awk -v L="${LETTERS:0:NR}" '#@awk ff_main.rail_speed'
#   "$WORK/iprail" "$NIC_DIAG")"  (iprail: "host nic rail" per tested host and usable rail; NIC_DIAG: nic_diagnostics.txt)
#   prints per rail "mode/voters/total" (the most common speed, NICs at it, NICs that voted)
for v in bsd mawk gawk; do
    o=$(PATH=$AWKBIN/$v:$PATH awk -v L=AB -f $A/ff_main.rail_speed.awk $U/iprail_tie.txt $U/nicdiag_tie.txt)
    chk "rail_speed unit, awk=$v: h1 B 50G and h3 B 200G tie, the higher wins: '400/2/2 200/1/2'" "[ \"$o\" = '400/2/2 200/1/2 ' ]" "[$o]"
done
sed 's/ || (n\[k\] == c\[r\] \&\& v > m\[r\])//' $A/ff_main.rail_speed.awk > $W/rail_speed.bug.awk
o=$(for v in bsd mawk gawk; do PATH=$AWKBIN/$v:$PATH awk -v L=AB -f $W/rail_speed.bug.awk $U/iprail_tie.txt $U/nicdiag_tie.txt; echo; done)
chk "planted bug (tie-break removed): some awk gives rail B 50, not 200" "grep -q '^400/2/2 50/1/2 \$' <<<\"\$o\"" "$o"
# 10-27 GPU fleet (synthetic names and addresses): 112 hosts with bond0 only (ens1np0 a member with no IPv4,
# no ens769np0), one storage host with rails A and B at 400G; 7 bonds at 400G. iprail_gpu.txt holds the usable rails
# only; iprail_gpu_ip.txt is the old "ip rail" form (225 "none" lines) for the IP-keyed awks kept as the planted bug
for v in bsd mawk gawk; do
    o=$(PATH=$AWKBIN/$v:$PATH awk -v L=ABC -f $A/ff_main.rail_speed.awk $U/iprail_gpu.txt $U/nicdiag_gpu.txt)
    chk "rail_speed unit, awk=$v: GPU fleet votes A 400 (1 of 1), B 400 (1 of 1), C 800 (105 of 112); the 112 IP-less ens1np0 vote nowhere" "[ \"$o\" = '400/1/1 400/1/1 800/105/112 ' ]" "[$o]"
    o=$(PATH=$AWKBIN/$v:$PATH awk -v lines="A=800 B=800 C=800" -f $A/ff_main.speed_mismatch.awk $U/iprail_gpu.txt $U/nicdiag_gpu.txt)
    chk "speed_mismatch unit, awk=$v: 9 off-speed lines: 7 bond0 (rail C) and stor001's ens1np0 (rail A), ens769np0 (rail B); no IP-less NIC" \
        "[ \$(wc -l <<<\"\$o\" | tr -d ' ') = 9 ] && [ \$(grep -c 'bond0 400000Mb/s (rail C)\$' <<<\"\$o\") = 7 ] && grep -qx '#   stor001 ens1np0 400000Mb/s (rail A)' <<<\"\$o\" && grep -qx '#   stor001 ens769np0 400000Mb/s (rail B)' <<<\"\$o\" && ! grep -q 'gpu[0-9]* ens1np0' <<<\"\$o\"" "$o"
done
o=$(awk -v lines="A=800 B=800 C=800" -f $U/speed_mismatch_ipkeyed.awk $U/iprail_gpu_ip.txt $U/nicdiag_gpu.txt)
chk "planted bug (the IP-keyed awk of 46c0374 on the old iprail): the 112 IP-less gpu ens1np0 get a rail letter (whichever 'none' line came last; rail B in the operator's log)" "[ \$(grep -c 'gpu[0-9]* ens1np0 400000Mb/s (rail [ABC])\$' <<<\"\$o\") = 107 ]" "$(wc -l <<<"$o" | tr -d ' ') lines; $(head -n 1 <<<"$o")"   # 107: 5 of the 112 report speed Unknown! and no awk lists those

# --- ff_udp_attr (was 05, 15): the loss placed into buckets; backlog drops not counted twice in the NIC bucket ---
# call site src/sh/ff_hostrx.sh udp_attr: awk -v t="$1" "$UDP_ATTR_AWK" udp_expected.txt "$WORK/uipmap" "$WORK/unicmap"
#   "$UDP_RESULTS" udp_host_counters.txt udp_nic_drops.txt  ->  "lost sent socket nic backlog unaccounted over expected beyond tx"
G=$S/fixtures/golden-B
ux() { uf "udp_attr $2 $3 $4" "$1" -v t= -- $G/udp_expected.txt $U/uipmap_B.txt $U/unicmap_B.txt "$2" "$3" "$4"; }
o=$(ux $A/ff_udp_attr.awk $G/iperf3_udp_results.txt $G/udp_host_counters.txt $G/udp_nic_drops.txt)
chk "udp_attr unit: golden-B's UDP: lost 4260 of 10000000, socket 4000, NIC 28, backlog 0, unaccounted 232" "[ \"$o\" = '4260 10000000 4000 28 0 232 0 0 232 0' ]" "$o"
o=$(ux $A/ff_udp_attr.awk $G/iperf3_udp_results.txt $U/udp_host_counters_kern.txt $U/udp_nic_drops_kern.txt)
chk "udp_attr unit: h2's backlog drops also in rx_dropped (the kernel's way): NIC stays 28, backlog 4000" "[ \"$(cut -d' ' -f4,5 <<<"$o")\" = '28 4000' ]" "$o"
sed 's/nk = DR\[k\] - BK\[k\]/nk = DR[k]/' $A/ff_udp_attr.awk > $W/udp_attr.bug.awk
o=$(ux $W/udp_attr.bug.awk $G/iperf3_udp_results.txt $U/udp_host_counters_kern.txt $U/udp_nic_drops_kern.txt)
chk "planted bug (backlog not taken out of rx_dropped): the NIC bucket counts them twice" "[ \"$(cut -d' ' -f4 <<<"$o")\" != 28 ]" "$o"
o=$(ux $A/ff_udp_attr.awk $U/udp_results_lost1.txt $G/udp_host_counters.txt $G/udp_nic_drops.txt)
chk "udp_attr unit: host counters above the loss (1 lost per run, h2's socket +1000): 'over' says so" "[ \"$(cut -d' ' -f7 <<<"$o")\" -gt 0 ]" "$o"
awkagree "udp_attr $G/iperf3_udp_results.txt $G/udp_host_counters.txt $G/udp_nic_drops.txt"
awkagree "udp_attr $G/iperf3_udp_results.txt $U/udp_host_counters_kern.txt $U/udp_nic_drops_kern.txt"

# --- ff_uplink (was 14's log lines): per-leaf uplink totals and the two verdicts ---
# call site src/sh/ff_results.sh uplink_summary: awk -F'[, ]+' -v mode= -v C="$UPLINK_GBPS" -v CC=... -v N="$FF_SPINES"
#   -v M="$FF_SPINE_LINKS" -v S="$FF_SPINE_GBPS" -v CM -v CS -v lines="$RAIL_LINES" -v cgb -v ok -v slow "$UPLINK_AWK"
#   ipmap lldp_neighbors nic_diagnostics results   (UPLINK_GBPS = spines x links x Gbps, 0 when not declared)
up() { uf "uplink $*" $A/ff_uplink.awk -F'[, ]+' -v mode= -v C=$1 -v CC=0 -v N=$2 -v M=$3 -v S=$4 -v CM= -v CS= -v lines="A=400 B=400" -v cgb=0 -v ok=75 -v slow=50 -- $U/ipmap_$5.txt $U/$6 $U/diag_$5.txt $U/$7; }
o=$(up 300 1 1 300 2x2 lldp_2x2.txt res_slowcross.txt)
chk "uplink unit: at capacity: verdict (a) per leaf, 80% of 300 G, oversubscribed 2.7:1" "[ \$(grep -c -E '^  Uplinks leaf[12]\.example phase 2: out 240\.0 G / in 240\.0 G of 300\.0 G declared \(80%\); downlinks 800\.0 G, oversubscribed 2\.7:1\$' <<<\"\$o\") = 2 ] && [ \$(grep -c 'at declared uplink capacity: oversubscribed 2.7:1 by design' <<<\"\$o\") = 2 ]" "$o"
o=$(up 4000 2 2 1000 2x2 lldp_2x2.txt res_slowcross.txt)
chk "uplink unit: far below capacity: verdict (b), 6%, ECMP uneven" "[ \$(grep -c -E '^    uplinks carried only 6% of declared capacity while cross-leaf runs were slow \(median 240\.0 Gbps, OK >= 300\) and same-leaf runs were OK .*ECMP is uneven\$' <<<\"\$o\") = 2 ]" "$o"
o=$(up 0 none none none 2x2 lldp_2x2.txt res_slowcross.txt)
chk "uplink unit: not declared: totals, no capacity, no verdict" "grep -q 'Uplink totals per leaf (set FF_SPINES, FF_SPINE_LINKS, FF_SPINE_GBPS to judge' <<<\"\$o\" && [ \$(grep -c -E '^  Uplinks leaf[12]\.example phase 2: out 240\.0 G / in 240\.0 G; downlinks 800\.0 G\$' <<<\"\$o\") = 2 ] && ! grep -q -E 'oversubscribed|ECMP' <<<\"\$o\"" "$o"
o=$(up 300 1 1 300 4x2 lldp_4_noh24.txt res_4_slowcross.txt)
chk "uplink unit: NICs without LLDP counted and left out (h24: 2 of 8, its 4 runs)" "grep -q '^  Uplinks: 2 of 8 rail NICs have no LLDP neighbour; their 4 runs are left out of the leaf totals.' <<<\"\$o\" && [ \$(grep -c '^  Uplinks leaf' <<<\"\$o\") = 2 ]" "$o"
o=$(up 300 1 1 300 2x2 lldp_none.txt res_slowcross.txt)
chk "uplink unit: no LLDP at all, check skipped, nothing judged" "grep -q '^  Uplink check skipped: it needs LLDP' <<<\"\$o\" && ! grep -q -E '^  Uplinks leaf|^    (at declared|uplinks carried)' <<<\"\$o\"" "$o"
o=$(up 0 none none none 2x2 lldp_none.txt res_slowcross.txt)
# (was "no uplink lines": a 10-27 field run with no LLDP and nothing declared dropped 285 runs in silence)
chk "uplink unit: not declared, no LLDP: the left-out line and nothing else" "[ \"\$o\" = '  Uplinks: 4 of 4 rail NICs have no LLDP neighbour; their 4 runs are left out of the leaf totals.' ]" "$o"
# a bond: its own LLDP row is unknown, its members name the leaf on the bond's IP (a 10-27 fleet: 215 bond rows unknown,
# 208 member rows named a leaf); the bond's runs count under the members' leaf, so the totals equal the plain 2x2 case
o=$(up 300 1 1 300 2x2 lldp_bond_2x2.txt res_slowcross.txt)
chk "uplink unit: h21's bond keyed by its members' leaf: the same leaf1/leaf2 totals as the plain run, no NIC left out" "[ \$(grep -c -E '^  Uplinks leaf[12]\.example phase 2: out 240\.0 G / in 240\.0 G of 300\.0 G declared \(80%\)' <<<\"\$o\") = 2 ] && ! grep -q 'no LLDP neighbour' <<<\"\$o\"" "$o"
o=$(up 300 1 1 300 2x2 lldp_mlag_2x2.txt res_slowcross.txt)
chk "uplink unit: members on two leaves (MLAG pair): the IP's leaf is 'leaf1.example+leaf1b.example'" "grep -q -E '^  Uplinks leaf1\.example\+leaf1b\.example phase 2: out 240\.0 G / in 240\.0 G of 300\.0 G declared \(80%\)' <<<\"\$o\" && ! grep -q 'no LLDP neighbour' <<<\"\$o\"" "$o"
awkagree "uplink 300 1 1 300 2x2 lldp_bond_2x2.txt res_slowcross.txt"; awkagree "uplink 300 1 1 300 2x2 lldp_mlag_2x2.txt res_slowcross.txt"
sed 's/if (lx > 0 \&\& pct >= ok \&\& xm < lx)/if (lx > 0 \&\& pct >= ok \&\& xm > lx)/' $A/ff_uplink.awk > $W/uplink.bug.awk
o=$(uf "uplink bug" $W/uplink.bug.awk -F'[, ]+' -v mode= -v C=300 -v CC=0 -v N=1 -v M=1 -v S=300 -v CM= -v CS= -v lines="A=400 B=400" -v cgb=0 -v ok=75 -v slow=50 -- $U/ipmap_2x2.txt $U/lldp_2x2.txt $U/diag_2x2.txt $U/res_slowcross.txt)
chk "planted bug (verdict (a) test inverted): the at-capacity line is gone" "! grep -q 'at declared uplink capacity' <<<\"\$o\"" "$o"
awkagree "uplink 300 1 1 300 2x2 lldp_2x2.txt res_slowcross.txt"; awkagree "uplink 300 1 1 300 4x2 lldp_4_noh24.txt res_4_slowcross.txt"

# --- ff_main.client_totals (was 35's fg/ft runs): all-at-once totals below 1 Tbps in Gbps, above in Tbps ---
# call site src/fabric_ferret.sh: awk '#@awk ff_main.client_totals' "$WORK/csum"  (csum: CLIENT_SUM_AWK's output; its
#   "#TOTAL phase flows avg lowest iterations" rows)
o=$(uf "client_totals fg" $A/ff_main.client_totals.awk -- $U/csum_fg.txt)
chk "client_totals unit: 5 x 10G all at once: '50.0 Gbps in total', no Tbps" "grep -qE '^  All at once, clients -> backends: 5 flows, 50\.0 Gbps in total' <<<\"\$o\" && ! grep -q 'Tbps' <<<\"\$o\"" "$o"
o=$(uf "client_totals ft" $A/ff_main.client_totals.awk -- $U/csum_ft.txt)
chk "client_totals unit: 5 x 300G: '1.50 Tbps in total' (control)" "grep -qE '^  All at once, clients -> backends: 5 flows, 1\.50 Tbps in total' <<<\"\$o\"" "$o"
sed 's/g >= 1000 ?/g >= 10 ?/' $A/ff_main.client_totals.awk > $W/client_totals.bug.awk
o=$(uf "client_totals bug" $W/client_totals.bug.awk -- $U/csum_fg.txt)
chk "planted bug (Tbps from 10 G): the 50 G total no longer prints in Gbps" "! grep -q '50\.0 Gbps in total' <<<\"\$o\"" "$o"

# --- ff_main.client_offspeed (was 35's cg/cgu/cg2 runs): client NICs not at FF_CLIENT_GBPS ---
# call site src/fabric_ferret.sh: awk -v w="$(( FF_CLIENT_GBPS * 1000 ))Mb/s" '#@awk ff_main.client_offspeed'
#   "$COLLECT_DIR/clients.txt" > "$WORK/coffspeed"
o=$(uf "client_offspeed cg" $A/ff_main.client_offspeed.awk -v w=100000Mb/s -- $U/clients_cg.txt)
chk "client_offspeed unit: FF_CLIENT_GBPS=100: c1-c3 bond0 (200G) listed, c4 (100G) not" "[ \$(grep -cE '^#   c[1-3] bond0 .* 200000Mb/s' <<<\"\$o\") = 3 ] && ! grep -qE '^#   c4 ' <<<\"\$o\"" "$o"
o=$(uf "client_offspeed cgu" $A/ff_main.client_offspeed.awk -v w=100000Mb/s -- $U/clients_cgu.txt)
chk "client_offspeed unit: c2 speed unknown: not listed (as backends), c1 and c3 are" "! grep -qE '^#   c2 ' <<<\"\$o\" && [ \$(grep -cE '^#   c[13] bond0 ' <<<\"\$o\") = 2 ]" "$o"
o=$(uf "client_offspeed cg2" $A/ff_main.client_offspeed.awk -v w=200000Mb/s -- $U/clients_cg2.txt)
chk "client_offspeed unit: FF_CLIENT_GBPS=200 with only 200G bonds: nothing listed (control)" "[ -z \"\$o\" ]" "$o"
sed 's#\$7 ~ /^\[0-9\]+Mb\\/s\$/ && ##' $A/ff_main.client_offspeed.awk > $W/client_offspeed.bug.awk
o=$(uf "client_offspeed bug" $W/client_offspeed.bug.awk -v w=100000Mb/s -- $U/clients_cgu.txt)
chk "planted bug (unknown speed not skipped): c2 is listed" "grep -qE '^#   c2 ' <<<\"\$o\"" "$o"

# --- ff_udp_expect (was 39's udp_expected.txt checks): expected UDP loss per receiving NIC ---
# call site src/sh/ff_results.sh udp_expect: awk "$UDP_EXPECT_AWK" $WORK/iplines udp_tx.txt iperf3_udp_results.txt
# fixtures udpx_<run>_*: 39's runs (tools/mkudpx.sh): ue FAKE_UDP_LOST=150000, un + FAKE_CLIENT_NOSPEED=c1, ua lost 100%;
# every sender sends 250G; lines: backend rail NICs 400G, c1-c3 bonds 200G, c4 two 100G NICs
ux() { uf "udp_expect $1" ${2:-$A/ff_udp_expect.awk} -- $U/udpx_$1_iplines.txt $U/udpx_$1_tx.txt $U/udpx_$1_res.txt; }
ue=$(ux ue)
chk "udp_expect unit: a row per UDP run with a result" "[ \$(wc -l <<<\"\$ue\") = \$(grep -c receiver $U/udpx_ue_res.txt) ] && [ \$(wc -l <<<\"\$ue\") -gt 10 ]" "$(wc -l <<<"$ue") rows"
chk "udp_expect unit: sent 250 into the 200G c1 bond: offered 250 (from 212.5 received x 1/0.85), expected 0.2" "grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.10\\.1 250 200 0\\.2000 ' <<<\"\$ue\"" "$(grep -E ' 198\.19\.10\.1 ' <<<"$ue")"
chk "udp_expect unit: sent 250 into a 100G c4 NIC: expected 0.6" "grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.1[01]\\.4 250 100 0\\.6000 ' <<<\"\$ue\"" "$(grep -E ' 198\.19\.1[01]\.4 ' <<<"$ue")"
chk "udp_expect unit: UF1: two senders (c1, c4) into one 400G backend NIC: offered 500, expected 0.2" "grep -qE '^iter1 UF1 - 198\\.19\\.10\\.1 198\\.19\\.1\\.21 500 400 0\\.2000 ' <<<\"\$ue\"" "$(grep -E '^iter1 UF1 ' <<<"$ue")"
chk "udp_expect unit: UF1: one sender (c2) into a 400G backend NIC: 250 under its line, expected 0 (control)" "grep -qE '^iter1 UF1 - 198\\.19\\.10\\.2 198\\.19\\.2\\.21 250 400 0\\.0000 ' <<<\"\$ue\"" "$(grep -E '^iter1 UF1 ' <<<"$ue")"
chk "udp_expect unit: U1 backend to backend, 250 into 400G: expected 0" "grep -qE '^iter1 U1 ' <<<\"\$ue\" && ! awk '\$2 ~ /^U[12]\$/ && \$8 != \"0.0000\"' <<<\"\$ue\" | grep -q ." "$(awk '$2 ~ /^U[12]$/' <<<"$ue")"
un=$(ux un)
chk "udp_expect unit: c1 speed unknown: rows into c1 have offered and rx '-', expected 0; c2 still 0.2 (control)" "grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.10\\.1 - - 0\\.0000 ' <<<\"\$un\" && grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.10\\.2 250 200 0\\.2000 ' <<<\"\$un\"" "$(grep -E '^iter1 UF2 ' <<<"$un")"
chk "udp_expect unit: c1 sending, speed unknown: its receiver's floor still comes from what was sent (500 into 400)" "grep -qE '^iter1 UF1 - 198\\.19\\.10\\.1 198\\.19\\.1\\.21 500 400 0\\.2000 ' <<<\"\$un\"" "$(grep -E '^iter1 UF1 ' <<<"$un")"
ua=$(ux ua)
chk "udp_expect unit: every datagram lost: offered '-', expected 0 on every row" "[ -n \"\$ua\" ] && ! awk '\$6 != \"-\" || \$8 != \"0.0000\"' <<<\"\$ua\" | grep -q ." "$(head -n 3 <<<"$ua")"
awkagree "udp_expect ue"; awkagree "udp_expect un"; awkagree "udp_expect ua"
# planted bugs: offered = received (no scaling by sent/delivered); the floor taken with the receiver's line unknown
sed 's#off\[k\] += R\[i\] \* (Se\[i\] - t) / (Se\[i\] - Lo\[i\])#off[k] += R[i]#' $A/ff_udp_expect.awk > $W/udp_expect.bug1.awk
o=$(ux ue $W/udp_expect.bug1.awk)
chk "planted bug (offered not scaled to what was sent): the c1-bond 250/0.2 row is gone" "! grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.10\\.1 250 200 0\\.2000 ' <<<\"\$o\"" "$(grep -E ' 198\.19\.10\.1 ' <<<"$o" | head -n 2)"
sed 's#ok = rx > 0 && !(k in unk)#ok = 1#' $A/ff_udp_expect.awk > $W/udp_expect.bug2.awk
o=$(ux un $W/udp_expect.bug2.awk); o2=$(ux ua $W/udp_expect.bug2.awk)
chk "planted bug (no 'unknown' case): c1's '-' rows and the all-lost '-' rows are gone" "! grep -qE '^iter1 UF2 - [0-9.]+ 198\\.19\\.10\\.1 - - 0\\.0000 ' <<<\"\$o\" && awk '\$6 != \"-\"' <<<\"\$o2\" | grep -q ." "$(grep -E '^iter1 UF2 .* 198\.19\.10\.1 ' <<<"$o" | head -n 2)"

# --- ff_xgroup_summary (ff_results.sh xgroup_summary): ipmap then results; phase 3 rows only, per rail pair from the
# marker, judged at each row's exp: (ok 75 / slow 50): C-A 3 flows (380/400 OK, 190/200 OK, 150/400 = 37.5% CRITICAL),
# C-B 2 flows (390/400 OK, 100/400 CRITICAL); the phase 1 row is left out ---
o=$(uf "xgroup_summary" $A/ff_xgroup_summary.awk -F'[, ]+' -v ok=75 -v slow=50 -- $U/ipmap_xgroup.txt $U/res_xgroup.txt)
chk "xgroup_summary unit: C-A 3 flows, median 190.0, expected 200 (the lowest), 2 OK 0 SLOW 1 CRITICAL; C-B 2 flows, 1 OK 1 CRITICAL; nothing from phase 1" \
    "[ \"\$(tr '\n' '|' <<<\"\$o\")\" = '  Cross-group C-A: 3 flows, 240.0 Gbps on average (median 190.0 Gbps per flow, expected 200 at the slower rail shared by its flows): 2 OK, 0 SLOW, 1 CRITICAL|  Cross-group C-B: 2 flows, 245.0 Gbps on average (median 245.0 Gbps per flow, expected 400 at the slower rail shared by its flows): 1 OK, 0 SLOW, 1 CRITICAL|' ]" "$o"
awkagree "xgroup_summary"
o=$(uf "xgroup_summary none" $A/ff_xgroup_summary.awk -F'[, ]+' -v ok=75 -v slow=50 -- $U/ipmap_xgroup.txt $U/res_slowcross.txt)
chk "xgroup_summary unit: a results file with no phase 3 says so (control)" "[ \"\$o\" = '  Cross-group: no run gave a result (phase 3).' ]" "$o"

# --- ff_lldp_rail_check (ff_mesh.sh lldp_rail_check): railmap "host nic rail ip" then LLDP rows; a bond's member rows
# carry the bond's IP and are checked against the bond's rail: h1's bond0 on rail B has member m2 cabled to leaf1,
# the switch the other NICs reach on rail A; m1 on leaf2 and the bond's own unknown row say nothing ---
o=$(uf "lldp_rail_check bond" $A/ff_lldp_rail_check.awk -- $U/railmap_bond.txt $U/lldp_bondwrong.txt)
chk "lldp_rail_check unit: a bond member on the other rail's leaf is named under the bond's rail; one finding" \
    "[ \"\$o\" = 'h1 lldp_wrong_rail rail B NIC m2 is cabled to leaf1, which 3 other NICs reach on rail A' ]" "$o"
awkagree "lldp_rail_check bond"

finish
