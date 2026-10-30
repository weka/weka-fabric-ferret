#!/opt/homebrew/bin/bash
# temperatures (10-26: "Temperature monintoring"; "Let's just go with /sys/class/hwmon, no lm-sensors, and add the
# ipmitool query"): hwmon on every host and client around every phase, the BMC once per iteration and at the end
# checks: 6
# secs: 16
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24

# reader on fake sysfs: coretemp, k10temp, nvme, mlx5 (NIC by netdev), ice, a power-only chip; ipmitool stub
for c in all nochips nohwmon; do
    o=$($B $H/test_temps.sh $C $W $c 2>&1)
    chk "reader, case $c: matches test_temps_$c.expected" "[ \"\$o\" = \"\$(cat $H/test_temps_$c.expected)\" ]" "$o"
done

# the temperature run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_HOT=h22, FAKE_NO_HWMON=c2,
# FAKE_NO_IPMI=c3 and FAKE_INLET=39

# FF_TEMPS=0: no reads, no files, no section; FF_IPMI=0: hwmon only
out=$(xrun t0 FF_TEMPS=0 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 timeout 240 $B $C 1)
chk "FF_TEMPS=0: no temps.txt, no Temperatures section" "! tar -tzf \$(bundle t0) | grep -q temps && ! grep -q '^Temperatures' <<<\"\$out\" && [ -n \"\$(bundle t0)\" ]" "$(tar -tzf $(bundle t0) | grep -c temps)"
out=$(xrun t1 FF_IPMI=0 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 timeout 240 $B $C 1)
chk "FF_IPMI=0: hwmon rows, no ipmi rows" "bfile t1 temps.txt | awk '\$3 == \"hwmon\" {h++} \$3 == \"ipmi\" {i++} END {exit !(h > 0 && !i)}'" "$(bfile t1 temps.txt | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')"
out=$(xrun t2 FF_TEMP_RISE=x FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
chk "FF_TEMP_RISE=x refused (rc 2)" "[ $rc = 2 ] && grep -q 'FF_TEMP_RISE must be a whole number' <<<\"\$out\"" "rc=$rc $(grep ERROR <<<"$out")"
finish
