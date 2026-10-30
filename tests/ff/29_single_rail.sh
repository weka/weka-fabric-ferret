#!/opt/homebrew/bin/bash
# one rail (FF_RAILS one CIDR or FF_NICS one name): runs, no cross-rail phase, RESULT COMPLETE with cross_rail=single
# checks: 10
# secs: 39
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(xrun one FAKE_RAILS=1 FF_RAILS=198.19.1.0/24 FF_HOSTS=198.18.0.21-23 FF_ITER=2 timeout 120 $B $C 1); rc=$?
chk "single rail: COMPLETE rc=0, cross_rail=single" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE .*cross_rail=single' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
meta=$(bfile one metadata.txt)
chk "single rail: metadata rail_count=1, cross_rail=single, rail_a only" "grep -qx 'rail_count=1' <<<\"\$meta\" && grep -qx 'cross_rail=single' <<<\"\$meta\" && grep -qx 'rail_a=198.19.1.0/24' <<<\"\$meta\" && ! grep -q '^rail_b=' <<<\"\$meta\"" "$(grep -E '^(rail|cross)' <<<"$meta" | tr '\n' ' ')"
chk "single rail: rails.txt has rail A's columns only" "[ \"\$(bhead one rails.txt)\" = 'Host Target Rail_A_NIC Rail_A_IP MTU_A State_A' ]" "$(bhead one rails.txt)"
chk "single rail: host_list.txt is host target ip_A nic_A" "bfile one host_list.txt | awk 'NF != 4 || \$3 !~ /^198\.19\.1\./ || \$4 != \"enp5s0np0\" {b++} END {exit !(NR == 3 && !b)}'" "$(bfile one host_list.txt | head -n 2)"
res=$(bfile one iperf3_results.txt)
chk "single rail: phase 1 ran, no phase 2 marker" "grep -q '^### iteration:1 phase:1' <<<\"\$res\" && ! grep -q 'phase:2' <<<\"\$res\"" "$(grep '^###' <<<"$res" | sort | uniq -c | tr '\n' ' ')"
chk "single rail: only rail A flows" "[ -s $FAKE_STATE/iperf_args.log ] && ! grep -v '^UDP' $FAKE_STATE/iperf_args.log | awk '\$1 !~ /^198\.19\.1\./ || \$2 !~ /^198\.19\.1\./' | grep -q ." "$(head -n 3 $FAKE_STATE/iperf_args.log)"
render one; prc=$?
chk "single rail: dashboard renders (rc 0 or 3)" "[ $prc = 0 ] || [ $prc = 3 ]" "rc=$prc $(tail -n 3 $W/one.pout)"

# positive control for 'no phase 2': a two-rail run writes a phase 2 marker (golden-B's stored iperf3_results, which
# 50 keeps fresh against its run; was its own run here, 10-26)
chk "two rails (control): phase 2 marker present" "grep -q '^### iteration:1 phase:2' $S/fixtures/golden-B/iperf3_results.txt"

# FF_ITER=all, one rail by one NIC name, 4 hosts: n(n-1) x 1 = 12 directed paths, each once (one run for FF_ITER=all
# and FF_NICS one name; was runs all1 and nic1; FF_RAILS one CIDR is the run above)
out=$(xrun all1 FAKE_RAILS=1 FF_RAILS= FF_NICS=enp5s0np0 FF_HOSTS=198.18.0.21-24 FF_ITER=all timeout 120 $B $C 1); rc=$?
chk "single rail FF_ITER=all: directed_paths_total=12, each flow once" "bfile all1 metadata.txt | grep -qx 'directed_paths_total=12' && onceeach 12" "$(bfile all1 metadata.txt | grep directed_paths) $(tcpflows | wc -l)"
chk "FF_NICS one name: runs, rail_mode=nic rail_count=1 cross_rail=single" "[ $rc = 0 ] && bfile all1 metadata.txt | grep -qx 'rail_count=1' && bfile all1 metadata.txt | grep -qx 'rail_mode=nic' && grep -qE '^RESULT .*cross_rail=single' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
finish
