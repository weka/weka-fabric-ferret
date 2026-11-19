#!/opt/homebrew/bin/bash
# issue 7 (2026-11-19): a bond's own ethtool counters are empty, so a slow bonded pair could not be traced to a member,
# a cable or a switch port. Each bond member is now read around every iteration (BMEM_SCRIPT): FEC and pre-FEC BER,
# symbol errors, discards, carrier drops and its share of the bond's bytes, in bond_members.txt; a flagged member is
# named in the log.
# checks: 7
# secs: 30
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# (u) the remote script on a sysfs tree (FF_SYSFS) and a stub ethtool: bond0 with two members, eth9 no bond
BS=$(sed -n "/^read -r -d '' BMEM_SCRIPT <<'EOF'\$/,/^EOF\$/p" $C | sed '1d;$d')
SY=$W/sys/class/net; mkdir -p $SY/bond0/bonding $SY/eth9 $W/stub
echo 'm1 m2' > $SY/bond0/bonding/slaves
for m in m1 m2; do mkdir -p $SY/$m/statistics; done
printf '%s\n' 1000 > $SY/m1/statistics/rx_bytes; printf '%s\n' 2000 > $SY/m1/statistics/tx_bytes; echo 0 > $SY/m1/statistics/rx_dropped; echo 0 > $SY/m1/statistics/rx_errors; echo 3 > $SY/m1/carrier_down_count
printf '%s\n' 5 > $SY/m2/statistics/rx_bytes; printf '%s\n' 6 > $SY/m2/statistics/tx_bytes; echo 1 > $SY/m2/statistics/rx_dropped; echo 2 > $SY/m2/statistics/rx_errors
printf '%s\n' '#!/usr/bin/env bash' 'm=${@: -1}' 'case "$1" in' '-I) [ "$m" = m2 ] && echo "Active FEC encoding: Off" || printf "Active FEC encoding: RS\n  corrected_blocks: 7\n  uncorrectable_blocks: 0\n";;' '-S) [ "$m" = m1 ] && printf "     rx_corrected_bits_phy: 99\n     rx_pcs_symbol_err_phy: 1\n     rx_discards_phy: 4\n";;' '*) echo "	Speed: 100000Mb/s";; esac' > $W/stub/ethtool
chmod +x $W/stub/ethtool
got=$(PATH=$W/stub:$PATH FF_SYSFS=$W/sys bash -s -- bond0 eth9 - <<<"$BS" 2>&1 | sed 's/^@@BMEM [^ ]* /@@BMEM H /')
want=$(printf '%s\n' '@@BMEM H bond0 m1 100000Mb/s 7 0 99 1 1000 2000 0 0 4 3' '@@BMEM H bond0 m2 100000Mb/s off off off na 5 6 1 2 na na')
chk "member script (sysfs tree, stub ethtool): one row per member of bond0 with FEC, symbol errors, bytes, drops, errors, discards and carrier drops; FEC off on m2; a counter not exposed is na; no row for eth9 (no bond) or -" "[ \"\$got\" = \"\$want\" ]" "got=[$(tr '\n' '|' <<<"$got")]"

# (r) bonded backends, h22's second member bad
B2="FF_HOSTS=198.18.0.21-23 FF_ITER=2 FF_UDP=0 FAKE_BOND_LLDP=h21,h22"
out=$(xrun bm env $B2 FAKE_BMEM_BAD=h22 timeout 120 $B $C 1); rc=$?
bmf=$(bfile bm bond_members.txt)
chk "bonded run: rc 0, 'Bond members over Ns: 4 members of 2 bonds read' in each of the 2 iterations; bond_members.txt 8 rows, 20 fields each; no h23 row (no bond)" \
    "[ $rc = 0 ] && [ \$(grep -c 'Bond members over [0-9]*s: 4 members of 2 bonds read' <<<\"\$out\") = 2 ] && [ \$(wc -l <<<\"\$bmf\") = 8 ] && [ \$(awk 'NF != 20' <<<\"\$bmf\" | wc -l) = 0 ] && ! grep -q '^iter[0-9] h23 ' <<<\"\$bmf\"" \
    "rc=$rc $(grep 'Bond members' <<<"$out" | tr '\n' '|') rows=$(wc -l <<<"$bmf")"
chk "h21's members clean: flags -, each 50% of the bond's rx and tx" \
    "[ \"\$(awk '\$2 == \"h21\" {print \$4, \$13, \$14, \$20}' <<<\"\$bmf\" | sort -u | tr '\n' '|')\" = 'ens1np0 50 50 -|ens3np0 50 50 -|' ]" "$(grep ' h21 ' <<<"$bmf" | tr '\n' '|')"
chk "h22's ens3np0 flagged uncorrectable, symbol_errors, carrier_down and idle_member (1% of the bond); its ens1np0 clean; the log names it once per iteration" \
    "awk '\$2 == \"h22\" && \$4 == \"ens3np0\"' <<<\"\$bmf\" | grep -q 'uncorrectable.*symbol_errors.*carrier_down.*idle_member\$' && [ \"\$(awk '\$2 == \"h22\" && \$4 == \"ens1np0\" {print \$20}' <<<\"\$bmf\" | sort -u)\" = - ] && [ \$(grep -c '^#   h22 enp5s0np0 ens3np0: uncorrectable' <<<\"\$out\") = 2 ] && [ \$(grep -c 'WARNING: bond members flagged in iter[12] (1):' <<<\"\$out\") = 2 ]" \
    "$(grep ' h22 ' <<<"$bmf" | tr '\n' '|') $(grep -A1 'bond members flagged' <<<"$out" | tr '\n' '|')"
# (c) no bonds: the file is there and empty, no log line
out=$(xrun bn env FF_HOSTS=198.18.0.21-22 FF_ITER=1 FF_UDP=0 timeout 120 $B $C 1); rc=$?
chk "no bonds: bond_members.txt in the bundle and empty, no 'Bond members' line" "[ $rc = 0 ] && tar tzf \"\$(bundle bn)\" | grep -q '/bond_members.txt\$' && [ -z \"\$(bfile bn bond_members.txt)\" ] && ! grep -q 'Bond members' <<<\"\$out\"" "rc=$rc $(grep 'Bond members' <<<"$out")"
# (p) planted, one line each: the idle rule gone; the member read never sampled after the iteration
perl -pe 's/if \(tot >= 1e9 && mine < 0\.05 \* tot\) f = f ",idle_member"/if (0) f = f ",idle_member"/' $C > $W/x_idle.sh
out=$(xrun pi env $B2 FAKE_BMEM_BAD=h22 timeout 120 $B $W/x_idle.sh 1)
perl -pe 's/; collect_counters "\$BMEM_SCRIPT" "\$WORK\/bmem_post"$//' $C > $W/x_post.sh
out2=$(xrun pp env $B2 FAKE_BMEM_BAD=h22 timeout 120 $B $W/x_post.sh 1)
chk "planted (1 line each): no idle rule -> h22's ens3np0 not idle_member; no post read -> no rows, no 'Bond members' line" \
    "[ \$(diff $C $W/x_idle.sh | grep -c '^>') = 1 ] && ! bfile pi bond_members.txt | grep -q idle_member && [ \$(diff $C $W/x_post.sh | grep -c '^>') = 1 ] && [ -z \"\$(bfile pp bond_members.txt)\" ] && ! grep -q 'Bond members' <<<\"\$out2\"" \
    "idle=$(bfile pi bond_members.txt | grep -c idle_member) post_rows=$(bfile pp bond_members.txt | wc -l)"
# control for the stub test above: a sysfs tree with no bond gives no row at all
got3=$(PATH=$W/stub:$PATH FF_SYSFS=$W/sys bash -s -- eth9 <<<"$BS" 2>&1)
chk "control: the member script on a NIC that is no bond prints nothing" "[ -z \"\$got3\" ]" "got3=[$got3]"
finish
