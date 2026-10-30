#!/opt/homebrew/bin/bash
# the same output under three awks (from test_thermals.sh, split into sections 10-26)

# checks: 2
# secs: 26
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- the same output under three awks (local and remote side) ---
if [[ $TIER == full ]]; then
CASES="198.19.105.1:all 198.19.105.2:hot 198.19.105.3:nohwmon 198.19.105.4:sudo 198.19.105.5:down"
for v in bsd mawk gawk; do
    XPATH=$AWKBIN/$v run awk_$v FF_HOSTS=198.19.105.1-5 $B $TC -o jsonl,html,md -i 1 -d 2 > $W/awk_$v.log
    { jl awk_$v | strip_time; sed -E 's/[0-9]{2}:[0-9]{2}:[0-9]{2} UTC|20[0-9-]+T[0-9:]+Z/T/g' $W/awk_$v/out/*.html $W/awk_$v/out/*.md; } > $W/awk_$v.norm
done
chk "awk: bsd, mawk and gawk give the same jsonl and html" "cmp -s $W/awk_bsd.norm $W/awk_mawk.norm && cmp -s $W/awk_bsd.norm $W/awk_gawk.norm && [ \$(wc -l < $W/awk_bsd.norm) -gt 40 ]" "$(diff $W/awk_bsd.norm $W/awk_mawk.norm | head -n 5; diff $W/awk_bsd.norm $W/awk_gawk.norm | head -n 5)"
chk "awk: three different awks behind awkbin (bsd, mawk, gawk)" "[ \$(for v in bsd mawk gawk; do readlink $AWKBIN/\$v/awk; done | sort -u | wc -l) = 3 ]" "$(for v in bsd mawk gawk; do readlink $AWKBIN/$v/awk; done)"
fi
finish
