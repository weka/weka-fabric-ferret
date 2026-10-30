#!/opt/homebrew/bin/bash
# usage: test_uplink.sh <collector> <workdir> [span]: feeds uplink_summary a synthetic 24-host run shaped like a
# two-leaf site (rail A on one leaf, rail B on the other, 24 cross flows all A->B, 6.28 T) declared 4 x 2 x 800G.
# span: rail A of h13-h24 sits on a third leaf (leafc), so same-rail phase 1 runs cross leaves too.
C=${1:?collector}; W=${2:?workdir}; SPAN=$3; mkdir -p "$W"
source "$C"
: > "$W/ipmap"; : > "$W/lldp"; : > "$W/diag"
for n in $(seq 1 24); do
    echo "198.19.1.$n h$n A" >> "$W/ipmap"; echo "198.19.2.$n h$n B" >> "$W/ipmap"
    la=leafa.example; [[ -n $SPAN && $n -gt 12 ]] && la=leafc.example
    echo "h$n enpA 198.19.1.$n $la swp$n x y" >> "$W/lldp"; echo "h$n enpB 198.19.2.$n leafb.example swp$n x y" >> "$W/lldp"
    echo "h$n enpA 198.19.1.$n 400000Mb/s" >> "$W/diag"; echo "h$n enpB 198.19.2.$n 400000Mb/s" >> "$W/diag"
done
{ echo "### iteration:1 phase:1"
  for n in $(seq 1 12); do m=$(( n + 12 ))
      echo "198.19.1.$n,198.19.1.$m,[SUM]  0.00-30.00  sec  1400  GBytes  385  Gbits/sec  receiver  retransmits:10"
      echo "198.19.2.$m,198.19.2.$n,[SUM]  0.00-30.00  sec  1400  GBytes  390  Gbits/sec  receiver  retransmits:10"; done
  echo "### iteration:1 phase:2"
  for n in $(seq 1 12); do m=$(( n + 12 ))
      echo "198.19.1.$n,198.19.2.$m,[SUM]  0.00-30.00  sec  950  GBytes  261.5  Gbits/sec  receiver  retransmits:140000"
      echo "198.19.1.$m,198.19.2.$n,[SUM]  0.00-30.00  sec  950  GBytes  261.83  Gbits/sec  receiver  retransmits:140000"; done
} > "$W/results"
FF_SPINES=4 FF_SPINE_LINKS=2 FF_SPINE_GBPS=800 UPLINK_GBPS=6400 RAIL_LINES="A=400 B=400" FF_OK_PCT=75 FF_SLOW_PCT=50 \
    uplink_summary "$W/ipmap" "$W/lldp" "$W/diag" "$W/results"
