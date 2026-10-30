#!/opt/homebrew/bin/bash
# sampling and -d (from test_thermals.sh, split into sections 10-26)

# checks: 8
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- sampling: a host heating up ---
CASES="198.19.101.1:hot 198.19.101.2:all"
out=$(run hot FF_HOSTS=198.19.101.1,198.19.101.2 $B $TC -i 1 -d 3); rc=$?
chk "sampling -i 1 -d 3: 4 samples (0..3s)" "[ \"\$(jl hot | jq -r 'select(.type == \"sample\") | .sample' | tr '\n' ' ')\" = 's1 s2 s3 s4 ' ]" "$(jl hot | jq -c 'select(.type == "sample")')"
chk "sampling: hot CPU package 70 -> 88: high+rise; control n2 package 60 flat: no flag" \
    "[ \"\$(jl hot | jq -r 'select(.type == \"sensor\" and .sensor == \"Package_id_0\") | \"\\(.host) \\(.first_c) \\(.max_c) \\(.flag)\"' | tr '\n' ' ')\" = 'n1 70.0 88.0 high+rise n2 60.0 60.0 null ' ]" "$(jl hot | jq -c 'select(.type == "sensor" and .sensor == "Package_id_0")')"
chk "sampling: inlet 39 with BMC status nc: high" "jl hot | jq -e 'select(.type == \"sensor\" and .host == \"n1\" and .sensor == \"Inlet_Temp\") | .flag == \"high\"' > $W/hot.jq" "$(jl hot | jq -c 'select(.sensor == "Inlet_Temp")')"
chk "sampling: stdout row n1 merged: BMC inlet 39 39 and other 52 52, hwmon cpu 88.0 67.0 (of 88, 58, 55.1), nvme, nic; ipmi+hwmon, 8 sensors, flags in type order inlet,cpu,other; one n1 row" "grep -qE '^n1 +ipmi\\+hwmon +8 +39\\.0 +39\\.0 +88\\.0 +67\\.0 +- +- +- +- +44\\.9 +44\\.9 +62\\.0 +60\\.0 +52\\.0 +52\\.0 +inlet:high,cpu:high\\+rise,other:high\$' <<<\"\$out\" && [ \$(grep -c '^n1 ' <<<\"\$out\") = 1 ] && grep -qE '^ +n1 +hwmon +cpu .* Package_id_0 .* 88\\.0 .* high\\+rise\$' <<<\"\$out\"" "$(grep -E '^n[12] ' <<<"$out")"
chk "sampling: rc 0 COMPLETE (flags don't change the data verdict); nothing missing: no count line" "[ $rc = 0 ] && grep -q '^RESULT data=COMPLETE hosts=2/2' <<<\"\$out\" && ! grep -q '^Unreachable:' <<<\"\$out\"" "rc=$rc $(tail -n 2 <<<"$out")"

# --- the Avg is the mean of the sensors' latest readings, not of their peaks (10-28): case cool, Core 0 falls
# 70, 64, 58, 52 while Package 60 and Tctl 55.1 hold: cpu high 70.0 (the peak), Avg (60 + 52 + 55.1) / 3 = 55.7, where the
# mean of the peaks would be 61.7. Oracle from the jsonl: per type max of max_c, mean of last_c, mean of max_c ---
CASES="198.19.101.5:cool"
out=$(run cool FF_HOSTS=198.19.101.5 $B $TC -i 1 -d 3); rc=$?
orc=$(jl cool | jq -r 'select(.type == "sensor" and .source == "hwmon" and .kind == "cpu") | "\(.max_c) \(.last_c)"' | awk '
    { n++; if (n == 1 || $1 > mx) mx = $1; sl += $2; sm += $1 } END { printf "%d cpu sensors: high %.1f avg_last %.1f avg_max %.1f\n", n, mx, sl / n, sm / n }')
chk "cool: stdout n5 cpu 70.0 55.7 = the oracle's high and mean of last_c (3 sensors); the mean of max_c is 61.7 (the old Avg): $orc" \
    "[ \"\$orc\" = '3 cpu sensors: high 70.0 avg_last 55.7 avg_max 61.7' ] && grep -qE '^n5 +ipmi\\+hwmon +8 +24\\.0 +24\\.0 +70\\.0 +55\\.7 +- +- +- +- +44\\.9 +44\\.9 +62\\.0 +60\\.0 +52\\.0 +52\\.0 +other:high\$' <<<\"\$out\" && [ \"\$(jl cool | jq -r 'select(.type == \"sensor\" and .sensor == \"Core_0\") | \"\\(.first_c) \\(.max_c) \\(.last_c) \\(.flag)\"')\" = '70.0 70.0 52.0 null' ]" "rc=$rc $(grep -E '^n1 ' <<<"$out"; jl cool | jq -c 'select(.type == "sensor" and .kind == "cpu")')"

# --- -d alone (10-26: 0 by default = one point-in-time reading; N = read now and N s later) ---
CASES="198.19.121.1:hot"
out=$(run d0 FF_HOSTS=198.19.121.1 $B $TC -d 0); rc=$?
chk "-d 0: one reading, no rise in the header, flagged table has Temp (no First/Min/Max/Last)" "[ \$(jl d0 | jq -r 'select(.type == \"sample\")' | jq -s length) = 1 ] && grep -q '^Temperatures, one reading (' <<<\"\$out\" && ! grep -q 'rise = ' <<<\"\$out\" && grep -qE '^    Host +Source +Type +Chip +Dev +Sensor +Temp +High +Crit +Flag\$' <<<\"\$out\"" "$(grep -A3 '^Temperatures' <<<"$out")"
CASES="198.19.121.2:hot"
t0=$SECONDS; out=$(run d2 FF_HOSTS=198.19.121.2 $B $TC -d 2); rc=$?; el=$(( SECONDS - t0 ))
chk "-d 2: two readings 2 s apart (s1 s2), first/min/max/last 70/70/76/76, flagged table First Min Max Last" \
    "[ \"\$(jl d2 | jq -r 'select(.type == \"sample\") | .sample' | tr '\n' ' ')\" = 's1 s2 ' ] && [ \"\$(jl d2 | jq -r 'select(.type == \"sensor\" and .sensor == \"Package_id_0\") | \"\\(.first_c) \\(.min_c) \\(.max_c) \\(.last_c)\"')\" = '70.0 70.0 76.0 76.0' ] && grep -qE '^    Host +Source +Type +Chip +Dev +Sensor +First +Min +Max +Last +High +Crit +Flag\$' <<<\"\$out\" && (( el >= 2 ))" "el=$el $(jl d2 | jq -c 'select(.type == "sample" or .sensor == "Package_id_0")')"
finish
