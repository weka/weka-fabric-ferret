#!/opt/homebrew/bin/bash
# expected UDP loss (10-24: "Reporting just need to make it clear where the line is for expected loss";
# 10-25: "Fix the expected-loss floor to use actual send rate"): per receiving NIC, offered = what the senders
# actually sent (received Gbps x sent / delivered), expected = 1 - line/offered when offered is above its line.
# Fake: every UDP sender sends 250G, the receiver gets 250 x delivered; lines: backend rail NICs 400G,
# c1-c3 bonds 200G, c4 two 100G NICs.
# checks: 5
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
CL="FF_CLIENT_RATIO=1:full FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1"

# FAKE_UDP_LOST=150000: every UDP run loses 15% (all of it unaccounted: no host counter rises)
out=$(xrun ue FAKE_UDP_LOST=150000 $CL timeout 300 $B $C 1); rc=$?
ue=$(bfile ue udp_expected.txt)
chk "udp_expected.txt: a row per UDP run with a result" "[ \$(wc -l <<<\"\$ue\") = \$(bfile ue iperf3_udp_results.txt | grep -c receiver) ] && [ \$(wc -l <<<\"\$ue\") -gt 10 ]" "$(wc -l <<<"$ue") rows"
# the offered/expected values per case (this run's, speed unknown, every datagram lost) are units of ff_udp_expect in
# 60, on fixtures from these runs (tools/mkudpx.sh; 10-26: was runs un and ua here too); this run keeps the
# wiring: the file's rows, the log lines, the summary column and the dashboard
chk "log: 15% loss into clients whose floor is 20-60% is within expected: UF2 beyond 0" "grep -qE '^#   UF2 expected from overload: [1-9][0-9]* \\([0-9.]+%\\); unaccounted beyond it \\(likely fabric\\): 0\$' <<<\"\$out\"" "$(grep 'expected from' <<<"$out")"
chk "log: the same 15% between backends (floor 0) is flagged: U1 beyond > 0 (control)" "grep -qE '^#   U1 expected from overload: 0 \\(0\\.000%\\); unaccounted beyond it \\(likely fabric\\): [1-9]' <<<\"\$out\"" "$(grep 'U1 expected' <<<"$out")"
chk "summary: Expected_% column; c4 60.000, h22 0.000" "grep -qE '^ +Host +Avg_Gbps +Lost/Sent +Loss_% +Expected_%' <<<\"\$out\" && grep -qE '^ +c4 .* 60\\.000\$' <<<\"\$out\" && grep -qE '^ +h22 .* 0\\.000\$' <<<\"\$out\"" "$(sed -n '/^UDP (-b 0)/,/unaccounted beyond/p' <<<"$out")"
render ue; prc=$?
chk "dashboard: header splits expected from beyond; a c4 row shows 60.0%" "grep -q 'expected from overload' $W/ue.html && grep -qE 'unaccounted beyond expected \\(likely fabric\\) [1-9]' $W/ue.html && grep -qE '<td>c4 198\\.19\\.1[01]\\.4</td>.*\\(60\\.0%\\)' $W/ue.html" "rc=$prc $(grep -oE 'expected from overload[^<]*' $W/ue.html | head -n 2)"
finish
