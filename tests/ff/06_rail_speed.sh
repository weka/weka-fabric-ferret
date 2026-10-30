#!/opt/homebrew/bin/bash
# a whole rail slow, rails mixed by design (speed and MTU), a speed tie under every awk
# checks: 12
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# a whole rail slow (every B NIC at 200G of 400G): judged at the faster rail's speed, so it shows as slow
fresh; mkdir -p $W/slowb; out=$(cd $W/slowb && PATH=$S/fake:$PATH FAKE_SPEED_B=200000 FF_HOSTS=198.18.0.1-4 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=1 timeout 120 $B $C 1 2>&1)
chk "whole rail slow: judged at 400G, warned" "grep -q 'Link speed for cut-offs: 400G (OK >= 300G' <<<\"\$out\" && grep -q 'WARNING: rails run at different speeds (rail A 400G on 4 of 4 NICs, rail B 200G on 3 of 3 NICs): both judged at 400G. If that is by design, set FF_LINE_GBPS=400,200' <<<\"\$out\"" "$(grep 'different speeds' <<<"$out")"
chk "no flap: no flap warning" "! grep -q 'rail links went down' <<<\"\$out\""
chk "whole rail slow: every usable B NIC listed off-speed (3: h4's B is link DOWN, unusable, under Rails not usable instead)" "grep -q 'NICs not at 400G:' <<<\"\$out\" && [ \$(grep -c 'enp196s0np0 200000Mb/s (rail B)' <<<\"\$out\") = 3 ] && grep -q '^#   h4 .* link_DOWN_on_enp196s0np0' <<<\"\$out\"" "$(grep -E 'enp196s0np0 200000|^#   h4 ' <<<"$out")"
# rails that differ by design, declared: A 400G at MTU 4220 (an RDMA rail), B 50G at 9000; h3 B at 200G is the odd one
fresh; mkdir -p $W/mix; out=$(cd $W/mix && PATH=$S/fake:$PATH FF_LINE_GBPS=400,50 FAKE_SPEED_B=50000 FAKE_MTU_A=4220 FF_UDP=1 FF_UDP_DURATION=1 FF_HOSTS=198.18.0.1-4 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=2 timeout 120 $B $C 1 2>&1)
chk "declared mixed rails: per-rail cut-offs, no warning" "grep -q 'Link speed for cut-offs: rail A 400G (OK >= 300G, SLOW >= 200G), rail B 50G (OK >= 37.5G, SLOW >= 25G)' <<<\"\$out\" && ! grep -q 'rails run at different speeds' <<<\"\$out\""
chk "declared mixed rails: off-speed judged per rail" "grep -q 'h3 enp196s0np0 200000Mb/s (rail B)' <<<\"\$out\" && [ \$(grep -c '(rail [AB])\$' <<<\"\$out\") = 1 ]"
chk "mixed MTU 4220/9000: no MTU skips" "! grep -q 'no-fragment ping failed' <<<\"\$out\""
chk "mixed MTU: UDP -l 4192 via rail A, 8972 B-B" "[ \"\$(grep '^UDP' $FAKE_STATE/iperf_args.log | awk '{print (\$2 ~ /^198.19.1/ || \$3 ~ /^198.19.1/) ? \"A\" \$7 : \"B\" \$7}' | sort -u | tr '\\n' ' ')\" = 'A4192 B8972 ' ]"
t=$(ls $W/mix/fabric_ferret_*.tgz | head -n1); python3 $P $t $W/mix.html > $W/p.out 2>&1
chk "declared mixed rails: dashboard per-rail note + inventory" "grep -q 'rails differ: A 400G, B 50G' $W/mix.html && grep -q 'At rail speed: <strong class=\"text-success\">7</strong>' $W/mix.html"
# "uniform rails: no per-rail note" moved to 04_e2e_awks.sh (it reads that group's fake.html)
# v3: the value count must match the rail count, so it is judged once the rails are known
out=$(xrun lg3 FF_LINE_GBPS=100,50,25 FF_HOSTS=198.18.0.21 timeout 60 $B $C 1); rc=$?; chk "FF_LINE_GBPS=100,50,25 rejected" "[ $rc = 2 ] && grep '^ERROR' <<<\"\$out\" | grep -q 'FF_LINE_GBPS'" "rc=$rc $(grep '^ERROR' <<<"$out")"
# the speed tie under every awk (h1 B 50G, h3 B 200G takes 200) is a unit in 60 on ff_main.rail_speed (10-26); the
# whole-rail-slow run above prints the line it feeds ("rail A 400G on 4 of 4 NICs, rail B 200G on 3 of 3 NICs")
# a bond at half speed (10-27 fleet: 7 bond0 at 400G of 2x400G, 5 with a member at Unknown! speed): the
# off-speed line names the slave without link, from the kernel's bonding report (bonds.txt in the bundle)
fresh; mkdir -p $W/bd; out=$(cd $W/bd && PATH=$S/fake:$PATH FAKE_BOND_DOWN=h2 FAKE_SPEED_B=200000 FF_LINE_GBPS=400,400 FF_HOSTS=198.18.0.1-4 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=1 timeout 120 $B $C 1 2>&1)
chk "bond down: h2's rail A line says 1 of 2 slaves up and names the slave down" "grep -qx '#   h2 enp5s0np0 200000Mb/s (rail A): 1 of 2 slaves up, enp5s0np1 down (MII)' <<<\"\$out\" && grep -q 'driver lines, 1 bonds' <<<\"\$out\"" "$(grep -E 'rail A\)|driver lines' <<<"$out" | tr '\n' '|')"
chk "control: the 3 rail B NICs at 200G (no bond) keep lines ending in '(rail B)', no slaves suffix" "[ \$(grep -c '(rail B)\$' <<<\"\$out\") = 3 ] && ! grep -q '(rail B): ' <<<\"\$out\"" "$(grep '(rail B)' <<<"$out" | tr '\n' '|')"
chk "bond down: bonds.txt in the bundle: 'h2 enp5s0np0 1 2 enp5s0np1'; the raw text carries the bonding section" "[ \"\$(tar -xzOf \$(ls $W/bd/fabric_ferret_*.tgz | head -n 1) --include='*/bonds.txt')\" = 'h2 enp5s0np0 1 2 enp5s0np1' ] && tar -xzOf \$(ls $W/bd/fabric_ferret_*.tgz | head -n 1) --include='*/raw_per_host/h2.txt' | grep -qx '=== bonding enp5s0np0 ==='" "$(tar -xzOf $(ls $W/bd/fabric_ferret_*.tgz | head -n 1) --include='*/bonds.txt' | tr '\n' '|')"
finish
