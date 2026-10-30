#!/opt/homebrew/bin/bash
# clients c1..c4 (198.18.1.1-4) on their own subnets: c1-c3 bond0 on 198.19.10.0/24, c4 ens1f0 + ens1f1 (198.19.10/11);
# every client NIC to every backend rail both ways, the new bundle files, servers and cleanup on clients
# checks: 3
# secs: 51
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24

# the clean client run's checks moved to 52_golden_C.sh (10-26); 32 keeps the fake's refusal control and the
# one-subnet and FF_CLIENT_NICS variants

# positive control for the refused check: a run to a port no server listens on is refused and logged
mkdir -p $W/refuse/fake; r=$( (echo 'iperf3 -s -D' | FAKE_STATE=$W/refuse/fake $S/fake/ssh 198.18.0.21 bash -s -- 5201 1 198.19.1.21; echo 'retransmits:' | FAKE_STATE=$W/refuse/fake $S/fake/ssh 198.18.1.1 bash -s -- 198.19.10.1 198.19.1.21 5202 4 1) 2>&1)
chk "fake refuses an unstarted port (control)" "grep -q 'Connection refused' <<<\"\$r\" && [ -s $W/refuse/fake/iperf_refused.log ]" "$r"

# positive control for the 20 keys: only 198.19.10.0/24 -> c4's ens1f1 is left out: 4 rows, 16 keys
out=$(xrun cl10 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=198.19.10.0/24 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "one client subnet: 4 clients.txt rows, 16 flow keys (control)" "[ \$(bfile cl10 clients.txt | awk 'NR > 1 && NF' | wc -l) = 4 ] && [ \$(cflows | wc -l) = 16 ]" "rc=$rc $(cflows | wc -l) keys"

# by NIC name
out=$(xrun cln FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NICS=bond0,ens1f0,ens1f1 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "FF_CLIENT_NICS: client_mode=nics, 5 rows, clients=4/4" "bfile cln metadata.txt | grep -qx 'client_mode=nics' && [ \$(bfile cln clients.txt | awk 'NR > 1 && NF' | wc -l) = 5 ] && grep -qE '^RESULT .*clients=4/4' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|ERROR' <<<"$out" | head -n 2)"
finish
