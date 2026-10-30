#!/opt/homebrew/bin/bash
# unit drivers on mlx5-shaped text (tools/mkmlx5.sh; step b, 10-29: was a real host's under FFT_SITE_DATA): diag parsing
# (mawk vs gawk), prio filter, DAC/optic temps, RDMA sysfs reader
# tier: fast
# checks: 15
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
mkdir -p $W/mlx5 && $B $S/tools/mkmlx5.sh raw $W/mlx5/s001.txt s001 && $B $S/tools/mkmlx5.sh dump $W/mlx5/dump.txt && $B $S/tools/mkmlx5.sh ethtool $W/mlx5/ethtool_S.txt || exit 2

# --- diag parsing on mlx5 text, mawk vs gawk ---
a=$(PATH=$S/awkbin/mawk:$PATH $B $S/test_diag.sh $W/mlx5/s001.txt enp5s0np0 enp196s0np0 2>&1)
g=$(PATH=$S/awkbin/gawk:$PATH $B $S/test_diag.sh $W/mlx5/s001.txt enp5s0np0 enp196s0np0 2>&1)
chk "diag mawk == gawk (6 @@ lines)" "[ \"\$a\" = \"\$g\" ] && [ \$(grep -c '' <<<\"\$a\") = 6 ]" "$(grep -c '' <<<"$a") lines"
chk "diag @@LLDP: the leaf and port read from the lldpcli text (leaf-r01-a swp2s1 on enp5s0np0, leaf-r01-b on enp196s0np0)" "grep -q '^@@LLDP s001 enp5s0np0 198.19.1.1 leaf-r01-a swp2s1 ' <<<\"\$a\" && grep -q '^@@LLDP s001 enp196s0np0 198.19.2.1 leaf-r01-b swp2s1 ' <<<\"\$a\"" "$(grep '^@@LLDP' <<<"$a" | tr '\n' '|')"
out=$($B $H/test_prio_real.sh $C $W/mlx5/ethtool_S.txt 2>&1); chk "mlx5 ethtool -S: 54 prio/pause/ECN/discard counters, no per-ring rxN_/txN_" "[ \$(wc -l <<<\"\$out\") -eq 54 ] && ! grep -q -E '^[rt]x[0-9]+_' <<<\"\$out\" && grep -q -x rx_ecn_mark <<<\"\$out\" && grep -q -x rx_discards_phy <<<\"\$out\" && grep -q -x rx_out_of_buffer <<<\"\$out\"" "$(wc -l <<<"$out")"
out=$($B $H/test_hwdump.sh $C $W/mlx5/dump.txt DIAG_SCRIPT ens800f0np0 2>&1 | grep '^@@NIC'); chk "mlx5 DAC (no DDM): temp n/a, not 0.00" "[ \"\${out##* }\" = n/a ]" "$out"
out=$(FF_C=$C $B $S/test_diag.sh $W/mlx5/s001.txt enp5s0np0 2>&1 | grep '^@@NIC'); chk "optic: its module temperature read (47.25) and four rx power channels (control: the DAC NIC reads n/a above)" "[ \"\${out##* }\" = 47.25 ] && grep -q ' -0.91 -0.92 -0.93 -0.94 47.25\$' <<<\"\$out\"" "$out"
out=$($B $H/test_rdma.sh $C $W 2>&1); chk "RDMA reader: VLAN maps to parent, bond and traffic counters skipped" "[ \"\$out\" = \"\$(cat $H/test_rdma.expected)\" ]" "$out"
out=$($B $H/test_txctr.sh $C $W 2>&1); chk "sender TX reader: bond and VLAN-over-bond sum their ports, a member without a port counter gives na" "[ \"\$out\" = \"\$(cat $H/test_txctr.expected)\" ]" "$out"
# --- DIAG_SCRIPT on a bond (10-27 fleet: 7 bonds at 400G of 2x400G): the kernel's bonding report read
# through the FF_PROCNET hook; one slave down -> "@@BOND hx bond0 1 2 ens1np1" and the report in the raw section ---
U=$S/fixtures/units
out=$(FF_PROCNET=$U/procnet $B $H/test_hwdump.sh $C $U/hw_dump_bond.txt DIAG_SCRIPT bond0 2>&1)
chk "bond: @@BOND line: 1 of 2 slaves up, ens1np1 down" "grep -qx '@@BOND hx bond0 1 2 ens1np1' <<<\"\$out\"" "$(grep '@@BOND\|@@DRV' <<<"$out" | tr '\n' '|')"
chk "bond: the kernel's report lands in the raw text under '=== bonding bond0 ==='" "grep -qx '=== bonding bond0 ===' <<<\"\$out\" && grep -qx 'Slave Interface: ens1np1' <<<\"\$out\"" "$(grep -c '' <<<"$out") lines"
out=$(FF_PROCNET=$U/nonexistent $B $H/test_hwdump.sh $C $U/hw_dump_bond.txt DIAG_SCRIPT bond0 2>&1)
chk "control: no bonding report readable -> no @@BOND line, no bonding section, the NIC's other lines as before" "! grep -q '@@BOND\|=== bonding' <<<\"\$out\" && grep -q '^@@DRV hx bond0 .* bonding ' <<<\"\$out\"" "$(grep '@@' <<<"$out" | tr '\n' '|')"
# the bond's members (sysfs bonding/slaves through the FF_SYSFS hook) each get an @@LLDP row on the bond's IP: ens1np0
# names its leaf from the dump's lldpcli section, ens1np1 (no section) is unknown; the bond's own row stays unknown
out=$(FF_SYSFS=$U/sysfs FF_PROCNET=$U/procnet $B $H/test_hwdump.sh $C $U/hw_dump_bond.txt DIAG_SCRIPT bond0 2>&1)
chk "bond: @@LLDP rows for the bond (unknown) and each member on the bond's IP; ens1np0 names leaf-003-compute swp5s1" \
    "[ \"\$(grep '^@@LLDP' <<<\"\$out\" | cut -d' ' -f2-6 | tr '\n' '|')\" = 'hx bond0 192.0.2.1 unknown unknown|hx ens1np0 192.0.2.1 leaf-003-compute swp5s1|hx ens1np1 192.0.2.1 unknown unknown|' ] && grep -qx '=== lldpcli ens1np0 ===' <<<\"\$out\"" "$(grep '^@@LLDP' <<<"$out" | tr '\n' '|')"
out=$(FF_PROCNET=$U/procnet $B $H/test_hwdump.sh $C $U/hw_dump_bond.txt DIAG_SCRIPT bond0 2>&1)
chk "control: no sysfs slaves readable -> one @@LLDP row (the bond, unknown), no member rows" "[ \$(grep -c '^@@LLDP' <<<\"\$out\") = 1 ] && grep -q '^@@LLDP hx bond0 192.0.2.1 unknown' <<<\"\$out\"" "$(grep '^@@LLDP' <<<"$out" | tr '\n' '|')"

# --- err_hist (src/fabric_ferret.sh): the ERROR rows of a results file grouped by iperf3's reason, under every awk;
# the fixture has column -t spacing, three reasons (one without iperf3's prefix), a result row to ignore ---
U=$S/fixtures/units; eval "$(sed -n '/^err_hist() {/,/^}/p' $C)"
for v in bsd mawk gawk; do
    out=$(PATH=$S/awkbin/$v:$PATH err_hist $U/errrows.txt 2>&1)
    chk "err_hist unit, awk=$v: 5 x No route to 5 destinations (4 named ...), 3 x refused to 1 (one row's share:2 dropped), 1 x timeout; most runs first" "[ \"\$out\" = \"\$(cat $U/errrows.expected)\" ]" "$(diff <(cat $U/errrows.expected) <(echo "$out"))"
done
finish
