#!/opt/homebrew/bin/bash
# parser on real/synthetic archives: the site sample, 100G synthetic, a lab canary, an all-0-Gbps run
# tier: fast
# checks: 7
# needs: site-data lab-runs
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(python3 $P $SITE_SAMPLE $W/site.html 2>&1); rc=$?
chk "site sample parses (rc=0)" "[ $rc = 0 ]" "rc=$rc"
chk "site sample: its result count (control: SITE_SAMPLE_RESULTS set)" "[ -n \"\$SITE_SAMPLE_RESULTS\" ] && grep -q \"\$SITE_SAMPLE_RESULTS iperf3 results\" <<<\"\$out\""
chk "site sample: its down/unknown rows in the table" "python3 -c \"import re;h=open('$W/site.html').read();m=re.search(r'id=\\\"not400Table\\\".*?<tbody>(.*?)</tbody>',h,re.S);exit(0 if m and m.group(1).count('<tr>')==$SITE_SAMPLE_DOWN_ROWS else 1)\""
chk "site sample: its slow IPs, none blamed on a lifetime FEC count" "[ \$(grep -o '\"samples\": [0-9]*' $W/site.html | wc -l) -eq $SITE_SAMPLE_SLOW_IPS ] && ! grep -q 'marginal fiber or dirty connector' $W/site.html && grep -q 'lifetime, not a rate' $W/site.html"
out=$(python3 $P $S/g100/g100.tar.gz $W/g100.html 2>&1); chk "100G sample cut-offs" "grep -q \"'G': 87.5\" <<<\"\$out\""
for x in ${FFT_LAB_RUNS:-$HOME/claude/fsLab/runs}/fabric_sleuth_fslab-canary_20261019T065808Z.tar.gz; do
    out=$(python3 $P $x $W/canary.html 2>&1); rc=$?; chk "canary parses" "[ $rc = 0 ]" "rc=$rc"
done
# --- every run at 0 Gbps must not crash the parser ---
out=$(python3 $P ${FFT_LAB_RUNS:-$HOME/claude/fsLab/runs}/finalsmoke_20261019_061741/fabric_sleuth_smoke-tool_v1_fdda79e-mtu_20261019T101916Z.tar.gz $W/zero.html 2>&1); rc=$?
chk "parser: all-0-Gbps archive renders" "[ -s $W/zero.html ] && ! grep -q ZeroDivisionError <<<\"\$out\"" "rc=$rc $(tail -n1 <<<"$out")"
finish
