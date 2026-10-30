#!/opt/homebrew/bin/bash
# --compare against an older run; the parser on a v1-shaped archive (tools/mkv2.sh; step b, 10-29: was a real site's
# sample and a lab run under FFT_SITE_DATA / FFT_LAB_RUNS)
# tier: fast
# checks: 5
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
$B $S/tools/mkv2.sh $W/v2.tar.gz v2 > $W/mk.out && $B $S/tools/mkv2.sh $W/new.tar.gz new >> $W/mk.out && $B $S/tools/mkv2.sh $W/v1.tar.gz v1 >> $W/mk.out || { cat $W/mk.out; exit 2; }

# the "new" run plants: s002 sends at half on both NICs (its partners' received rows follow it), s004's two NICs on
# firmware 28.00.1000, s006 enp5s0np0's LLDP port description swp9s1, s008 enp5s0np0's lifetime FEC count below the old one
# (a counter reset), s010 enp5s0np0 3 link down events, s012's rail B newly down (Unknown!, its runs gone: no result)
out=$(python3 $P $W/new.tar.gz $W/cmp.html --compare $W/v2.tar.gz 2>&1)
chk "compare: the planted changes found: 14 NIC changes, 1 newly down IP, 0 recovered" "grep -q '14 NIC changes, 1 newly down IPs, 0 recovered' <<<\"\$out\"" "$(grep changes <<<"$out")"
chk "compare: throughput -50% (sent, and received 'follows s002 enp5s0np0 (sent less)'), fw 28.00.1000, LLDP swp9s1, counter reset, link down events 0 -> 3 (+3) in the card" "grep -q '190.0 Gbps (-50%)' $W/cmp.html && grep -q 'follows s002 enp5s0np0 (sent less)' $W/cmp.html && grep -q 'fw 28.00.1000' $W/cmp.html && grep -q 'leaf-r01-a.example - swp9s1' $W/cmp.html && grep -q 'counter reset' $W/cmp.html && grep -q '>3 (+3)<' $W/cmp.html" "$(grep -o -E '190.0 Gbps \(-50%\)[^<]*|fw 28.00.1000|counter reset|>3 \(\+3\)<' $W/cmp.html | sort | uniq -c | tr '\n' ';')"
out=$(python3 $P $W/v2.tar.gz $W/self.html --compare $W/v2.tar.gz 2>&1)
chk "compare: run vs itself = no changes" "grep -q '0 NIC changes, 0 newly down IPs, 0 recovered' <<<\"\$out\""
out=$(python3 $P $W/v2.tar.gz --compare 2>&1); chk "compare: missing arg fails loudly" "grep -q 'needs an older run' <<<\"\$out\""
python3 $P $W/v1.tar.gz $W/v1c.html > $W/p.out 2>&1; rc=$?
chk "parser on a v1-shaped archive (rails.txt, packet_drops.txt, no coverage keys; nothing down or slow): rc=0 with the note" "[ $rc = 0 ] && grep -q 'without coverage counts' $W/p.out" "rc=$rc $(tail -n 2 $W/p.out | tr '\n' '|')"
finish
