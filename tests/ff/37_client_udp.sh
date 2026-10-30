#!/opt/homebrew/bin/bash
# client UDP pass (10-24: "make the client UDP pass always run"): with FF_UDP=1 every client phase gets a
# UDP twin (UC1/UC2, UF1/UF2), the same runs, with UDP host and NIC counters around it and loss placed per receiver
# checks: 10
# secs: 60
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
CIPS='198\.19\.1[01]\.'
cnt() { awk -v p="$2" '/^### / {ph = ""; for (i = 2; i <= NF; i++) if ($i ~ /^phase:/) ph = substr($i, 7); next} ph == p && /Gbits/ {n++} END {print n + 0}' <<<"$1"; }

# the client UDP twin run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_UDP_SOCK=c1

# the datagram size (c2 at MTU 1500: -l 1472) and the default-on UDP pass with clients are checked on golden-C (52),
# which runs with UDP at its default and FAKE_CLIENT_MTU=c2:1500 (10-26: was runs cm and dd here)

# FF_UDP=0 with clients: no twins
out=$(xrun c0 FF_UDP=0 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 300 $B $C 1); rc=$?
chk "FF_UDP=0: no UDP runs, no U rows in phase_times" "! grep -q '^UDP ' $FAKE_STATE/iperf_args.log && ! bfile c0 phase_times.txt | grep -qE '^1 U'" "$(grep -c '^UDP ' $FAKE_STATE/iperf_args.log) $(bfile c0 phase_times.txt | awk '{print $2}' | tr '\n' ' ')"

# default (10-24: "default FF_UDP to 1"): UDP on with load (golden-C), off with FF_SKIP_IPERF=1; both set = refused
out=$(xrun ds FF_SKIP_IPERF=1 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 300 $B $C 1); rc=$?
chk "default with FF_SKIP_IPERF=1: runs, UDP off (udp=0)" "grep -qE '^RESULT coverage=COMPLETE' <<<\"\$out\" && bfile ds metadata.txt | grep -qx 'udp=0'" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
out=$(xrun dx FF_SKIP_IPERF=1 FF_UDP=1 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 300 $B $C 1); rc=$?
chk "FF_SKIP_IPERF=1 with FF_UDP=1 set: refused (rc 2)" "[ $rc = 2 ] && grep -q 'FF_UDP=1 is a load test' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"

# no clients, FF_UDP=1: the UDP files and summary match fixed expected files (fake UDP values are fixed); made from
# 2ca3fa9 (byte-equal to c2e9c7d but the shebang), replacing a compare against `git show HEAD:` that proved nothing
# once committed (10-26)
X=$(dirname "${BASH_SOURCE[0]}")/expected/37_no_clients
out=$(xrun un FF_UDP=1 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 300 $B $C 1)
for f in iperf3_udp_results.txt udp_host_counters.txt udp_nic_drops.txt; do
    a=$(bfile un $f | sort)   # rows come back in ssh completion order
    chk "no clients: $f as expected/37_no_clients.$f" "[ -s $X.$f ] && [ \"\$a\" = \"\$(cat $X.$f)\" ]" "$(diff $X.$f <(echo "$a") 2>&1 | head -n 6)"
done
s1=$(sed -n '/^UDP (-b 0) by receiving host/,/^  UDP runs with no result/p' <<<"$out")
chk "no clients: UDP summary section as expected/37_no_clients.summary.txt (rows in any order)" "[ -s $X.summary.txt ] && [ \"\$(sort <<<\"\$s1\")\" = \"\$(sort $X.summary.txt)\" ]" "$(diff $X.summary.txt <(echo "$s1") 2>&1 | head -n 6)"
chk "no clients: every backend's Expected_% is 0 (same rail, 1:1)" "[ \$(grep -cE '^ +h2[12] .* 0\.000\$' <<<\"\$s1\") = 2 ] && grep -q 'Expected from overload: 0;' <<<\"\$s1\"" "$s1"
# a client run that fails (c2's address refuses, as a host firewall does): the client phase WARNING carries the
# reason line and the summary's client count its histogram (10-27: the client lines must not stay untested)
out=$(xrun cfail env FAKE_IPERF_NOROUTE=198.19.10.2 FF_UDP=0 FF_CLIENTS=198.18.1.1-3 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "client phase (C2 pairs a backend to c2): the WARNING ends with a colon; the next line is the reason to 1 destination (198.19.10.2), the row's share:1 dropped" \
    "grep -A1 -E '^# WARNING: [0-9]+ client runs in phase C[12] returned no result \(lines with ERROR above\):$' <<<\"\$out\" | tail -n 1 | grep -q '^#   [0-9]* x \"unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: No route to host\" to 1 destination (198\.19\.10\.2)$'" "rc=$rc $(grep -A1 'client runs in phase C' <<<"$out" | cut -c1-120 | tr '\n' '|')"
ne=$(bfile cfail client_results.txt | grep -c ',ERROR')
chk "summary: 'Client runs with no result: $ne' (= client_results.txt's ERROR rows), then its reason line" \
    "[ $ne -gt 0 ] && grep -q \"^  Client runs with no result: $ne |\" <<<\"\$out\" && grep -qE \"^    $ne x \\\"unable to connect .* No route to host\\\" to 1 destination \(198\.19\.10\.2\)\$\" <<<\"\$out\"" "ne=$ne $(grep -A1 'Client runs with no result' <<<"$out" | cut -c1-120 | tr '\n' '|')"
finish
