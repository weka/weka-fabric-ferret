#!/opt/homebrew/bin/bash
# Makes the stored parser archives in fixtures/bundles (10-26) with the runs 11, 12 and 14 used to make, into a new
# directory. Usage: tools/mkbundles.sh <ff_repo> <new_dir>. The .tgz ones come from the collector in <ff_repo> (record its
# commit in fixtures/bundles/README); 12_old_v2_allAtoB.tar.gz comes from the pre-ferret fabric_sleuth v2 (renamed)
# and is not regenerated: copy the stored one forward.
R=${1:?usage: tools/mkbundles.sh <ff_repo> <new_dir>}; D=${2:?usage: tools/mkbundles.sh <ff_repo> <new_dir>}
[ -e "$D" ] && { echo "STOP: $D exists"; exit 1; }
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source $H/suite_lock.sh; suite_lock mkbundles
source $H/lib.sh $R/fabric_ferret.sh $R/generate_dashboard.py
mkdir -p "$D"
xrun xa FAKE_BSPEED=380 FAKE_XSPEED=240 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1 > $W/xa.out; cp $(bundle xa) $D/12_slowcross.tgz
xrun xb FAKE_BSPEED=210 FAKE_XSPEED=400 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1 > $W/xb.out; cp $(bundle xb) $D/12_bslow.tgz
xrun xc FF_LINE_GBPS=400,50 FAKE_SPEED_B=50000 FAKE_BSPEED=48 FAKE_XSPEED=380 FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 timeout 60 $B $C 1 > $W/xc.out; cp $(bundle xc) $D/11_routed32.tgz
xrun xs FAKE_XSPEED=40 FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 timeout 60 $B $C 1 > $W/xs.out; cp $(bundle xs) $D/11_xcrit.tgz
# 14's dashboard uplink card: declared at capacity (a), declared far below (b), not declared, h24 without LLDP, no LLDP
up() { xrun "$@" FAKE_BSPEED=380 FAKE_XSPEED=240 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1; }
up ua FF_SPINES=1 FF_SPINE_LINKS=1 FF_SPINE_GBPS=300 > $W/ua.out; cp $(bundle ua) $D/14_ua.tgz
up ub FF_SPINES=2 FF_SPINE_LINKS=2 FF_SPINE_GBPS=1000 > $W/ub.out; cp $(bundle ub) $D/14_ub.tgz
up un > $W/un.out; cp $(bundle un) $D/14_un.tgz
xrun ul FAKE_NO_LLDP=h24 FF_SPINES=1 FF_SPINE_LINKS=1 FF_SPINE_GBPS=300 FF_HOSTS=198.18.0.21-24 FF_ITER=1 timeout 60 $B $C 1 > $W/ul.out; cp $(bundle ul) $D/14_ul.tgz
up ux FAKE_NO_LLDP=all FF_SPINES=1 FF_SPINE_LINKS=1 FF_SPINE_GBPS=300 > $W/ux.out; cp $(bundle ux) $D/14_ux.tgz
# 14's "Where to look" edges (10-29): 14_where = a hot host (h1's CPU climbs to crit over the run), the B rail at 100G
# (CRITICAL under a 400G line's 50%), four clients at 50G, h4 without LLDP (a repair NIC with no switch seen); 14_clean =
# two hosts with nothing wrong. Temperatures on, UDP and the mesh off, one iteration
xrun uw FAKE_HOT=h1 FAKE_BSPEED=100 FAKE_CLIENT_SPEED=50 FAKE_NO_LLDP=h4 FF_HOSTS=198.18.0.1-5 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=198.19.10.0/24,198.19.11.0/24 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=1 timeout 120 $B $C 1 > $W/uw.out; cp $(bundle uw) $D/14_where.tgz
xrun uc FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=1 timeout 60 $B $C 1 > $W/uc.out; cp $(bundle uc) $D/14_clean.tgz
ls -l $D; rm -rf "${W:?}"
