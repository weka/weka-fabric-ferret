#!/opt/homebrew/bin/bash
# client stops (no NETS/NICS, host in both lists, busy client, half-set client spine) and client anomalies (route, MTU, shared leaf);
# FF_SKIP_IPERF=1 with clients = client path checks only. Runs here use FF_SKIP_IPERF=1 where load isn't the point.
# checks: 14
# secs: 42
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
SP="FF_SPINES=2 FF_SPINE_LINKS=4 FF_SPINE_GBPS=400"

# clean no-load run: the control for every anomaly and stop below
out=$(xrun ok env FF_SKIP_IPERF=1 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS $SP FF_CLIENT_SPINE_LINKS=2 FF_CLIENT_SPINE_GBPS=400 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "skip-iperf with clients: COMPLETE, clients=4/4, iperf=skipped" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE .*clients=4/4.*iperf=skipped' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
meta=$(bfile ok metadata.txt)
chk "skip-iperf with clients: no iperf3 run, client path checks all OK" "[ -n \"\$(bundle ok)\" ] && [ ! -e $FAKE_STATE/iperf_args.log ] && awk -F= '\$1 == \"client_paths_planned\" {p = \$2} \$1 == \"client_paths_ok\" {o = \$2} END {exit !(p >= 20 && p == o)}' <<<\"\$meta\"" "$(grep '^client_paths' <<<"$meta" | tr '\n' ' ')"
chk "client spine settings recorded" "grep -qx 'client_spine_links=2' <<<\"\$meta\" && grep -qx 'client_spine_gbps=400' <<<\"\$meta\"" "$(grep '^client_spine' <<<"$meta" | tr '\n' ' ')"
anom=$(bfile ok rail_anomalies.txt)
chk "clean run: no client anomalies (control)" "[ -n \"\$(bundle ok)\" ] && ! grep -qE 'client_route_undeclared|client_mtu_mismatch|shared_leaf' <<<\"\$anom\"" "$anom"

# faults: c3's route to the backends leaves by eno1, c2's data NIC at MTU 1500, client NICs on backend rail A's leaf; 5 expected
out=$(xrun bad env FF_SKIP_IPERF=1 FAKE_CROUTE_BAD=c3 FAKE_CLIENT_MTU=c2:1500 FAKE_CLIENT_SHARED_LEAF=1 FF_EXPECT_CLIENTS=5 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
anom=$(bfile bad rail_anomalies.txt)
chk "FAKE_CROUTE_BAD=c3: client_route_undeclared anomaly" "grep -q 'client_route_undeclared' <<<\"\$anom\" && grep -q c3 <<<\"\$(grep client_route_undeclared <<<\"\$anom\")\"" "rc=$rc $anom"
chk "FAKE_CROUTE_BAD=c3: client_routes rows by eno1 undeclared" "bfile bad client_routes.txt | awk '\$1 == \"c3\" && \$5 == \"eno1\" && \$6 == \"undeclared\" {f = 1} \$1 != \"c3\" && \$6 == \"undeclared\" {b = 1} END {exit !(f && !b)}'" "$(bfile bad client_routes.txt)"
chk "c2 MTU 1500: client_mtu_mismatch anomaly, clients.txt MTU 1500" "grep -q 'client_mtu_mismatch' <<<\"\$anom\" && bfile bad clients.txt | awk '\$1 == \"c2\" && \$5 == 1500 {f = 1} END {exit !f}'" "$anom"
chk "client NICs on a backend leaf: shared_leaf anomaly" "grep -q 'shared_leaf' <<<\"\$anom\"" "$anom"
chk "FF_EXPECT_CLIENTS=5 with 4 found: clients=4/5" "grep -qE '^RESULT .*clients=4/5' <<<\"\$out\" && bfile bad metadata.txt | grep -qx 'clients_expected=5'" "rc=$rc $(grep '^RESULT' <<<"$out")"

# stops
out=$(xrun nonets FF_CLIENTS=198.18.1.1-4 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
chk "FF_CLIENTS without NETS/NICS: stops listing the client subnets" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -q '198.19.10.0/24' <<<\"\$out\" && grep -q '198.19.11.0/24' <<<\"\$out\" && grep -q 'FF_CLIENT_NETS' <<<\"\$out\"" "rc=$rc $(tail -n 8 <<<"$out")"
# 198.18.1.9 answers as h1 (machine-id of 198.18.0.1)
out=$(xrun both env FF_SKIP_IPERF=1 FF_CLIENTS=198.18.1.1,198.18.1.9 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 timeout 120 $B $C 1); rc=$?
chk "a host in both FF_HOSTS and FF_CLIENTS stops" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -E 'ERROR|STOPPED' <<<\"\$out\" | grep -qE 'h1|198\.18\.1\.9' && ! grep -q 'unknown setting' <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR' <<<"$out")"
out=$(xrun busy env FAKE_BUSY=c2 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 120 $B $C 1); rc=$?
chk "busy client stops a load run" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -E 'ERROR|STOPPED' <<<\"\$out\" | grep -q c2 && ! grep -q 'unknown setting' <<<\"\$out\" && [ ! -e $FAKE_STATE/iperf_args.log ]" "rc=$rc $(grep -E 'ERROR' <<<"$out")"
out=$(xrun busyskip env FF_SKIP_IPERF=1 FAKE_BUSY=c2 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "busy client is fine with FF_SKIP_IPERF=1" "grep -qE '^RESULT coverage=(COMPLETE|PARTIAL) .*clients=4/4' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
out=$(xrun halfsp env $SP FF_CLIENT_SPINE_LINKS=2 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
chk "FF_CLIENT_SPINE_LINKS without FF_CLIENT_SPINE_GBPS stops" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -q 'FF_CLIENT_SPINE_GBPS' <<<\"\$out\" && ! grep -q 'unknown setting' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"
finish
