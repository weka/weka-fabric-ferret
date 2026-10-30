#!/opt/homebrew/bin/bash
# rails on a site's addressing (subnet lists, NIC names): the two slow unit checks on a synthetic 253-host site
# (tools/mksite.sh: 8 /24s in two rails, /31 addresses, 16 hosts with rail B's link down; step b, 10-29: was a real
# site's sample under FFT_SITE_DATA)
# tier: fast
# checks: 3
# secs: 66
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
$B $S/tools/mksite.sh $W/site > $W/mksite.out 2>&1 || { cat $W/mksite.out; exit 2; }
RA='198.19.1.0/24,198.19.3.0/24,198.19.5.0/24,198.19.7.0/24;198.19.2.0/24,198.19.4.0/24,198.19.6.0/24,198.19.8.0/24'

# --fast: the subset (every host with a link down plus 8 healthy ones); --full: every host (10-26: 02 was the fast tier's
# long pole, ~13 s per mode, from rail_lookup's per-host spawns)
if [[ $TIER == fast ]]; then sub=$W/site/subset.txt; n=24; else sub=; n=253; fi
out=$(FF_C=$C FF_RAILS="$RA" $B $S/test_rails.sh $W/site/disc $W/site/host_list.txt $sub 2>&1 | tail -n1)
chk "synthetic site, subnet-list rails $n/$n, the 16 link-down hosts among them" "[[ \"$out\" == *'hosts=$n match=$n mismatch=0 hosts_with_a_down_rail=16'* ]]" "$out"
out=$(FF_C=$C FF_NICS=enp5s0np0,enp196s0np0 $B $S/test_rails.sh $W/site/disc $W/site/host_list.txt $sub 2>&1 | tail -n1)
chk "synthetic site, NIC-name rails $n/$n, the 16 link-down hosts among them" "[[ \"$out\" == *'hosts=$n match=$n mismatch=0 hosts_with_a_down_rail=16'* ]]" "$out"
# the positive control for mismatch=0: the subset with one host's rail A NIC renamed (no NIC enp5s0np0) -> mismatch=1
mkdir -p $W/site/disc1 && for h in $(cat $W/site/subset.txt); do cp $W/site/disc/$h $W/site/disc1/; done && sed 's/enp5s0np0/enp5s0np1/g' $W/site/disc/s001 > $W/site/disc1/s001
out=$(FF_C=$C FF_NICS=enp5s0np0,enp196s0np0 $B $S/test_rails.sh $W/site/disc1 $W/site/host_list.txt $W/site/subset.txt 2>&1 | tail -n1)
chk "control: one host's rail NIC renamed -> NIC-name rails 23/24, mismatch=1" "[[ \"$out\" == *'hosts=24 match=23 mismatch=1 hosts_with_a_down_rail=16'* ]]" "$out"
finish
