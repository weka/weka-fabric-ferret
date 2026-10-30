#!/opt/homebrew/bin/bash
# preflight findings (swapped NICs, LLDP wrong rail, gateway) and the LLDP check on a synthetic 253-host site's rows
# (tools/mksite.sh; step b, 10-29: was a real site's sample under FFT_SITE_DATA)
# checks: 6
# secs: 14
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FAKE_SWAP=h2 FAKE_GWFAIL=h3 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull)
chk "swapped NICs found" "grep -q 'h2 swapped_nics' <<<\"\$out\""
chk "LLDP wrong rail x2" "[ \$(grep -c 'h2 lldp_wrong_rail' <<<\"\$out\") = 2 ]"
chk "gateway failure found" "grep -q 'h3 B 198.19.2.3 GW 198.19.2.254 FAIL' <<<\"\$out\""
t=$(ls $W/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/pf.html > $W/p.out 2>&1
chk "preflight card lists 5" "grep -q '<b class=\"stat-bad\">5</b> findings' $W/pf.html"
# golden-B2 (10-26): this group's one run; its clean-layout control is golden-B (50: no swap/LLDP/gateway warnings)
$B $S/tools/mksite.sh $W/site > $W/mksite.out 2>&1 || { cat $W/mksite.out; exit 2; }
out=$(FF_C=$C $B $S/test_lldp.sh $W/site/lldp_neighbors.txt $W/site/host_list.txt 2>&1 | tail -n1); chk "LLDP check: 506 rows of a 253-host site, a leaf per rail per rack, 0 false positives (control: the planted swap below counts 2)" "[ \"\$out\" = 'anomalies: 0' ]" "$out"
out=$(FF_C=$C $B $S/test_lldp.sh $W/site/lldp_swapped.txt $W/site/host_list.txt 2>&1 | tail -n1); chk "LLDP check: the same rows with one host's two leaf names swapped, 2 anomalies" "[ \"\$out\" = 'anomalies: 2' ]" "$out"
finish
