#!/opt/homebrew/bin/bash
# 10-25: "add the retransmit flag as a suffix"; and a backend missing one rail's address must not just show
# fewer rows: every expected data NIC gets a row, with its rail state when it ran nothing
# checks: 8
# secs: 46
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
CL="FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 FF_MESH=0"
tbl() { grep -E '^ +(Role|backend|client) ' <<<"$1"; }

# the c1 retransmit run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_RETR_SRC=198.19.10.1
# the threshold is a setting: 100,000 per run (~0.045%) passes at 0.1, is flagged at 0.01
out=$(xrun r2 FAKE_RETR_SRC=198.19.10.1 FAKE_RETR_N=100000 $CL timeout 240 $B $C 1)
chk "0.045% with the default 0.1: no flag" "tbl \"\$out\" | grep -qE '^ +client +c1 .* Retr_%|^ +client +c1 ' && ! tbl \"\$out\" | grep -q '(retr)' && grep -q 'Retr_%' <<<\"\$out\"" "$(tbl "$out")"
out=$(xrun r3 FF_RETR_PCT=0.01 FAKE_RETR_SRC=198.19.10.1 FAKE_RETR_N=100000 $CL timeout 240 $B $C 1)
chk "0.045% with FF_RETR_PCT=0.01: OK(retr)" "tbl \"\$out\" | awk '\$2 == \"c1\" {f = 1; ok = (\$NF == \"OK(retr)\")} END {exit !(f && ok)}'" "$(tbl "$out")"
out=$(xrun r4 FF_RETR_PCT=abc $CL timeout 60 $B $C 1); rc=$?
chk "FF_RETR_PCT=abc refused (rc 2)" "[ $rc = 2 ] && grep -q 'FF_RETR_PCT must be a number' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"

# h22 has no IPv4 on rail B: its rail B row stays, IP '-', Status its rail state; 4 backend rows, not 3
out=$(xrun na FAKE_NOIP_B=h22 FF_HOSTS=198.18.0.21,198.18.0.22,198.18.0.23 FF_ITER=1 FF_UDP=0 FF_MESH=0 timeout 240 $B $C 1); rc=$?
# rails by subnet: a rail NIC without an address in the rail's subnets is "no address in <subnets>", NIC unknown ('-')
chk "no address on h22 rail B: a row for it, NIC and IP '-', Status its rail state" "tbl \"\$out\" | grep -qE '^ +backend +h22 +- +- +.* no_address_in_198\\.19\\.2\\.0/24\$'" "$(tbl "$out")"
chk "h21 sat out (3 hosts, 1 iteration): its two rows show no_result, not dropped" "[ \$(tbl \"\$out\" | grep -cE '^ +backend +h21 .* no_result\$') = 2 ]" "$(tbl "$out")"
# rail groups: h22 holds rail A only; it pairs within the A,B hosts and only its rail A is planned (said in the planning log)
chk "h22 lacks rail B: it pairs within the A,B group on rail A only, said in the planning log; its rail A run has a result" \
    "grep -q '^# 1 host lacks a rail and pairs within the hosts holding the rails it has: h22: rail B not addressed, tested on A only$' <<<\"\$out\" && tbl \"\$out\" | grep -qE '^ +backend +h22 +enp5s0np0 +198\.19\.1\.22 +[0-9.]+ .* OK\$'" "$(grep 'lacks a rail' <<<"$out") $(tbl "$out" | grep ' h22 ')"
chk "6 backend rows for 3 hosts x 2 rails (none dropped)" "[ \$(tbl \"\$out\" | grep -c '^ *backend ') = 6 ]" "$(tbl "$out")"
render na; prc=$?
chk "dashboard: the same rows (h22 rail state; 6 backend rows, no stray 'none' row)" "ROWS=1 node $H/rows.js $W/na.html | grep -qx 'h22 no address in 198.19.2.0/24' && [ \$(ROWS=1 node $H/rows.js $W/na.html | wc -l) = 7 ] && ! ROWS=1 node $H/rows.js $W/na.html | grep -q '^none '" "rc=$prc $(ROWS=1 node $H/rows.js $W/na.html)"
# the link-down row (fake h4 rail B) is checked in 50_golden_B.sh (10-26)
finish
