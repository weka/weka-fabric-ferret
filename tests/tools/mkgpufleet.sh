#!/usr/bin/env bash
# Makes the GPU-fleet unit inputs for 60 (rail_speed, speed_mismatch, the IP-keyed planted bug), synthetic, in the
# shape of a 10-27 field run: 112 GPU hosts with bond0 (800G, two 400G members: ens1np0 without IPv4, ens769np0 absent)
# on two /24s, 7 of the bonds at 400G (a member down), 5 ens1np0 at "Unknown!" speed; one storage host with rails A and
# B at 400G. Usage: tests/tools/mkgpufleet.sh <dir>   writes iprail_gpu.txt, iprail_gpu_ip.txt, nicdiag_gpu.txt there.
# Addresses in 198.19.0.0/16 (never a site's); names gpuNNN / stor001; counters deterministic from the host number.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "mkgpufleet.sh: needs bash 4+ (this is bash $BASH_VERSION)" >&2; exit 2; }
D=${1:?usage: mkgpufleet.sh <dir>}; mkdir -p "$D"
: > "$D/iprail_gpu.txt"; : > "$D/iprail_gpu_ip.txt"; : > "$D/nicdiag_gpu.txt"
for i in $(seq 1 112); do
    h=$(printf 'gpu%03d' "$i")
    if (( i <= 56 )); then ip=198.19.178.$(( i + 10 )); else ip=198.19.179.$(( i - 56 + 10 )); fi
    bsp=800000Mb/s; (( i % 16 == 0 )) && bsp=400000Mb/s          # 7 bonds at 400G: i = 16, 32, ..., 112
    msp=400000Mb/s; (( i % 23 == 0 )) && msp='Unknown!'           # 5 members at Unknown!: i = 23, 46, 69, 92, 115>112 -> 4; plus 7
    (( i == 7 )) && msp='Unknown!'
    echo "$h bond0 C" >> "$D/iprail_gpu.txt"
    printf '%s\n' "none A" "none B" "$ip C" >> "$D/iprail_gpu_ip.txt"
    # every counter and reading from the host number (nothing copied from any run): rx, tx, errors, discards, pause,
    # two zero columns, four optic power readings in dBm, the module temperature
    c=$(( i * 1000003 ))
    echo "$h ens1np0 none $msp $(( c * 4 )) $(( c * 2 )) $c $(( c / 2 )) $(( c / 3 )) 0 0 1.$(( 10 + i % 90 )) 2.$(( i % 50 )) 1.$(( 20 + i % 70 )) 1.$(( 30 + i % 60 )) 4$(( i % 2 )).$(( i % 10 ))" >> "$D/nicdiag_gpu.txt"
    echo "$h bond0 $ip $bsp n/a n/a n/a n/a n/a n/a n/a n/a n/a n/a n/a n/a" >> "$D/nicdiag_gpu.txt"
done
printf '%s\n' "stor001 ens1np0 A" "stor001 ens769np0 B" >> "$D/iprail_gpu.txt"
printf '%s\n' "198.19.201.11 A" "198.19.205.11 B" "none C" >> "$D/iprail_gpu_ip.txt"
s=200000006   # the storage host: the same formula at host numbers 200 and 201
echo "stor001 ens1np0 198.19.201.11 400000Mb/s $(( s * 4 )) $(( s * 2 )) $s $(( s / 2 )) $(( s / 3 )) 0 0 1.20 2.00 1.40 1.50 40.0" >> "$D/nicdiag_gpu.txt"
s=$(( s + 1000003 ))
echo "stor001 ens769np0 198.19.205.11 400000Mb/s $(( s * 4 )) $(( s * 2 )) $s $(( s / 2 )) $(( s / 3 )) 0 0 1.21 2.01 1.41 1.51 41.1" >> "$D/nicdiag_gpu.txt"
echo "wrote $D: iprail_gpu.txt $(wc -l < "$D/iprail_gpu.txt") lines, iprail_gpu_ip.txt $(wc -l < "$D/iprail_gpu_ip.txt"), nicdiag_gpu.txt $(wc -l < "$D/nicdiag_gpu.txt") (bonds at 400G: $(grep -c 'bond0 .* 400000Mb/s' "$D/nicdiag_gpu.txt"), Unknown!: $(grep -c 'Unknown!' "$D/nicdiag_gpu.txt"))"
