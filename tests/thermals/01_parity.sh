#!/opt/homebrew/bin/bash
# parity with fabric_ferret.sh and the reader on every chip case (from test_thermals.sh, split into sections 10-26)
# tier: fast
# checks: 13
# secs: 38
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- parity with fabric_ferret.sh: the hwmon reader, the summary awk, the host expansion ---
hw() { awk '/echo "@@HWMON \$h - - none - - -"/ {print; exit} {print}' <<<"$1"; }   # the reader up to the end of its hwmon part
ff_ts=$( source "$FF"; echo "$TEMP_SCRIPT" ); tc_ts=$( source "$TC"; echo "$TEMP_SCRIPT" )
chk "parity: hwmon reader identical to fabric_ferret.sh's" "[ \"\$(hw \"\$ff_ts\")\" = \"\$(hw \"\$tc_ts\")\" ] && [ \$(hw \"\$tc_ts\" | wc -l) -gt 15 ]" "$(diff <(hw "$ff_ts") <(hw "$tc_ts"))"
chk "parity: TEMP_SUM_AWK identical" "[ \"\$(source $FF; echo \"\$TEMP_SUM_AWK\")\" = \"\$(source $TC; echo \"\$TEMP_SUM_AWK\")\" ]"
fns="is_ip ip2int int2ip cidr_bounds _emit _need expand_entry _words expand_targets"
chk "parity: host expansion functions identical ($fns)" "[ \"\$(source $FF; declare -f $fns)\" = \"\$(source $TC; declare -f $fns)\" ] && [ -n \"\$(source $TC; declare -f expand_entry)\" ]"
# positive control: one changed character must fail the reader parity check
cp "$TC" $W/drift.sh; perl -pi -e 's/FF_SYSFS:-\/sys\}; n=0$/FF_SYSFS:-\/sys}; n=1/' $W/drift.sh
chk "parity control: a one-character drift (n=0 -> n=1) fails the check" "[ \$(diff $TC $W/drift.sh | grep -c '^>') = 1 ] && [ \"\$(hw \"\$ff_ts\")\" != \"\$(hw \"\$(source $W/drift.sh; echo \"\$TEMP_SCRIPT\")\")\" ]" "$(diff $TC $W/drift.sh)"
for c in all amd nolabel nochips nohwmon; do
    a=$(reader "$FF" $c ipmi | grep '^@@HWMON'); b=$(reader "$TC" $c ipmi | grep '^@@HWMON')
    chk "reader, case $c: same @@HWMON lines from both tools" "[ \"\$a\" = \"\$b\" ] && [ -n \"\$a\" ]" "$(diff <(echo "$a") <(echo "$b"))"
done
chk "reader, case all: 6 sensors over coretemp k10temp nvme mlx5(enp5s0np0) ice(ens1f0), power-only chip skipped" \
    "[ \"\$(reader $TC all - | awk '{print \$3, \$4, \$5}' | tr '\n' ' ')\" = 'coretemp coretemp.0 Package_id_0 coretemp coretemp.0 Core_0 k10temp k10 Tctl nvme nvme0 Composite mlx5 enp5s0np0 temp1 ice ens1f0 temp1 ' ]" "$(reader $TC all -)"

chk "reader, case amd: k10temp Tctl+Tccd1, two nvme, bnxt_en without net/ falls back to its device (pci2)" \
    "[ \"\$(reader $TC amd - | awk '{print \$3, \$4, \$5, \$6, \$7, \$8}' | tr '\n' ' ')\" = 'k10temp k10 Tctl 65000 - - k10temp k10 Tccd1 60500 - - nvme nvme0 Composite 40850 - 84850 nvme nvme1 Composite 41850 - 84850 bnxt_en pci2 temp1 70000 - - ' ]" "$(reader $TC amd -)"
chk "reader, case nolabel: temp1 (no label), temp2 -5000 kept, unreadable temp3 skipped, no none row" \
    "[ \"\$(reader $TC nolabel - | awk '{print \$3, \$5, \$6}' | tr '\n' ' ')\" = 'acpitz temp1 45000 acpitz temp2 -5000 ' ]" "$(reader $TC nolabel -)"
# planted bug (10-26): a reader that never reads temp*_label must fail the all and amd cases' expected lists
perl -pe 's/\[ -r "\$\{b\}_label" \] && lb=\$\(cat "\$\{b\}_label" 2>&1\)/:/' "$TC" > $W/nolabel_bug.sh
chk "planted bug (labels not read): the all and amd case lists no longer match" \
    "[ \$(diff $TC $W/nolabel_bug.sh | grep -c '^>') = 1 ] && [ \"\$(reader $W/nolabel_bug.sh all - | awk '{print \$3, \$4, \$5}' | tr '\n' ' ')\" != 'coretemp coretemp.0 Package_id_0 coretemp coretemp.0 Core_0 k10temp k10 Tctl nvme nvme0 Composite mlx5 enp5s0np0 temp1 ice ens1f0 temp1 ' ] && [ \"\$(reader $W/nolabel_bug.sh amd - | awk '{print \$5}' | tr '\n' ' ')\" != 'Tctl Tccd1 Composite Composite temp1 ' ]" "$(diff $TC $W/nolabel_bug.sh | head -n 4) $(reader $W/nolabel_bug.sh all - | head -n 3)"
finish
