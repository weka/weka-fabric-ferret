#!/opt/homebrew/bin/bash
# item 5b (10-24): phase_times.txt, each phase's start and end (UTC), and the start on each phase log line
# checks: 4
# secs: 28
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# the two-iteration UDP + clients run's checks moved to 52_golden_C.sh (10-26)

# one rail: phase 2 skipped, recorded as "- -"
out=$(xrun p1 FF_RAILS=198.19.1.0/24 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
pt=$(bfile p1 phase_times.txt)
chk "one rail: phase 2 row is '1 2 - -', phase 1 has stamps" "grep -qx '1 2 - -' <<<\"\$pt\" && grep -qE '^1 1 $TS $TS\$' <<<\"\$pt\"" "$pt"

# FF_SKIP_IPERF=1: an observation window row, no client rows (no load ran)
out=$(xrun po FF_SKIP_IPERF=1 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
pt=$(bfile po phase_times.txt)
chk "FF_SKIP_IPERF=1: one 'obs' row with stamps, nothing else" "[ \"\$(awk 'NR > 1' <<<\"\$pt\" | wc -l | tr -d ' ')\" = 1 ] && grep -qE '^1 obs $TS $TS\$' <<<\"\$pt\"" "$pt"
chk "FF_SKIP_IPERF=1: observation log line carries its start" "grep -qE '^# Observation window: .*start $TS;' <<<\"\$out\"" "$(grep 'Observation window' <<<"$out")"
# default FF_ITER (10-24: "Default FF_ITER to 3"): three passes
out=$(xrun d3 FF_SKIP_IPERF=1 FF_HOSTS=198.18.0.21,198.18.0.22 timeout 240 $B $C 1); rc=$?
chk "FF_ITER unset: 3 passes ('Iteration 3 of 3', no 4th)" "grep -q 'Iteration 3 of 3 ' <<<\"\$out\" && ! grep -q 'Iteration 4 ' <<<\"\$out\"" "rc=$rc $(grep -E '=== Iteration' <<<"$out")"
finish
