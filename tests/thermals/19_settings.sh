#!/opt/homebrew/bin/bash
# verdicts, formats, settings (from test_thermals.sh, split into sections 10-26)

# checks: 26
# secs: 25
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- verdicts, formats, settings ---
CASES="198.19.103.1:down 198.19.103.2:down"
out=$(run none FF_HOSTS=198.19.103.1,198.19.103.2 $B $TC); rc=$?
chk "two listed hosts, both unreachable: rc 4 NONE, one line says so, neither named without -v" "[ $rc = 4 ] && grep -q '^RESULT data=NONE hosts=0/0 sensors=0 .* unreachable=2\$' <<<\"\$out\" && grep -q 'none of the 2 targets took an ssh connection (-v lists them)' <<<\"\$out\" && ! grep -q 'NO TEMPERATURE DATA: 198\\.19\\.103\\.' <<<\"\$out\"" "rc=$rc $(tail -n 6 <<<"$out")"
CASES="198.19.104.1:all"
out=$(run ipmi0 FF_IPMI=0 FF_HOSTS=198.19.104.1 $B $TC); rc=$?
chk "FF_IPMI=0: hwmon only, no ipmi readings or nodata" "[ $rc = 0 ] && [ \"\$(jl ipmi0 | jq -r 'select(.source) | .source' | sort -u | tr '\n' ' ')\" = 'hwmon ' ]" "rc=$rc"
# FF_MAX_TARGETS is checked before FF_HOSTS expands against it (the check moved behind the -t load once, 10-27, and
# a bad value then surfaced as "adds 1 targets, past FF_MAX_TARGETS=abc")
out=$(run mtb FF_MAX_TARGETS=abc FF_HOSTS=198.19.104.1 $B $TC --list); rc=$?
chk "FF_MAX_TARGETS=abc in the environment: refused by name before any expansion" "[ $rc = 2 ] && grep -q \"^ERROR: FF_MAX_TARGETS must be a positive integer, got 'abc'\" <<<\"\$out\"" "rc=$rc $out"
# the same from a -t file's settings line (10-27, step 2): the value reaches the run, past the defaults
mkdir -p $W/ipf; printf '%s\n' 'FF_IPMI=0' 'backend,198.19.104.1' > $W/ipf/targets.csv
out=$(run ipf env -u FF_HOSTS $B $TC -t $W/ipf/targets.csv); rc=$?
chk "FF_IPMI=0 as a -t settings line: hwmon only, as from the environment" "[ $rc = 0 ] && [ \"\$(jl ipf | jq -r 'select(.source) | .source' | sort -u | tr '\n' ' ')\" = 'hwmon ' ]" "rc=$rc $(tail -n 2 <<<"$out")"
out=$(run oj FF_HOSTS=198.19.104.1 $B $TC); chk "default -o: one .jsonl, no .html" "[ \"\$(ls $W/oj/out | sed 's/.*\\.//' | tr '\n' ' ')\" = 'jsonl ' ]" "$(ls $W/oj/out)"
out=$(run oh FF_HOSTS=198.19.104.1 $B $TC -o html); chk "-o html: one .html, no .jsonl" "[ \"\$(ls $W/oh/out | sed 's/.*\\.//' | tr '\n' ' ')\" = 'html ' ]" "$(ls $W/oh/out)"
out=$(run lab FF_LABEL='rack 7/a' FF_HOSTS=198.19.104.1 $B $TC -o jsonl,md); chk "FF_LABEL: the title inside the files (made safe), not the file name" "ls $W/lab/out | grep -qE '^thermcap_20[0-9]{6}T[0-9]{6}Z\\.jsonl\$' && grep -q '^# Thermals: rack_7_a\$' $W/lab/out/*.md && jq -e 'select(.type == \"run\") | .label == \"rack_7_a\"' $W/lab/out/*.jsonl > $W/lab.jq" "$(ls $W/lab/out)"
out=$(run omd FF_HOSTS=198.19.104.1 $B $TC -o md,html,md); chk "-o md,html,md: one .md and one .html (repeat ignored)" "[ \"\$(ls $W/omd/out | sed 's/.*\\.//' | sort | tr '\n' ' ')\" = 'html md ' ]" "$(ls $W/omd/out)"
for bad in "-o csv|got 'csv' in 'csv'" "-o both|got 'both' in 'both'" "-o jsonl,,md|comma-separated list of jsonl, html, md; got 'jsonl,,md'" "-o html,|got 'html,'" "-i 5|-i needs -d" "-d x|-d must be a whole number of seconds" "-i 0 -d 5|-i must be a positive whole number" "-i 10 -d 5|-d (5) must be at least -i (10)" "-x|unknown option -x" "extra|unexpected argument 'extra'" "-o|-o needs a value"; do
    a=${bad%%|*}; m=${bad#*|}
    out=$(run bad FF_HOSTS=198.19.104.1 $B $TC $a); rc=$?
    chk "refused: '$a' (rc 2)" "[ $rc = 2 ] && grep -qF -- \"\$m\" <<<\"\$out\" && grep -q '^RESULT data=STOPPED' <<<\"\$out\"" "rc=$rc $out"
done
for s in "FF_TEMP_RISE=x|FF_TEMP_RISE must be a whole number" "FF_IPMI=2|FF_IPMI must be 0 or 1" "FF_IPMI_TIMEOUT=0|FF_IPMI_TIMEOUT must be a positive integer" "FF_HOSTS=198.19.104.300|bad octet '300'" "FF_HOSTS=198.19.104.1/33|bad CIDR" "FF_HOSTS=|no targets: set FF_HOSTS or give -t <file>" "FF_OUT_DIR=/nonexistent|is not a writable directory"; do
    out=$(run bad env FF_HOSTS=198.19.104.1 "${s%%|*}" $B $TC); rc=$?   # env: the later assignment wins
    chk "refused: ${s%%|*} (rc 2)" "[ $rc = 2 ] && grep -qF -- \"${s#*|}\" <<<\"\$out\"" "rc=$rc $out"
done
finish
