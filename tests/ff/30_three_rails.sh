#!/opt/homebrew/bin/bash
# three rails (FAKE_RAILS=3, rail C = enp65s0np0 on 198.19.3.0/24): phase 1 on A, B and C, phase 2 across rail pairs, FF_ITER=all coverage
# checks: 14
# secs: 140
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
R3='198.19.1.0/24;198.19.2.0/24;198.19.3.0/24'

# FF_ITER=all, 3 hosts: n(n-1) x (N + N(N-1)) = 6 x (3 + 6) = 54 directed paths
out=$(xrun all3 FAKE_RAILS=3 FF_RAILS="$R3" FF_HOSTS=198.18.0.21-23 FF_ITER=all timeout 900 $B $C 1); rc=$?
chk "three rails: COMPLETE rc=0, cross_rail=on" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE .*cross_rail=on' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
meta=$(bfile all3 metadata.txt)
chk "three rails: metadata rail_count=3, rail_c, line_rate_c_gbps" "grep -qx 'rail_count=3' <<<\"\$meta\" && grep -qx 'rail_c=198.19.3.0/24' <<<\"\$meta\" && grep -q '^line_rate_c_gbps=' <<<\"\$meta\"" "$(grep -E '^(rail|line_rate)' <<<"$meta" | tr '\n' ' ')"
chk "three rails: directed_paths_total=54" "grep -qx 'directed_paths_total=54' <<<\"\$meta\"" "$(grep directed <<<"$meta" | tr '\n' ' ')"
# every directed path (src IP -> dst IP) at least once; phase 1 repeats per rail-pair cycle, so not once each
chk "three rails FF_ITER=all: all 54 directed paths run" "[ \$(tcpflows | sort -u | wc -l) = 54 ]" "$(tcpflows | sort -u | wc -l) distinct"
same=$(tcpflows | awk '{split($1, s, "."); split($2, d, "."); if (s[3] == d[3]) print s[3]}' | sort -u | tr '\n' ' ')
chk "three rails: phase 1 on A, B and C" "[ \"\$same\" = '1 2 3 ' ]" "same-rail octets: $same"
cross=$(tcpflows | awk '{split($1, s, "."); split($2, d, "."); if (s[3] != d[3]) print (s[3] < d[3] ? s[3] d[3] : d[3] s[3])}' | sort -u | tr '\n' ' ')
chk "three rails: phase 2 covers A-B, A-C and B-C" "[ \"\$cross\" = '12 13 23 ' ]" "cross pairs: $cross"
chk "three rails: rails.txt header has Rail_C columns" "[ \"\$(bhead all3 rails.txt)\" = 'Host Target Rail_A_NIC Rail_A_IP MTU_A State_A Rail_B_NIC Rail_B_IP MTU_B State_B Rail_C_NIC Rail_C_IP MTU_C State_C' ]" "$(bhead all3 rails.txt)"
chk "three rails: host_list.txt has 3 IPs and 3 NICs" "bfile all3 host_list.txt | awk 'NF != 8 || \$5 != \"198.19.3.\" substr(\$1, 2) || \$8 != \"enp65s0np0\" {b++} END {exit !(NR == 3 && !b)}'" "$(bfile all3 host_list.txt | head -n 2)"
chk "three rails: host_rx header NUMA_A/B/C, Ring and PCIe per rail" "bhead all3 host_rx.txt | grep -q '^Host NUMA_A/B/C Ring_A Ring_B Ring_C PCIe_A PCIe_B PCIe_C '" "$(bhead all3 host_rx.txt)"
render all3; prc=$?
chk "three rails: dashboard renders (rc 0 or 3) and carries rail C (its rail list and Ring_C)" "{ [ $prc = 0 ] || [ $prc = 3 ]; } && grep -qF '\"rail\": \"C\"' $W/all3.html && grep -qF Ring_C $W/all3.html" "rc=$prc $(tail -n 3 $W/all3.pout)"

# phase 1 and phase 2 markers (on the FF_ITER=all run; was its own FF_ITER=2 run, 10-26)
chk "three rails: phase 1 and phase 2 markers" "bfile all3 iperf3_results.txt | grep -q '^### iteration:1 phase:1' && bfile all3 iperf3_results.txt | grep -q '^### iteration:1 phase:2'" "$(bfile all3 iperf3_results.txt | grep -c '^### ') markers"

# FF_LINE_GBPS: one value or one per rail
out=$(xrun lg2 FAKE_RAILS=3 FF_RAILS="$R3" FF_LINE_GBPS=400,400 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
chk "three rails: FF_LINE_GBPS with 2 values stops" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -q 'FF_LINE_GBPS' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"
# three NIC names, with FF_LINE_GBPS per rail (one run for both; was runs lg3 and nic3)
out=$(xrun nic3 FAKE_RAILS=3 FF_RAILS= FF_NICS=enp5s0np0,enp196s0np0,enp65s0np0 FF_LINE_GBPS=400,400,200 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 120 $B $C 1); rc=$?
chk "three rails: FF_LINE_GBPS per rail sets line_rate_c_gbps=200" "bfile nic3 metadata.txt | grep -qx 'line_rate_c_gbps=200'" "rc=$rc $(bfile nic3 metadata.txt | grep line_rate | tr '\n' ' ')"
chk "FF_NICS three names: rail_mode=nic rail_count=3" "bfile nic3 metadata.txt | grep -qx 'rail_count=3' && bfile nic3 metadata.txt | grep -qx 'rail_mode=nic'" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
finish
