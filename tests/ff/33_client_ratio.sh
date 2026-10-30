#!/opt/homebrew/bin/bash
# FF_CLIENT_RATIO: N = waves only (C1/C2), full = all at once only (F1/F2), N:full = both; share:K = flows on that backend NIC at once
# 2 backends x 2 rails = 2 backend NICs per rail for 5 client NICs, so ratio 2 has to put two flows on one backend NIC
# checks: 10
# secs: 139
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
CL="FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=198.19.10.0/24,198.19.11.0/24 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1"
marks() { bfile $1 client_results.txt | grep -oE '^### client .*phase:[A-Z][0-9]' | grep -oE '[A-Z][0-9]$' | sort -u | tr '\n' ' '; }

out=$(xrun full env $CL FF_CLIENT_RATIO=full timeout 240 $B $C 1); rc=$?
chk "ratio full: only F1 and F2 markers" "[ \"\$(marks full)\" = 'F1 F2 ' ]" "rc=$rc marks=$(marks full) $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
# all at once: every client NIC sends and receives (the contract does not say every rail in this mode)
chk "ratio full: metadata client_ratio=full, every client NIC both ways" "bfile full metadata.txt | grep -qx 'client_ratio=full' && [ \$(cflows | awk '{print \$1, \$3}' | sort -u | wc -l) = 10 ]" "$(cflows | tr '\n' ';')"

# ratio 2:full (C1 C2 F1 F2 markers, share:2 in a wave, metadata) is golden-C's own setting: its checks are in 52

# waves with ratio 2: a backend NIC serves two client flows at once in a C-phase wave, on two ports, both listening
out=$(xrun w2 env $CL FF_CLIENT_RATIO=2 FF_CLIENT_GBPS=400 timeout 240 $B $C 1); rc=$?
w2=$(bfile w2 client_results.txt)
chk "ratio 2 waves: share:2 in C1, port FF_PORT+1 used, nothing refused, rc=0" "[ $rc = 0 ] && awk '/^### /{c = (\$0 ~ /phase:C1/)} c && / share:2\$/ {n++} END {exit !n}' <<<\"\$w2\" && grep -q ' 5202 ' $FAKE_STATE/iperf_args.log && [ ! -s $FAKE_STATE/iperf_refused.log ] && grep -q 'servers on port 5201-5202' <<<\"\$out\"" "rc=$rc $(grep -E 'servers on port|^RESULT' <<<"$out")"
# expected = min(client 400, backend 400 / share): 200 for a client NIC that shared a backend NIC
chk "ratio 2 waves: a shared run is expected at backend line / 2 (Expect 200)" "grep -E '^ +client +c[0-9] ' <<<\"\$out\" | awk '\$(NF-1) == 200 {n++} END {exit !n}'" "$(grep -E '^ +(Role|client) ' <<<"$out")"
# clients follow FF_ITER: each iteration has its client phases and moves every client NIC on to the next backend
# (src dst dir) of the client runs, from the fake's iperf3 log: a client IP is 198.19.10/11.x
cpairs() { grep -v '^UDP' $FAKE_STATE/iperf_args.log 2>&1 | awk '$1 ~ /^198\.19\.1[01]\./ {print $1, $2, "c2b"} $2 ~ /^198\.19\.1[01]\./ {print $2, $1, "b2c"}' | sort -u; }
out=$(xrun it2 env ${CL/FF_ITER=1/FF_ITER=2} timeout 240 $B $C 1); rc=$?
it2=$(bfile it2 client_results.txt)
# control: ratio 1 (the default) waves never put two flows on one backend NIC (on the FF_ITER=2 run; was its own run)
chk "ratio 1 (default, control): only C1 C2, every share:1" "[ \"\$(marks it2)\" = 'C1 C2 ' ] && grep -q ' share:1' <<<\"\$it2\" && ! grep -qE ' share:([2-9]|[1-9][0-9])' <<<\"\$it2\"" "rc=$rc marks=$(marks it2) $(grep -o 'share:[0-9]*' <<<"$it2" | sort | uniq -c | tr '\n' ' ')"
chk "FF_ITER=2: client phases C1 and C2 in iterations 1 and 2, rc=0" "[ $rc = 0 ] && ( for i in 1 2; do for p in C1 C2; do grep -qE \"^### client iteration:\$i phase:\$p\" <<<\"\$it2\" || exit 1; done; done )" "rc=$rc $(grep -oE '^### client iteration:[0-9]+ phase:[A-Z][0-9]' <<<"$it2" | sort -u | tr '\n' ' ')"
# 5 client NICs x 2 rails x 2 directions, each to a different backend in iteration 2: 40 (client, backend, dir)
chk "FF_ITER=2: each client NIC meets a second backend on each rail (40 client-backend-direction triples)" "[ \$(cpairs | wc -l) = 40 ]" "$(cpairs | wc -l)"
chk "FF_ITER=2: RESULT counts both iterations' client paths (40)" "grep -qE '^RESULT coverage=COMPLETE .*client_paths=40/40' <<<\"\$out\"" "$(grep '^RESULT' <<<"$out")"
# FF_ITER=all: every client NIC to every backend NIC on its rail both ways; 2 backends a rail -> 2 iterations at least
out=$(xrun itall env ${CL/FF_ITER=1/FF_ITER=all} timeout 240 $B $C 1); rc=$?
chk "FF_ITER=all: every client NIC to every backend NIC, both ways (5 x 4 x 2 = 40)" "[ $rc = 0 ] && [ \$(cpairs | wc -l) = 40 ] && grep -q 'reaches 2 of 2 backend NICs per rail' <<<\"\$out\"" "rc=$rc $(cpairs | wc -l) $(grep 'reaches' <<<"$out")"
out=$(xrun bad env $CL FF_CLIENT_RATIO=0 timeout 60 $B $C 1); rc=$?
chk "FF_CLIENT_RATIO=0 stops naming the setting" "[ $rc = 2 ] && grep -q 'FF_CLIENT_RATIO' <<<\"\$out\" && ! grep -q 'unknown setting' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"
finish
