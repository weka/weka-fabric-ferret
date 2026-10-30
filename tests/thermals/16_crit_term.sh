#!/opt/homebrew/bin/bash
# crit only, and TERM mid-sampling (from test_thermals.sh, split into sections 10-26)

# checks: 3
# secs: 14
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- crit only: high = 95% of crit (10-26: "If only a critical limit is given then let's assume warning is within 5% of critical") ---
CASES="198.19.127.1:crithot 198.19.127.2:all"
out=$(run cro FF_HOSTS=198.19.127.1,198.19.127.2 $B $TC); rc=$?
chk "crit only: mlx5 (crit 105, no max) at 101 gets high 99.8 and is flagged high; at 62 (control) not flagged" \
    "[ \"\$(jl cro | jq -r 'select(.type == \"sensor\" and .chip == \"mlx5\") | \"\\(.host):\\(.max_c):\\(.high_c):\\(.crit_c):\\(.flag)\"' | tr '\n' ' ')\" = 'n1:101.0:99.8:105.0:high n2:62.0:99.8:105.0:null ' ]" "$(jl cro | jq -c 'select(.type == "sensor" and .chip == "mlx5")')"
chk "crit only: a sensor with its own high keeps it (ice max 96, crit 102); one with neither stays without (k10temp Tctl)" \
    "[ \"\$(jl cro | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and (.chip == \"ice\" or .chip == \"k10temp\")) | \"\\(.chip):\\(.high_c):\\(.crit_c)\"' | tr '\n' ' ')\" = 'k10temp:null:null ice:96.0:102.0 ' ]" "$(jl cro | jq -c 'select(.type == "sensor" and .host == "n1" and (.chip == "ice" or .chip == "k10temp"))')"

# --- stop mid-sampling: TERM after the first sample still writes what was read ---
CASES="198.19.102.1:all"
( run term FF_HOSTS=198.19.102.1 $B $TC -i 2 -d 60 > $W/term.log ) & tp=$!
for i in $(seq 1 50); do grep -q 'Reading temperatures' $W/term.log && [ -s $W/term/fake/calls.log ] && break; sleep 0.2; done
sleep 1; pk=$(pgrep -o -f "^$B $TC -i 2 -d 60\$"); kill -TERM $pk; wait $tp   # -o: the script, not its sampling subshells
chk "TERM mid-sampling: stops, writes the jsonl, rc 0" "grep -q 'Stopped after' $W/term.log && [ \$(jl term | jq -r 'select(.type == \"sample\")' | jq -s length) -ge 1 ] && grep -q '^RESULT data=COMPLETE' $W/term.log" "pid=$pk $(tail -n 4 $W/term.log)"
finish
