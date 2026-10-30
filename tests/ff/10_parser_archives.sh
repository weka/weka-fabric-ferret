#!/opt/homebrew/bin/bash
# parser on old-format archives of a 253-host site (tools/mkv2.sh; step b, 10-29: was a real site's sample and two lab
# runs under FFT_SITE_DATA / FFT_LAB_RUNS), 100G synthetic, a v1-shaped run, an all-0-Gbps run
# tier: fast
# checks: 7
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
for m in v2 rates v1 zero; do $B $S/tools/mkv2.sh $W/$m.tar.gz $m >> $W/mk.out || { cat $W/mk.out; exit 2; }; done
v1out=$(python3 $P $W/v1.tar.gz $W/canary.html 2>&1); v1rc=$?   # the v1-shaped archive: rendered first, a control below

# v2: 253 hosts, one iteration of two phases, every 5th host slow on both rails, 16 hosts with rail B down (Unknown!),
# lifetime FEC counts on every NIC (no fec_rates.txt)
out=$(python3 $P $W/v2.tar.gz $W/site.html 2>&1); rc=$?
chk "v2 site archive parses (rc=0)" "[ $rc = 0 ]" "rc=$rc $(tail -n 2 <<<"$out" | tr '\n' '|')"
chk "v2 site archive: 708 iperf3 results (504 phase 1 + 204 phase 2 rows: the 16 down rails run nothing)" "grep -q '708 iperf3 results' <<<\"\$out\"" "$(grep 'iperf3 results' <<<"$out")"
# (the table's rows sit on one line: count <tr> occurrences from the table's id to its </tbody>, less the header row)
rows() { awk '/id="not400Table"/ {on = 1} on {n += gsub(/<tr>/, "")} on && /<\/tbody>/ {exit} END {print n - 1}' "$1"; }
chk "v2 site archive: the 16 down rail-B NICs (Unknown!) are the inventory table's rows (control: the v1-shaped archive, nothing down, has 0)" "[ \$(rows $W/site.html) = 16 ] && [ \$(rows $W/canary.html) = 0 ]" "$(rows $W/site.html) rows"
# a lifetime count has no time base, so no slow IP is blamed on it; the control: the same site with fec_rates.txt rows
# putting s005's two NICs over the FEC limit is blamed ("above the RS(544,514) correction limit")
python3 $P $W/rates.tar.gz $W/rates.html > $W/rates.pout 2>&1
chk "v2 site archive: 184 slow IPs, none blamed on a lifetime FEC count ('correction limit' 0, 'lifetime, not a rate' said; control: the fec_rates variant blames s005's NICs, 2 hits)" "[ \$(grep -o '\"samples\": [0-9]*' $W/site.html | wc -l) -eq 184 ] && [ \$(grep -c 'correction limit' $W/site.html) = 0 ] && grep -q 'lifetime, not a rate' $W/site.html && [ \$(grep -o 'above the RS(544,514) correction limit' $W/rates.html | wc -l | tr -d ' ') = 2 ]" "samples $(grep -o '"samples": [0-9]*' $W/site.html | wc -l | tr -d ' '); rates page: $(grep -o 'above the RS(544,514) correction limit' $W/rates.html | wc -l | tr -d ' ') blamed, $(grep -o 'slow IPs.*' $W/rates.pout | head -n 1)"
out=$(python3 $P $S/g100/g100.tar.gz $W/g100.html 2>&1); chk "100G sample cut-offs" "grep -q \"'G': 87.5\" <<<\"\$out\""
chk "v1-shaped archive parses (rc=0)" "[ $v1rc = 0 ]" "rc=$v1rc $(tail -n 2 <<<"$v1out" | tr '\n' '|')"
# --- every run at 0 Gbps must not crash the parser ---
out=$(python3 $P $W/zero.tar.gz $W/zero.html 2>&1); rc=$?
chk "parser: all-0-Gbps archive renders (no ZeroDivisionError; control: the 756 rows all read 0.00 Gbits/sec)" "[ -s $W/zero.html ] && ! grep -q ZeroDivisionError <<<\"\$out\" && [ \$(tar xzOf $W/zero.tar.gz --include='*/iperf3_results.txt' | grep -c '0.00  Gbits/sec') = 756 ]" "rc=$rc $(tail -n1 <<<"$out")"
finish
