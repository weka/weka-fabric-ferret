#!/opt/homebrew/bin/bash
# --compare against an older run; the parser on a fabric_sleuth v1 archive
# tier: fast
# checks: 5
# needs: site-data lab-runs
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(python3 $P $SITE_CMP_NEW $W/cmp.html --compare $SITE_SAMPLE 2>&1)
chk "compare: planted changes found" "grep -q '10 NIC changes, 1 newly down IPs, 0 recovered' <<<\"\$out\"" "$(grep changes <<<"$out")"
chk "compare: throughput, fw, LLDP, reset in card" "grep -q '142.7 Gbps (-50%)' $W/cmp.html && grep -q \"follows \${SITE_RAW_HOST%.txt} \${SITE_RAIL_NICS%%,*} (sent less)\" $W/cmp.html && grep -q 'fw 28.48.1000' $W/cmp.html && grep -q 'swp9s1' $W/cmp.html && grep -q 'counter reset' $W/cmp.html"
out=$(python3 $P $SITE_SAMPLE $W/self.html --compare $SITE_SAMPLE 2>&1)
chk "compare: run vs itself = no changes" "grep -q '0 NIC changes, 0 newly down IPs, 0 recovered' <<<\"\$out\""
out=$(python3 $P $SITE_SAMPLE --compare 2>&1); chk "compare: missing arg fails loudly" "grep -q 'needs an older run' <<<\"\$out\""
python3 $P ${FFT_LAB_RUNS:-$HOME/claude/fsLab/runs}/fabric_sleuth_fslab-canary_20261019T065808Z.tar.gz $W/v1c.html > $W/p.out 2>&1; rc=$?
chk "parser on a fabric_sleuth v1 archive rc=0 with note" "[ $rc = 0 ] && grep -q 'without coverage counts' $W/p.out" "rc=$rc"
finish
