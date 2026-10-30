#!/opt/homebrew/bin/bash
# a host that hangs: cut off at FF_IPMI_TIMEOUT+30, loud no-data, keeps its target (from test_thermals.sh's mix run,
# split out 10-26: the cut-off is this suite's long pole, so it runs on its own, first)
# checks: 3
# secs: 35
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
CASES="198.19.100.9:hang"
t0=$SECONDS
out=$(run hang FF_IPMI_TIMEOUT=2 FF_HOSTS=198.19.100.9 $B $TC -o jsonl); rc=$?; el=$(( SECONDS - t0 ))
chk "hang: the hung host was cut off at FF_IPMI_TIMEOUT+30 (finished in under 60s)" "(( el < 60 && el >= 30 ))" "took ${el}s"
nd=$(jl hang | jq -r 'select(.type == "nodata") | "\(.host) \(.source) \(.why)"' | sort)
exp_nd="198.19.100.9 hwmon ssh_cut_off_after_32s
198.19.100.9 ipmi ssh_cut_off_after_32s"
chk "hang: both sources no-data with the cut-off reason" "[ \"\$nd\" = \"\$exp_nd\" ]" "$(diff <(echo "$exp_nd") <(echo "$nd"))"
chk "hang: the host record keeps the target (198.19.100.9)" \
    "[ \"\$(jl hang | jq -r 'select(.type == \"host\" and .target == \"198.19.100.9\") | .host' | tr '\n' ' ')\" = '198.19.100.9 ' ]" "rc=$rc $(jl hang | jq -c 'select(.type == "host")')"
finish
