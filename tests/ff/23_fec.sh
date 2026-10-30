#!/opt/homebrew/bin/bash
# FEC during the run (off, uncorrectable, watch), mlx5 FEC text, an old archive's lifetime counts (tools/mkmlx5.sh and
# tools/mkv2.sh; step b, 10-29: was a real NIC's dump and a real site's sample under FFT_SITE_DATA)
# tier: fast
# checks: 3
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# the FEC run's checks (off counted, uncorrectable warned, the card, the slow-link diagnosis, the cross-only IP) moved to
# 50_golden_B.sh (10-26): the default fake's FEC faults are in golden-B
$B $S/tools/mkmlx5.sh dump $W/dump.txt || exit 2   # (step b, 10-29: was a real NIC's dump under FFT_SITE_DATA)
out=$($B $H/test_hwdump.sh $C $W/dump.txt FEC_SCRIPT ens800f0np0 ens300f0np0 2>&1); chk "mlx5 dump: FEC RS read (0 0 0 0), FEC Off = off" "[ \"\$out\" = \"\$(printf 'hx_ens800f0np0 0 0 0 0\nhx_ens300f0np0 off off off 0')\" ]" "$out"
$B $S/tools/mkv2.sh $W/v2.tar.gz v2 > $W/mk.out && $B $S/tools/mkv2.sh $W/rates.tar.gz rates >> $W/mk.out || { cat $W/mk.out; exit 2; }
python3 $P $W/v2.tar.gz $W/sitev2.html > $W/p.out 2>&1
python3 $P $W/rates.tar.gz $W/rates.html > $W/pr.out 2>&1
chk "v2 archive (lifetime counts only): no rate card, the count chart marked cumulative (control: the fec_rates variant has the rate card)" "! grep -q 'FEC during this run' $W/sitev2.html && grep -q 'cumulative since the counters last reset' $W/sitev2.html && grep -q 'FEC during this run' $W/rates.html"
chk "v2 archive: 184 slow IPs, none blamed on a lifetime FEC count (control: the fec_rates variant blames s005's two NICs on their pre-FEC BER)" "[ \$(grep -o '\"samples\": [0-9]*' $W/sitev2.html | wc -l) -eq 184 ] && [ \$(grep -c 'correction limit' $W/sitev2.html) = 0 ] && grep -q 'lifetime, not a rate' $W/sitev2.html && [ \$(grep -o 'above the RS(544,514) correction limit' $W/rates.html | wc -l | tr -d ' ') = 2 ]" "$(grep -o '"samples": [0-9]*' $W/sitev2.html | wc -l | tr -d ' ') samples; rates: $(grep -o 'above the RS(544,514) correction limit' $W/rates.html | wc -l | tr -d ' ')"
finish
