#!/opt/homebrew/bin/bash
# rails on a real site's addressing (subnet lists, NIC names): the two slow unit checks on the site sample
# (FFT_SITE_DATA; its subnets, NIC names, file names and counts come from the site's own site_vars.sh, never from here)
# tier: fast
# checks: 2
# needs: site-data
# secs: 69
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# --fast: the sample's subset (every host with a link down plus a few healthy ones); --full: every host (10-26: 02 was the
# fast tier's long pole, ~13 s per mode, from rail_lookup's per-host spawns)
if [[ $TIER == fast ]]; then sub=$SITE_SUBSET; n=$(grep -c '' "$SITE_SUBSET"); else sub=; n=$SITE_HOSTS; fi
out=$(FF_C=$C FF_RAILS="$SITE_RAILS_SUBNETS" $B $S/test_rails.sh $SITE_DISC $d/host_list.txt $sub 2>&1 | tail -n1)
chk "site sample, subnet-list rails $n/$n, the $SITE_HOSTS_DOWN_RAIL link-down hosts among them" "[[ \"$out\" == *'hosts=$n match=$n mismatch=0 hosts_with_a_down_rail=$SITE_HOSTS_DOWN_RAIL'* ]]" "$out"
out=$(FF_C=$C FF_NICS="$SITE_RAIL_NICS" $B $S/test_rails.sh $SITE_DISC $d/host_list.txt $sub 2>&1 | tail -n1)
chk "site sample, NIC-name rails $n/$n, the $SITE_HOSTS_DOWN_RAIL link-down hosts among them" "[[ \"$out\" == *'hosts=$n match=$n mismatch=0 hosts_with_a_down_rail=$SITE_HOSTS_DOWN_RAIL'* ]]" "$out"
finish
