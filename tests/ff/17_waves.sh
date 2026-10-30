#!/opt/homebrew/bin/bash
# FF_CROSS_MAX: balanced cross-rail waves
# checks: 9
# secs: 34
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(xrun w8 FF_HOSTS=198.18.0.21-32 FF_ITER=1 FF_CROSS_MAX=8 timeout 120 $B $C 1)
chk "FF_CROSS_MAX=8, 12 cross flows: 2 waves, each 3 A->B / 3 B->A" "grep -q '12 cross-rail flows in 2 waves of at most 8' <<<\"\$out\" && [ \"\$(wavebal w8 8)\" = '2 0' ]" "$(wavebal w8 8)"
chk "waves: total reported per wave, not per iteration" "grep -q -E '^  Cross-rail total per wave \(FF_CROSS_MAX=8 flows at once\): largest [0-9.]+ (Tbps|Gbps), .* over 2 waves\), 12 flows \(A->B 6, B->A 6\)' <<<\"\$out\"" "$(grep 'Cross-rail total' <<<"$out")"
chk "waves: uplink busiest names the wave" "grep -q -E 'Uplinks leaf1.example phase 2: .*\[iteration 1 wave [12]/2, busiest of 2\]' <<<\"\$out\"" "$(grep 'Uplinks leaf1' <<<"$out")"
t=$(ls $W/w8/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/w8.html > $W/p.out 2>&1
chk "parser: wave archive renders, metadata cross_max=8" "[ -s $W/w8.html ] && tar -xzOf $t --include='*metadata.txt' | grep -q '^cross_max=8\$'" "$(tail -n1 $W/p.out)"
out=$(xrun w1 FAKE_XSPEED=240 FF_HOSTS=198.18.0.21-24 FF_ITER=1 FF_CROSS_MAX=1 timeout 120 $B $C 1)
chk "FF_CROSS_MAX=1: 4 flows in 4 waves, one at a time" "grep -q '4 cross-rail flows in 4 waves of at most 1 (FF_CROSS_MAX), one flow at a time' <<<\"\$out\" && [ \"\$(wavebal w1 1 | cut -d' ' -f1)\" = 4 ]" "$(wavebal w1 1)"
t=$(ls $W/w1/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/w1.html > $W/p.out 2>&1
chk "dashboard: slow cross in waves, total per wave" "grep -q 'Cross-rail total per wave (1 flows at once): largest 240.0 Gbps' $W/w1.html" "$(grep -o 'Cross-rail total[^<]*' $W/w1.html | head -n1)"
# "FF_CROSS_MAX unset: no waves, one phase 2 marker" is checked on golden-B (50), which leaves it unset (10-26: was
# run w0 here); the w8 check above is its positive control ('waves of at most' printed when set)
for v in 0 x -2; do out=$(FF_CROSS_MAX=$v FF_HOSTS=198.18.0.21 $B $C 1 2>&1); chk "FF_CROSS_MAX=$v rejected" "grep -q 'FF_CROSS_MAX must be a positive integer' <<<\"\$out\""; done
finish
