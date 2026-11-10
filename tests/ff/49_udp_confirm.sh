#!/opt/homebrew/bin/bash
# scope 6 (the operator 11-10: "Go with A"): when a UDP phase ends with unaccounted loss into a host whose line rate is
# not known, each run into it is rerun once, paced (5 s at 80% of what it delivered). Loss that goes at the paced rate
# moves to "rate limit between the hosts (paced run)"; only what persists stays "likely fabric".
# Fake (FAKE_UDP_PATH, by receiving host): h21 and c1 sit behind a rate limit, h22 on a lossy path (15% at any rate),
# h23 both (limit + 2%), h24's paced runs get no result, h25 loses 0.5% (under the trigger), h26 gets nothing.
# checks: 17
# secs: 35
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
X=$S/ff/expected/49_off.log.txt
PATHS='h21:cap=50 h22:loss=150000 h23:cap=50,loss=20000 h24:cap=50,cfail=1 h25:loss=5000 h26:loss=1000000 c1:cap=20'
RUN="FAKE_NOSPEED=1 FAKE_CLIENT_NOSPEED=c1,c2 FF_HOSTS=198.18.0.21-26 FF_CLIENTS=198.18.1.1-2 FF_CLIENT_NETS=198.19.10.0/24,198.19.11.0/24 FF_ITER=1"
# the log's UDP loss lines (per phase and in the summary) and the summary's host rows
udplines() { grep -E '^#   U[CF]?[0-9] (loss|expected)|^  (Lost datagrams|Expected from overload)|^  [hc][0-9]+ +[0-9.]+ +[0-9]+/[0-9]+ ' | sort; }
# paced <args log>: the paced runs the fake saw, "src dst port streams secs len tos bps"
paced() { awk '$1 == "UDPC" { $1 = ""; print substr($0, 2) }' $W/$1.args; }
npaced() { paced $1 | wc -l | tr -d ' '; }

# cf: every case in one run (6 backends, 2 clients, no line speed anywhere)
out=$(xrun cf FAKE_UDP_PATH="$PATHS" $RUN timeout 300 $B $C 1); rc=$?
cp $FAKE_STATE/iperf_args.log $W/cf.args; lm_on=$(cat $FAKE_STATE/lockmax.h21 2>&1)
ue=$(bfile cf udp_expected.txt); uc=$(bfile cf udp_confirm.txt 2>&1)
rows=$(grep -v '^#' <<<"$uc" | grep -E '^iter[0-9]+ ')
# the paced runs a correct tool makes, from the original runs: every run into h21, h22, h23, h24 and c1
want=$(awk '{ split($5, d, "."); c = ($5 ~ /^198\.19\.1[01]\./) } (!c && d[4] >= 21 && d[4] <= 24) || (c && d[4] == 1) { print $4, $5, $11 }' <<<"$ue" | sort)
# moved and left, from the original loss: all of it moves for h21 and c1, all but 2% of the datagrams for h23
read -r M Bx <<<"$(awk '{ split($5, d, "."); c = ($5 ~ /^198\.19\.1[01]\./); m = 0
    if ((!c && d[4] == 21) || (c && d[4] == 1)) m = $9; else if (!c && d[4] == 23) m = $9 - 20000; s += m; l += $9 } END { print s + 0, l - s }' <<<"$ue")"
una=$(grep -m1 '^  Lost datagrams' <<<"$out" | sed 's/.*unaccounted //; s/[^0-9].*//')
# 1
chk "confirm runs: one paced run per original run into a host over the trigger with no line rate (h21, h22, h23, h24, c1: 14 of the 20 UDP runs), each once, on the original's source and destination" \
    "[ \$(npaced cf) = 14 ] && [ \"\$(paced cf | awk '{print \$1, \$2}' | sort)\" = \"\$(awk '{print \$1, \$2}' <<<\"\$want\")\" ] && [ \$(wc -l <<<\"\$want\") = 14 ]" \
    "paced runs $(npaced cf) of $(grep -c '^UDP ' $W/cf.args) UDP runs; rc=$rc; $(paced cf | awk '{print $1 ">" $2}' | sort | tr '\n' ' ' | cut -c1-300)"
# 2: bps per stream = int(0.8 x delivered Gbps x 1e9 / streams), 1 bit/s of rounding allowed
chk "confirm runs: 5 s, the original's port, stream count, datagram length and TOS; -b per stream = 80% of what the run delivered / the streams (h21: 50 Gbps delivered, 16 streams: 2500000000)" \
    "[ \$(npaced cf) = 14 ] && [ \$(paced cf | awk 'NR == FNR { if (\$1 == \"UDP\") o[\$2 \" \" \$3] = \$4 \" \" \$5 \" \" \$7 \" \" (\$8 == \"\" ? \"-\" : \$8); next } \$5 != 5 || o[\$1 \" \" \$2] != \$3 \" \" \$4 \" \" \$6 \" \" \$7 { bad++ } END { print bad + 0 }' $W/cf.args -) = 0 ] && [ \$(paced cf | awk 'NR == FNR { g[\$1 \" \" \$2] = \$3; next } { w = int(0.8 * g[\$1 \" \" \$2] * 1e9 / \$4); d = \$8 - w; if (d < -1 || d > 1) bad++ } END { print bad + 0 }' <(echo \"\$want\") -) = 0 ] && paced cf | grep -qE '^198\\.19\\.2\\.26 198\\.19\\.2\\.21 [0-9]+ 16 5 [0-9]+ [^ ]+ (2500000000|2499999999)\$'" \
    "$(paced cf | sort | head -n 3 | tr '\n' '|'); original: $(grep '^UDP 198.19.2.26 198.19.2.21' $W/cf.args | head -n 1)"
# 3
chk "udp_confirm.txt: a '#' header naming the columns, then a row per confirm run (14): 5 gone (h21 x3, c1 x2), 7 persists (h22 x4, h23 x3), 2 no_result (h24); h26>h21's row: 40 Gbps paced, 0 of 160000 lost" \
    "head -n 1 <<<\"\$uc\" | grep -qE '^# .*paced_gbps.*moved' && [ \$(grep -c . <<<\"\$rows\") = 14 ] && [ \"\$(awk '{print \$NF}' <<<\"\$rows\" | sort | uniq -c | awk '{printf \"%s:%s \", \$2, \$1}')\" = 'gone:5 no_result:2 persists:7 ' ] && awk '\$4 == \"198.19.2.26\" && \$5 == \"198.19.2.21\" && \$6 + 0 == 40 && \$7 == 0 && \$8 == 160000 { f = 1 } END { exit !f }' <<<\"\$rows\"" \
    "$(head -n 1 <<<"$uc" | cut -c1-120); rows $(grep -c . <<<"$rows"); $(awk '{print $NF}' <<<"$rows" | sort | uniq -c | tr '\n' ' ')"
# 4
chk "rate limit (h21, c1): 0 lost at the paced rate, so all of the run's loss moves (800000 per h21 run, 920000 per c1 run); the log names the limit: '...loss gone at a paced rate: overload against a rate limit of about 50 Gb/s between the hosts' (c1: 16 Gb/s paced, about 20)" \
    "[ \"\$(awk '\$5 ~ /^198\\.19\\.[12]\\.21\$/ {print \$(NF-1)}' <<<\"\$rows\" | sort -u)\" = 800000 ] && [ \"\$(awk '\$5 == \"198.19.10.1\" {print \$(NF-1)}' <<<\"\$rows\" | sort -u)\" = 920000 ] && grep -qE '^#  +h26 198\\.19\\.2\\.26 -> h21 198\\.19\\.2\\.21: 40(\\.0+)? Gb/s paced, 0/160000 lost \\(0(\\.0+)?%\\): loss gone at a paced rate: overload against a rate limit of about 50(\\.0+)? Gb/s between the hosts\$' <<<\"\$out\" && grep -qE '-> c1 198\\.19\\.10\\.1: 16(\\.0+)? Gb/s paced, 0/64000 lost .*rate limit of about 20(\\.0+)? Gb/s between the hosts\$' <<<\"\$out\"" \
    "moved: $(awk '$5 ~ /\.21$|^198\.19\.10\.1$/ {print $5 ":" $(NF-1)}' <<<"$rows" | tr '\n' ' '); $(grep -m2 'loss gone' <<<"$out" | cut -c1-200 | tr '\n' '|')"
# 5
chk "control, lossy path (h22: 15% at any rate): confirm runs happen (4), nothing moves, the reading says lossy path: '170 Gb/s paced, 102000/680000 lost (15.000%): loss persists at a paced rate (15.000 %): lossy path'" \
    "[ \"\$(awk '\$5 ~ /^198\\.19\\.[12]\\.22\$/ {print \$(NF-1), \$NF}' <<<\"\$rows\" | sort | uniq -c | awk '{print \$1, \$2, \$3}')\" = '4 0 persists' ] && grep -qE -- '-> h22 198\\.19\\.2\\.22: 170(\\.0+)? Gb/s paced, 102000/680000 lost \\(15(\\.0+)?%\\): loss persists at a paced rate \\(15(\\.0+)? ?%\\): lossy path\$' <<<\"\$out\"" \
    "$(awk '$5 ~ /\.22$/ {print $5 ":" $(NF-1) ":" $NF}' <<<"$rows" | tr '\n' ' '); $(grep -m1 -- '-> h22 ' <<<"$out" | cut -c1-200)"
# 6
chk "mixed (h23: the limit plus 2% at any rate): only the 2% share stays beyond: each run moves 784000 of its 804000 lost (20000 = 2% of the 1000000 sent stays); reading 'loss persists at a paced rate (2.000 %)'" \
    "[ \"\$(awk '\$5 ~ /^198\\.19\\.[12]\\.23\$/ {print \$(NF-1), \$NF}' <<<\"\$rows\" | sort | uniq -c | awk '{print \$1, \$2, \$3}')\" = '3 784000 persists' ] && grep -qE -- '-> h23 198\\.19\\.2\\.23: 39\\.20* Gb/s paced, 3136/156800 lost \\(2(\\.0+)?%\\): loss persists at a paced rate \\(2(\\.0+)? ?%\\): lossy path\$' <<<\"\$out\"" \
    "$(awk '$5 ~ /\.23$/ {print $5 ":" $(NF-1) ":" $NF}' <<<"$rows" | tr '\n' ' '); $(grep -m1 -- '-> h23 ' <<<"$out" | cut -c1-200)"
# 7
chk "a confirm run with no result (h24, 2 runs): nothing moved, lost and sent '-', and the log names each run with 'no result' and 'nothing moved' (never a silent 0)" \
    "[ \"\$(awk '\$5 ~ /^198\\.19\\.[12]\\.24\$/ {print \$7, \$8, \$(NF-1), \$NF}' <<<\"\$rows\" | sort | uniq -c | awk '{print \$1, \$2, \$3, \$4, \$5}')\" = '2 - - 0 no_result' ] && [ \$(grep -cE -- '-> h24 198\\.19\\.[12]\\.24: .*no result.*nothing moved' <<<\"\$out\") = 2 ]" \
    "$(awk '$5 ~ /\.24$/ {print $5 ":" $7 ":" $8 ":" $(NF-1) ":" $NF}' <<<"$rows" | tr '\n' ' '); log lines: $(grep -cE -- '-> h24 ' <<<"$out")"
# 8
chk "no confirm run under the trigger or for a run that delivered nothing: h25 (0.5% lost, FF_UDP_CONFIRM_PCT 1), c2 (0.001%) and h26 (all lost, 0 Gbps) get 0 paced runs and 0 rows (control: h21 has 3 of each)" \
    "[ \$(paced cf | awk '\$2 ~ /^198\\.19\\.[12]\\.2[56]\$/ || \$2 == \"198.19.10.2\"' | wc -l) = 0 ] && [ \$(awk '\$5 ~ /^198\\.19\\.[12]\\.2[56]\$/ || \$5 == \"198.19.10.2\"' <<<\"\$rows\" | grep -c .) = 0 ] && [ \$(paced cf | awk '\$2 ~ /^198\\.19\\.[12]\\.21\$/' | wc -l) = 3 ] && [ \$(awk '\$5 ~ /^198\\.19\\.[12]\\.21\$/' <<<\"\$rows\" | grep -c .) = 3 ]" \
    "paced to h25/h26/c2: $(paced cf | awk '$2 ~ /^198\.19\.[12]\.2[56]$/ || $2 == "198.19.10.2"' | wc -l | tr -d ' '); to h21: $(paced cf | awk '$2 ~ /^198\.19\.[12]\.21$/' | wc -l | tr -d ' ')"
# 9: U1 = one run into each backend: h21's 800000 and 784000 of h23's move; h22 150000, h23 20000, h24 800000, h25 5000, h26 1000000 stay
chk "log, phase U1: the second loss line carries the bucket: 'U1 expected from overload: 0 (0.000%); rate limit between the hosts (paced run): 1584000; unaccounted beyond it (likely fabric): 1975000' (1584000 + 1975000 = the phase's 3559000 unaccounted); a 'paced confirm runs' line per phase, 14 runs in all, naming 80% and 5 s" \
    "grep -qxF '#   U1 expected from overload: 0 (0.000%); rate limit between the hosts (paced run): 1584000; unaccounted beyond it (likely fabric): 1975000' <<<\"\$out\" && grep -qE '^#   U1 loss: 3559000 of 6000000 .* unaccounted 3559000\$' <<<\"\$out\" && [ \$(grep -E '^#   U[CF]?[0-9] paced confirm runs: [0-9]+.*80 ?%.* 5 ?s' <<<\"\$out\" | sed 's/.*paced confirm runs: //; s/[^0-9].*//' | awk '{s += \$1} END {print s + 0}') = 14 ]" \
    "$(grep -E 'U1 (loss|expected)|paced confirm runs' <<<"$out" | cut -c1-200 | tr '\n' '|')"
# 10
chk "summary: 'Expected from overload: 0; rate limit between the hosts (paced run): $M; unaccounted beyond it (likely fabric): $Bx': the bucket is what moved (h21 and c1 all, h23 all but 2%), likely fabric what is left, and the two add up to the unaccounted loss ($una; control: the two are > 0)" \
    "grep -qxF '  Expected from overload: 0; rate limit between the hosts (paced run): $M; unaccounted beyond it (likely fabric): $Bx' <<<\"\$out\" && [ \$(( M + Bx )) = \"$una\" ] && [ $M -gt 0 ] && [ $Bx -gt 0 ] && [ \"\$(awk '{s += \$(NF-1)} END {print s + 0}' <<<\"\$rows\")\" = $M ]" \
    "$(grep -m1 '^  Expected from overload' <<<"$out"); file moved sum $(awk '{s += $(NF-1)} END {print s + 0}' <<<"$rows"); want $M + $Bx = $una"
# 11
chk "metadata.txt records both settings: udp_confirm=1, udp_confirm_pct=1" "[ \"\$(bfile cf metadata.txt | grep -E '^udp_confirm(_pct)?=' | tr '\n' ' ')\" = 'udp_confirm=1 udp_confirm_pct=1 ' ]" "$(bfile cf metadata.txt | grep -E '^udp' | tr '\n' ' ')"
# 12: the page, by its strings (numbers with thousands separators)
render cf; prc=$?
cM=$(printf "%'d" $M 2>&1); cB=$(printf "%'d" $Bx 2>&1)
chk "dashboard, a bundle with udp_confirm.txt: the UDP card's header carries 'rate limit between the hosts (paced run) <moved>' and 'unaccounted beyond expected (likely fabric) <what is left>'; the table has Paced run and Rate limit columns; h26>h21's row reads '40 Gbps, 0.000%' and 800,000 moved; an h24 row reads 'no result'" \
    "grep -qF 'rate limit between the hosts (paced run) $(LC_ALL=en_US.UTF-8 printf "%'d" $M)' $W/cf.html && grep -qF 'unaccounted beyond expected (likely fabric) $(LC_ALL=en_US.UTF-8 printf "%'d" $Bx)' $W/cf.html && grep -q '<th>Paced run</th>' $W/cf.html && grep -q '<th>Rate limit' $W/cf.html && grep -qE '<td>h26 198\\.19\\.2\\.26</td><td>h21 198\\.19\\.2\\.21</td>.*<td[^>]*>40(\\.0+)? Gbps, 0(\\.0+)?%</td><td[^>]*>800,000</td>' $W/cf.html && grep -qE '<td>h24 198\\.19\\.[12]\\.24</td>.*<td[^>]*>no result</td>' $W/cf.html" \
    "rc=$prc $(grep -oE 'expected from overload[^<]*|<b class=\"stat-[a-z]*\">unaccounted[^<]*' $W/cf.html | tr '\n' ' ' | cut -c1-260); th: $(grep -oE '<th>(Paced run|Rate limit[^<]*)</th>' $W/cf.html | tr '\n' ' ')"

# lk: line rates known (FF_LINE_GBPS=400, FF_CLIENT_GBPS=200; widened 11-10: a known line rate does not stop the
# trigger). c1's limit sits under its line: the overload floor (250G into 200G: 20%) comes out first, the rest moves.
# Control: c2 loses 15%, inside its floor: no confirm run
out=$(xrun lk FAKE_UDP_PATH="$PATHS c2:loss=150000" $RUN FF_LINE_GBPS=400 FF_CLIENT_GBPS=200 timeout 300 $B $C 1); rc=$?
cp $FAKE_STATE/iperf_args.log $W/lk.args; lrows=$(bfile lk udp_confirm.txt 2>&1 | grep -E '^iter[0-9]+ ')
chk "line speed known, a limit under it: confirm runs happen (the same 14) and the loss beyond the floor moves: each c1 run 720000 (920000 lost - 200000 expected from overload), each h21 run 800000 (floor 0); control: c2's 15% is within its 20% floor: 0 paced runs and 0 rows for it of $(grep -c '^UDP ' $W/lk.args) UDP runs" \
    "[ \$(npaced lk) = 14 ] && [ \$(grep -c '^UDP ' $W/lk.args) = 20 ] && [ \"\$(awk '\$5 == \"198.19.10.1\" {print \$(NF-1), \$NF}' <<<\"\$lrows\" | sort | uniq -c | awk '{print \$1, \$2, \$3}')\" = '2 720000 gone' ] && [ \"\$(awk '\$5 ~ /^198\\.19\\.[12]\\.21\$/ {print \$(NF-1)}' <<<\"\$lrows\" | sort -u)\" = 800000 ] && [ \$(paced lk | awk '\$2 == \"198.19.10.2\"' | wc -l) = 0 ] && [ \$(awk '\$5 == \"198.19.10.2\"' <<<\"\$lrows\" | grep -c .) = 0 ] && [ \$(awk '\$5 == \"198.19.10.2\" && \$9 == 150000' <<<\"\$(bfile lk udp_expected.txt)\" | grep -c .) = 2 ]" \
    "paced $(npaced lk); rc=$rc; c1: $(awk '$5 == "198.19.10.1" {print $(NF-1) ":" $NF}' <<<"$lrows" | tr '\n' ' ') h21: $(awk '$5 ~ /\.21$/ {print $(NF-1)}' <<<"$lrows" | tr '\n' ' ') c2 paced $(paced lk | awk '$2 == "198.19.10.2"' | wc -l | tr -d ' ')"

# off: FF_UDP_CONFIRM=0 on the first run's input: no confirm run, the UDP loss lines as the tool wrote them before scope 6
# (expected/49_off.log.txt, made on 0039610 with FIXTURE_UPDATE=1, which leaves the setting out: that tool has none)
OFF=FF_UDP_CONFIRM=0; [[ -n $FIXTURE_UPDATE ]] && OFF=FF_UDP=1
out=$(xrun off FAKE_UDP_PATH="$PATHS" $RUN $OFF timeout 300 $B $C 1); rc=$?
cp $FAKE_STATE/iperf_args.log $W/off.args; lm_off=$(cat $FAKE_STATE/lockmax.h21 2>&1)
[[ -n $FIXTURE_UPDATE ]] && { udplines <<<"$out" > $X; echo "WRITTEN  $X ($(wc -l < $X | tr -d ' ') lines)"; }
render off; prc=$?
chk "FF_UDP_CONFIRM=0: 0 paced runs, no udp_confirm.txt, metadata udp_confirm=0, and the log's UDP loss lines (4 phases x 2, the summary's 2, 8 host rows) equal expected/49_off.log.txt, the pre-scope-6 tool's on the same input; its page has 0 'Paced run' and 0 'paced run' (control: the first page has both)" \
    "[ \$(npaced off) = 0 ] && [ \$(grep -c '^UDP ' $W/off.args) = 20 ] && [ \$(tar -tzf \$(bundle off) | grep -c 'udp_confirm') = 0 ] && bfile off metadata.txt | grep -qx 'udp_confirm=0' && [ \$(wc -l < $X) = 18 ] && [ \"\$(udplines <<<\"\$out\")\" = \"\$(cat $X)\" ] && [ \$(grep -c -i 'paced run' $W/off.html) = 0 ] && [ \$(grep -c -i 'paced run' $W/cf.html) -ge 1 ]" \
    "paced $(npaced off); rc=$rc prc=$prc; $(diff $X <(udplines <<<"$out") 2>&1 | head -n 4 | cut -c1-160 | tr '\n' '|'); page 'paced run' lines $(grep -c -i 'paced run' $W/off.html)"
chk "run lock: the max age the run asks for covers the confirm time: with confirm runs on it is 5 s or more above FF_UDP_CONFIRM=0's (the fake keeps take's max age)" \
    "[[ \"$lm_on\" =~ ^[0-9]+\$ && \"$lm_off\" =~ ^[0-9]+\$ ]] && [ \$(( ${lm_on:-0} - ${lm_off:-0} )) -ge 5 ]" "on '$lm_on' off '$lm_off'"

# pct: FF_UDP_CONFIRM_PCT=85 on the same input: only c1 (92% lost) is over the trigger
out=$(xrun pct FAKE_UDP_PATH="$PATHS" $RUN FF_UDP_CONFIRM_PCT=85 timeout 300 $B $C 1); rc=$?
cp $FAKE_STATE/iperf_args.log $W/pct.args
chk "FF_UDP_CONFIRM_PCT=85: only the runs into c1 (92% unaccounted) get a confirm run (2); h21, h23, h24 (80%) and h22 (15%) get none; metadata udp_confirm_pct=85" \
    "[ \$(npaced pct) = 2 ] && [ \"\$(paced pct | awk '{print \$2}' | sort -u)\" = 198.19.10.1 ] && bfile pct metadata.txt | grep -qx 'udp_confirm_pct=85'" \
    "paced $(npaced pct): $(paced pct | awk '{print $1 ">" $2}' | tr '\n' ' '); rc=$rc; $(tail -n 2 <<<"$out" | cut -c1-160 | tr '\n' '|')"
o1=$(xrun b1 $RUN FF_UDP_CONFIRM=2 timeout 60 $B $C 1); r1=$?
o2=$(xrun b2 $RUN FF_UDP_CONFIRM_PCT=abc timeout 60 $B $C 1); r2=$?
chk "bad values die at the start (rc 2): FF_UDP_CONFIRM=2 with \"FF_UDP_CONFIRM must be 0 or 1, got '2'\"; FF_UDP_CONFIRM_PCT=abc with 'FF_UDP_CONFIRM_PCT must be ... got 'abc''" \
    "[ $r1 = 2 ] && [ $r2 = 2 ] && grep -qF \"FF_UDP_CONFIRM must be 0 or 1, got '2'\" <<<\"\$o1\" && grep -qE \"FF_UDP_CONFIRM_PCT must be .*got 'abc'\" <<<\"\$o2\"" \
    "rc $r1 $r2: $(tail -n 1 <<<"$o1" | cut -c1-140) | $(tail -n 1 <<<"$o2" | cut -c1-140)"
finish
