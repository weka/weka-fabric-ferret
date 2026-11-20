#!/opt/homebrew/bin/bash
# the tool's version (1.0.0, 2026-11-20): a run writes tool_version=<FERRET_VERSION> to the bundle's metadata.txt and the
# dashboard header shows "fabric_ferret.sh <version>"; a bundle made before 1.0.0 (no tool_version) shows
# "fabric_ferret.sh version unknown"
# checks: 3
# secs: 15
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
fv=$(sed -n 's/^FERRET_VERSION=\([^ ]*\).*/\1/p' $C)
xrun v FF_HOSTS=198.18.0.1-3 FF_ITER=1 timeout 120 $B $C 1 > $W/v.out; rc=$?
chk "run: metadata.txt has tool_version=$fv (the script's FERRET_VERSION)" "[[ '$fv' =~ ^[0-9]+\.[0-9]+\.[0-9]+\$ ]] && [ \"\$(bfile v metadata.txt | grep -c -x 'tool_version=$fv')\" = 1 ]" "rc=$rc fv=$fv $(bfile v metadata.txt | grep -E '^tool' | tr '\n' ' ')"
render v; vrc=$?
chk "dashboard: the header shows 'fabric_ferret.sh $fv'" "[ -s $W/v.html ] && grep -q ' | fabric_ferret.sh $fv | line rate ' $W/v.html" "rc=$vrc $(grep -o '| fabric_ferret.sh [^|]*|' $W/v.html | head -n 1)"
python3 $P $S/fixtures/bundles/14_ub_oldtypes.tar.gz $W/old.html > $W/old.pout 2>&1; orc=$?
chk "dashboard of a bundle with no tool_version: 'fabric_ferret.sh version unknown'" "[ -s $W/old.html ] && ! tar -xzOf $S/fixtures/bundles/14_ub_oldtypes.tar.gz --include='*/metadata.txt' | grep -q '^tool_version=' && grep -q ' | fabric_ferret.sh version unknown | line rate ' $W/old.html" "rc=$orc $(grep -o '| fabric_ferret.sh [^|]*|' $W/old.html | head -n 1)"
finish
