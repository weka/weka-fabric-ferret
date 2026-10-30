#!/opt/homebrew/bin/bash
# FEC during the run (off, uncorrectable, watch), real mlx5 FEC text, the site sample's lifetime counts
# tier: fast
# checks: 3
# needs: site-data
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# the FEC run's checks (off counted, uncorrectable warned, the card, the slow-link diagnosis, the cross-only IP) moved to
# 50_golden_B.sh (10-26): the default fake's FEC faults are in golden-B
out=$($B $H/test_hwdump.sh $C $SITE_HWDUMP FEC_SCRIPT ens800f0np0 ens300f0np0 2>&1); chk "real mlx5: FEC RS read, FEC Off = off" "[ \"\$out\" = \"\$(printf 'hx_ens800f0np0 0 0 0 0\nhx_ens300f0np0 off off off 0')\" ]" "$out"
python3 $P $SITE_SAMPLE $W/sitev2.html > $W/p.out 2>&1
chk "site sample: no rate card, count chart marked cumulative" "! grep -q 'FEC during this run' $W/sitev2.html && grep -q 'cumulative since the counters last reset' $W/sitev2.html"
chk "site sample (v2 format): its slow IPs, none blamed on a lifetime FEC count" "[ \$(grep -o '\"samples\": [0-9]*' $W/sitev2.html | wc -l) -eq $SITE_SAMPLE_SLOW_IPS ] && ! grep -q 'marginal fiber or dirty connector' $W/sitev2.html && grep -q 'lifetime, not a rate' $W/sitev2.html"
finish
