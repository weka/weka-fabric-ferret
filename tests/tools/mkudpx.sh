#!/opt/homebrew/bin/bash
# Makes the ff_udp_expect unit fixtures (fixtures/units/udpx_*, 10-26) from 39's three runs, into a new
# directory: the program's three inputs (iplines rebuilt the way FF builds it, udp_tx.txt, iperf3_udp_results.txt)
# and FF's own udp_expected.txt as the expected output. Usage: tools/mkudpx.sh <ff_repo> <new_dir>
R=${1:?usage: tools/mkudpx.sh <ff_repo> <new_dir>}; D=${2:?usage: tools/mkudpx.sh <ff_repo> <new_dir>}
[ -e "$D" ] && { echo "STOP: $D exists"; exit 1; }
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source $H/suite_lock.sh; suite_lock mkudpx
source $H/lib.sh $R/fabric_ferret.sh $R/generate_dashboard.py
mkdir -p "$D"
NETS=198.19.10.0/24,198.19.11.0/24
CL="FF_CLIENT_RATIO=1:full FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1"
mk() { local n=$1; shift
    xrun $n "$@" $CL timeout 300 $B $C 1 > $W/$n.out
    # iplines as FF writes it: a backend rail IP its rail's line (both rails 400 here), a client data NIC its speed
    { bfile $n host_list.txt | awk '{print $3, 400; print $4, 400}'
      bfile $n clients.txt | awk 'NR > 1 && $4 != "none" {s = $7; sub(/Mb\/s/, "", s); print $4, (s ~ /^[0-9]+$/ ? s / 1000 : 0)}'; } > $D/udpx_${n}_iplines.txt
    bfile $n udp_tx.txt > $D/udpx_${n}_tx.txt; bfile $n iperf3_udp_results.txt > $D/udpx_${n}_res.txt
    bfile $n udp_expected.txt > $D/udpx_${n}_expected.txt
}
mk ue FAKE_UDP_LOST=150000
mk un FAKE_CLIENT_NOSPEED=c1 FAKE_UDP_LOST=150000
mk ua FAKE_UDP_LOST=1000000
wc -l $D/*; rm -rf "${W:?}"
