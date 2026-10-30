#!/opt/homebrew/bin/bash
# parsers name the page <run>.html for .tgz and .tar.gz, never over the archive. On the stored archives 12 parses
# (fixtures/bundles, 10-26); "run writes a .tgz bundle, no .tar.gz" is checked in 50_golden_B.sh
# tier: fast
# checks: 3
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
X=$S/fixtures/bundles
mkdir -p $W/nm; cp $X/12_slowcross.tgz $W/nm/run1.tgz; cp $X/12_old_v2_allAtoB.tar.gz $W/nm/run2.tar.gz; s1=$(cksum < $W/nm/run1.tgz); s2=$(cksum < $W/nm/run2.tar.gz)
python3 $P $W/nm/run1.tgz > $W/p.out 2>&1; python3 $P $W/nm/run2.tar.gz >> $W/p.out 2>&1
chk "parser: run1.tgz -> run1.html, archive untouched" "[ -s $W/nm/run1.html ] && [ ! -e $W/nm/run1.tgz.html ] && [ \"\$(cksum < $W/nm/run1.tgz)\" = \"$s1\" ]" "$(ls $W/nm)"
chk "parser: old run2.tar.gz -> run2.html, archive untouched" "[ -s $W/nm/run2.html ] && [ ! -e $W/nm/run2.tar.gz.html ] && [ \"\$(cksum < $W/nm/run2.tar.gz)\" = \"$s2\" ] && grep -q 'Cross<small>rail to rail' $W/nm/run2.html" "$(ls $W/nm)"
out=$(python3 $P $W/nm/run1.tgz $W/nm/run1.tgz 2>&1); chk "parser refuses to write over the archive" "grep -q 'is the input archive' <<<\"\$out\" && [ \"\$(cksum < $W/nm/run1.tgz)\" = \"$s1\" ]" "$out"
finish
