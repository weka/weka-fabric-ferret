#!/opt/homebrew/bin/bash
# status = worst column; inter-rail total. The dashboard on stored archives (fixtures/bundles/12_*, 10-26): the Status
# and total rules are units in 60 (ff_nic_sum and ff_cross_summary, with planted-bug controls that replace the old
# collector, the pre-ferret fabric_sleuth v2, as this group's control); the phase 2 direction check moved to 16 (it needs a fresh run);
# FF_CROSS_RAIL=0's "no cross-rail total" is checked in 07's FF_CROSS_RAIL=0 run
# tier: fast
# checks: 5
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
X=$S/fixtures/bundles

# (a) A OK, B 95%, cross 60%: worst-of says SLOW(cross)
python3 $P $X/12_slowcross.tgz $W/xa.html > $W/p.out 2>&1
chk "dashboard: SLOW(cross) for the two cross NICs, OK for the other two" "[ \"\$(hrows $W/xa.html)\" = '{\"SLOW(cross)\":2,\"OK\":2}' ]" "$(hrows $W/xa.html)"
chk "dashboard: shared-path finding" "grep -q 'Same-rail runs are OK, cross-rail runs are not: cross-rail median 240.0' $W/xa.html && grep -q 'Cross-rail total: 480.0 Gbps over 2 flows run at once (A-&gt;B 1, B-&gt;A 1)' $W/xa.html"
# (b) A OK, B at 52%, cross at line rate
python3 $P $X/12_bslow.tgz $W/xb.html > $W/p.out 2>&1
chk "dashboard: B at 52%: the rail B NICs SLOW, rail A NICs OK" "[ \"\$(hrows $W/xb.html)\" = '{\"SLOW\":2,\"OK\":2}' ]" "$(hrows $W/xb.html)"
chk "dashboard: cross at line rate, no shared-path finding" "! grep -q 'Same-rail runs are OK, cross-rail' $W/xb.html"
# (e) an archive from the old collector (all cross runs A->B) renders, Status column filled
out=$(python3 $P $X/12_old_v2_allAtoB.tar.gz $W/xe.html 2>&1); rc=$?
chk "old-format archive (all A->B) renders" "{ [ $rc = 0 ] || [ $rc = 3 ]; } && [ \"\$(hrows $W/xe.html)\" = '{\"SLOW(cross)\":4}' ] && grep -q '(A-&gt;B 2, B-&gt;A 0)' $W/xe.html" "rc=$rc $(hrows $W/xe.html)"
finish
