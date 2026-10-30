#!/opt/homebrew/bin/bash
# unreachable targets (from test_thermals.sh, split into sections 10-26)

# checks: 14
# secs: 27
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- unreachable targets (10-26: "Connection issues should be silent unless -v is given") ---
# /29 = .1-.6: .1 all, .2 down, .3 denied (a host is there: loud), .4 no route on sample 1 then up, .5 down and
# also listed on its own, .6 refused; plus a name that doesn't resolve
CASES="198.19.107.1:all 198.19.107.2:down 198.19.107.3:denied 198.19.107.4:downfirst 198.19.107.5:down 198.19.107.6:refused nosuch-host:nodns"
out=$(run cidr FF_HOSTS=198.19.107.0/29,198.19.107.5,nosuch-host $B $TC -i 1 -d 1); rc=$?
chk "unreachable: rc 3, hosts=2/3 (7 less 4 unreachable), unreachable=4" "[ $rc = 3 ] && grep -qE '^RESULT data=PARTIAL hosts=2/3 .* unreachable=4\$' <<<\"\$out\"" "rc=$rc $(tail -n 2 <<<"$out")"
chk "unreachable: .2 .5 .6 and the unresolvable name appear nowhere without -v (stderr, jsonl)" "! grep -qE '198\\.19\\.107\\.[256]\\b|nosuch-host' <<<\"\$out\" && ! jl cidr | grep -qE '198\\.19\\.107\\.[256]\"|nosuch-host'" "$(grep -E '198\.19\.107\.[256]|nosuch' <<<"$out"; jl cidr | grep -E '198\.19\.107\.[256]"|nosuch')"
chk "unreachable: auth refused (.3) stays loud (hwmon+ipmi)" "[ \"\$(jl cidr | jq -r 'select(.type == \"nodata\") | \"\\(.host) \\(.source)\"' | tr '\n' ' ')\" = '198.19.107.3 hwmon 198.19.107.3 ipmi ' ] && grep -q 'NO TEMPERATURE DATA: 198.19.107.3 hwmon (ssh_failed_root_198.19.107.3:_Permission_denied' <<<\"\$out\"" "$(jl cidr | jq -c 'select(.type == "nodata")')"
chk "unreachable: .4 missed sample 1 but answered sample 2: a host with data, not unreachable, no nodata" "jl cidr | jq -e 'select(.type == \"sensor\" and .host == \"n4\" and .sensor == \"Package_id_0\")' > $W/cidr.jq" "$(jl cidr | jq -c 'select(.host == "n4" or .target == "198.19.107.4")' | head -n 3)"
chk "unreachable: jsonl run record: targets 3, unreachable 4" "jl cidr | jq -e 'select(.type == \"run\") | .targets == 3 and .unreachable == 4' > $W/cidr2.jq" "$(jl cidr | head -n 1)"
out=$(run cidrv FF_HOSTS=198.19.107.0/29,198.19.107.5,nosuch-host $B $TC -v -i 1 -d 1); rc=$?
chk "unreachable -v: count line drops the -v hint; unavailable 1 (.3 auth refused)" "[ \"\$(tail -n 2 <<<\"\$out\" | head -n 1)\" = 'Unreachable: 4 (no ssh connection), unavailable: 1 (connected, no readings)' ]" "$(tail -n 3 <<<"$out")"
# the whole -v listing against the list the old code built (the four lines, sort -V order, two-space indent); the
# control plants a fifth line into the expected list, which must break the compare
vlist=$(sed -n '/^Unreachable: 4 target(s)/,/^$/p' <<<"$out" | sed '1d;$d')
exp_v=$(printf '%s\n' '  198.19.107.2 ssh_failed_ssh:_connect_to_host_198.19.107.2_port_22:_Connection_timed_out' '  198.19.107.5 ssh_failed_ssh:_connect_to_host_198.19.107.5_port_22:_Connection_timed_out' '  198.19.107.6 ssh_failed_ssh:_connect_to_host_198.19.107.6_port_22:_Connection_refused' '  nosuch-host ssh_failed_ssh:_Could_not_resolve_hostname_nosuch-host:_Name_or_service_not_known')
chk "unreachable -v: the listing block is exactly the four lines in sort -V order (the listing the old loop built)" "[ \"\$vlist\" = \"\$exp_v\" ]" "$(diff <(echo "$exp_v") <(echo "$vlist"))"
chk "control: a planted fifth line in the expected list breaks the compare" "[ \"\$vlist\" != \"\$(printf '%s\n  198.19.107.9 planted' \"\$exp_v\")\" ] && [ -n \"\$vlist\" ]"
chk "unreachable -v: lists all 4 with the reason, same verdict" "[ $rc = 3 ] && grep -q '^Unreachable: 4 target(s) took no ssh connection' <<<\"\$out\" && grep -qx '  198.19.107.2 ssh_failed_ssh:_connect_to_host_198.19.107.2_port_22:_Connection_timed_out' <<<\"\$out\" && grep -qx '  198.19.107.5 ssh_failed_ssh:_connect_to_host_198.19.107.5_port_22:_Connection_timed_out' <<<\"\$out\" && grep -qx '  198.19.107.6 ssh_failed_ssh:_connect_to_host_198.19.107.6_port_22:_Connection_refused' <<<\"\$out\" && grep -qx '  nosuch-host ssh_failed_ssh:_Could_not_resolve_hostname_nosuch-host:_Name_or_service_not_known' <<<\"\$out\"" "rc=$rc $(grep -A5 '^Unreachable' <<<"$out")"
CASES="198.19.108.1:down 198.19.108.2:refused"
# refused under load: one retry (8 at a time); an ssh that dies with nothing on stderr gets a reason; every ssh error of
# the run lands in thermcap_<UTC>.ssh_errors.log beside the outputs, written only when there were any
CASES="198.19.109.1:cmfail 198.19.109.2:downsilent 198.19.109.3:all"
out=$(run rt FF_HOSTS=198.19.109.1,198.19.109.2,198.19.109.3 $B $TC); rc=$?
chk "retry: a control-master failure on the first call is retried and recovers (.1 has data; the log says 1 refused, recovered 1)" "jl rt | jq -e 'select(.type == \"sensor\" and .host == \"n1\" and .sensor == \"Package_id_0\")' > $W/rt.jq && grep -q '^# sample 1: 1 target(s) refused ssh under load (control master, reset, kex); retried 8 at a time, recovered 1$' <<<\"\$out\"" "rc=$rc $(grep -E 'refused|RESULT' <<<"$out")"
chk "an ssh that dies silently (rc 255, empty stderr): nodata with the reason ssh_failed_rc255_no_message, both sources" "[ \"\$(jl rt | jq -r 'select(.type == \"nodata\") | \"\\(.host) \\(.source) \\(.why)\"' | sort | tr '\n' '|')\" = '198.19.109.2 hwmon ssh_failed_rc255_no_message|198.19.109.2 ipmi ssh_failed_rc255_no_message|' ]" "$(jl rt | jq -c 'select(.type == "nodata")')"
chk "ssh_errors.log: written beside the outputs, one line per failed read: the control-master line for .1's first try, '(no message)' for .2; .3 (clean) absent" "[ \$(ls $W/rt/out/*.ssh_errors.log | wc -l) = 1 ] && grep -q '^s1 198.19.109.1 rc=255 (retried): Failed to connect to new control master|\$' $W/rt/out/*.ssh_errors.log && grep -qx 's1 198.19.109.2 rc=255: (no message)' $W/rt/out/*.ssh_errors.log && ! grep -q '198.19.109.3' $W/rt/out/*.ssh_errors.log && grep -q 'Wrote .*ssh_errors.log' <<<\"\$out\"" "$(cat $W/rt/out/*.ssh_errors.log 2>&1)"
CASES="198.19.109.3:all 198.19.109.4:all"
out=$(run rtc FF_HOSTS=198.19.109.3,198.19.109.4 $B $TC); rc=$?
chk "control: a run with no ssh error writes no ssh_errors.log (jsonl only)" "[ $rc = 0 ] && [ \"\$(ls $W/rtc/out | sed 's/.*\\.//' | tr '\n' ' ')\" = 'jsonl ' ]" "$(ls $W/rtc/out)"
CASES="198.19.108.1:down 198.19.108.2:refused"   # (restored: the retry block above changed CASES)
out=$(run allempty FF_HOSTS=198.19.108.0/30 $B $TC); rc=$?
chk "nobody reachable: rc 4 NONE, says so even without -v" "[ $rc = 4 ] && grep -q '^RESULT data=NONE hosts=0/0 .* unreachable=2\$' <<<\"\$out\" && grep -q 'NO TEMPERATURE DATA: none of the 2 targets took an ssh connection (-v lists them)' <<<\"\$out\"" "rc=$rc $(tail -n 4 <<<"$out")"
finish
