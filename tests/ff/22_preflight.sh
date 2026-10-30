#!/opt/homebrew/bin/bash
# preflight findings (swapped NICs, LLDP wrong rail, gateway) and the LLDP check on the site sample's data
# checks: 6
# needs: site-data
# secs: 16
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FAKE_SWAP=h2 FAKE_GWFAIL=h3 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull)
chk "swapped NICs found" "grep -q 'h2 swapped_nics' <<<\"\$out\""
chk "LLDP wrong rail x2" "[ \$(grep -c 'h2 lldp_wrong_rail' <<<\"\$out\") = 2 ]"
chk "gateway failure found" "grep -q 'h3 B 198.19.2.3 GW 198.19.2.254 FAIL' <<<\"\$out\""
t=$(ls $W/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/pf.html > $W/p.out 2>&1
chk "preflight card lists 5" "grep -q '<b class=\"stat-bad\">5</b> findings' $W/pf.html"
# golden-B2 (10-26): this group's one run; its clean-layout control is golden-B (50: no swap/LLDP/gateway warnings)
out=$(FF_C=$C $B $S/test_lldp.sh $d/lldp_neighbors.txt $d/host_list.txt 2>&1 | tail -n1); chk "LLDP check: the site sample's real data, 0 false positives (control: the planted swap below counts 2)" "[ \"\$out\" = 'anomalies: 0' ]" "$out"
out=$(FF_C=$C $B $S/test_lldp.sh $SITE_LLDP_SWAPPED $d/host_list.txt 2>&1 | tail -n1); chk "LLDP check: the site sample with a planted swap, 2 anomalies" "[ \"\$out\" = 'anomalies: 2' ]" "$out"
finish
