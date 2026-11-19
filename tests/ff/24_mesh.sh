#!/opt/homebrew/bin/bash
# FF_MESH ping mesh (clean, dead IP, ICMP block, off by default)
# checks: 12
# secs: 31
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FF_MESH=1 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull); chk "mesh clean: 64 pairs pinged, 0 unreachable, 0 lossy" "grep -q 'Mesh: 64 pairs pinged (5 pings each), 0 unreachable, 0 lossy' <<<\"\$out\""
# the dead-IP run, its card and "mesh on by default" moved to 50_golden_B.sh (10-26): golden-B leaves FF_MESH unset
# and carries FAKE_MESHFAIL=198.19.2.3
out=$(FF_MESH=0 FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 frunfull); chk "FF_MESH=0: no mesh" "! grep -q 'Mesh' <<<\"\$out\""
out=$(FF_MESH=1 FAKE_ICMP_BLOCK=198.19.2.3 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull)
chk "mesh ICMP block: source named, no innocent IPs" "grep -q 'h3 mesh_no_replies rail IP 198.19.2.3' <<<\"\$out\" && grep -q 'did not answer 7 of 7' <<<\"\$out\" && [ \$(grep -c 'mesh_unreachable' <<<\"\$out\") = 1 ]"

# --- issue 6 (2026-11-19): on rails that are separate fabrics every cross-rail ping failed and was reported as an
# unreachable rail IP; and one lost ping called a pair unreachable. Now a pair whose route leaves another NIC than the
# source's own is not pinged (mesh_unrouted.txt), FF_CROSS_RAIL=0 pings the own rail only, and each pair gets 5 pings:
# all lost = unreachable, some lost = lossy (mesh_lossy.txt).
# (u) the remote script itself, on stub ip and ping (iputils and busybox summaries; a route out eth9; no route at all)
MS=$(sed -n "/^read -r -d '' MESH_SCRIPT <<'EOF'\$/,/^EOF\$/p" $C | sed '1d;$d')
mkdir -p $W/stub
printf '%s\n' '#!/usr/bin/env bash' 'd=$4; s=$6' 'case $d in 198.19.250.*) echo "$d from $s dev eth9 uid 0";; 198.18.250.6) echo "RTNETLINK answers: Network is unreachable"; exit 2;; *) echo "$d from $s dev eth0 uid 0";; esac' > $W/stub/ip
printf '%s\n' '#!/usr/bin/env bash' 'c=$2; d=${@: -1}' 'case $d in' '198.18.250.3) echo "$c packets transmitted, 3 received, 40% packet loss";;' '198.18.250.4) echo "$c packets transmitted, 0 received, 100% packet loss"; exit 1;;' '198.18.250.5) echo "$c packets transmitted, $c packets received, 0% packet loss";;' '198.18.250.7) echo "$c packets transmitted, 4 packets received, 20% packet loss";;' '*) echo "$c packets transmitted, $c received, 0% packet loss";; esac' > $W/stub/ping
chmod +x $W/stub/ip $W/stub/ping
mrun() { PATH=$W/stub:$PATH bash -s -- 198.18.250.1@eth0 none 5 198.18.250.2 198.18.250.3 198.18.250.4 198.18.250.5 198.18.250.6 198.18.250.7 198.19.250.1 <<<"$1" 2>&1 | sort; }
want=$(printf '%s\n' 'MESHLOSS 198.18.250.1 198.18.250.3 2 5' 'MESHLOSS 198.18.250.1 198.18.250.4 5 5' 'MESHLOSS 198.18.250.1 198.18.250.7 1 5' 'MESHROUTE 198.18.250.1 198.18.250.6 ' 'MESHROUTE 198.18.250.1 198.19.250.1 eth9')
got=$(mrun "$MS")
chk "mesh script (stub ip/ping): lost counts from iputils and busybox summaries, no line for a clean pair, MESHROUTE for a route out eth9 and for no route" "[ \"\$got\" = \"\$want\" ]" "got=[$(tr '\n' '|' <<<"$got")]"
got2=$(mrun "$(grep -v 'MESHROUTE' <<<"$MS")")
chk "planted: the route test taken out of the script: the eth9 and no-route pairs are pinged, the check above would fail" "[ \"\$got2\" != \"\$want\" ] && ! grep -q MESHROUTE <<<\"\$got2\"" "got2=[$(tr '\n' '|' <<<"$got2")]"

# (r) rails that are separate fabrics: 3 hosts x 2 rails, each rail IP has 2 same-rail and 2 cross-rail peers
M3="FF_HOSTS=198.18.0.21-23 FF_ITER=1 FF_UDP=0"
out=$(xrun xr env $M3 FAKE_NOXROUTE=1 timeout 120 $B $C 1); rc=$?
chk "FAKE_NOXROUTE: 12 pairs pinged, 0 unreachable; 12 not pinged, all cross-rail; no mesh finding; mesh_unrouted.txt 12 cross rows; metadata mesh_unrouted=12" \
    "grep -q 'Mesh: 12 pairs pinged (5 pings each), 0 unreachable, 0 lossy\$' <<<\"\$out\" && grep -q 'Mesh: 12 pairs not pinged, their route leaves another NIC than the source.s own (mesh_unrouted.txt): 12 cross-rail, 0 same-rail\$' <<<\"\$out\" && ! grep -q 'mesh_[a-z_]* rail IP' <<<\"\$out\" && [ \$(bfile xr mesh_unrouted.txt | awk '\$6 == \"cross\"' | wc -l) = 12 ] && bfile xr metadata.txt | grep -qx 'mesh_unrouted=12'" \
    "rc=$rc $(grep -E 'Mesh|mesh_' <<<"$out" | tr '\n' '|') unrouted=$(bfile xr mesh_unrouted.txt | wc -l)"
out=$(xrun xd env $M3 FAKE_NOXROUTE=1 FAKE_MESHFAIL=198.19.2.22 timeout 120 $B $C 1); rc=$?
chk "FAKE_NOXROUTE + a dead rail B IP: it did not answer 2 of 2 (its same-rail peers; the cross-rail pairs not pinged never count)" \
    "grep -q 'mesh_unreachable rail IP 198.19.2.22 did not answer 2 of 2 pinging rail IPs' <<<\"\$out\" && grep -q 'Mesh: 12 pairs pinged (5 pings each), 2 unreachable, 0 lossy' <<<\"\$out\"" "rc=$rc $(grep -E 'Mesh|mesh_' <<<"$out" | tr '\n' '|')"
# (x) FF_CROSS_RAIL=0: the own rail only, nothing cross-rail planned
out=$(xrun xc env $M3 FF_CROSS_RAIL=0 FAKE_MESHLOG=1 timeout 120 $B $C 1); rc=$?
np=$(wc -l < $FAKE_STATE/mesh_pairs.log 2>&1 | tr -d " "); nx=$(awk '{split($1, a, "."); split($2, b, "."); if (a[3] != b[3]) n++} END {print n + 0}' $FAKE_STATE/mesh_pairs.log 2>&1)
chk "FF_CROSS_RAIL=0: 12 pairs pinged, all same-rail (the fake's log: 12, 0 cross); the log says own rail; no 'not pinged' line" \
    "[ \"$np\" = 12 ] && [ \"$nx\" = 0 ] && grep -q 'on its own rail (FF_CROSS_RAIL=0), 5 pings each' <<<\"\$out\" && grep -q 'Mesh: 12 pairs pinged (5 pings each), 0 unreachable, 0 lossy' <<<\"\$out\" && ! grep -q 'not pinged' <<<\"\$out\"" "rc=$rc pairs=$np cross=$nx $(grep 'Mesh' <<<"$out" | tr '\n' '|')"
rm -f "${FAKE_STATE:?}/mesh_pairs.log"
# (l) a rail IP that loses some pings: lossy, not unreachable
out=$(xrun xl env $M3 FAKE_MESHLOSSY=198.19.1.22 timeout 120 $B $C 1); rc=$?
chk "FAKE_MESHLOSSY: 24 pairs, 0 unreachable, 4 lossy; finding: lost pings from 4 of 4 (8 of 20 lost); no mesh_unreachable; mesh_lossy.txt 4 rows; metadata mesh_lossy=4 mesh_count=5" \
    "grep -q 'Mesh: 24 pairs pinged (5 pings each), 0 unreachable, 4 lossy' <<<\"\$out\" && grep -q 'mesh_lossy rail IP 198.19.1.22 lost pings from 4 of 4 pinging rail IPs (8 of 20 pings lost)' <<<\"\$out\" && ! grep -q 'mesh_unreachable' <<<\"\$out\" && [ \$(bfile xl mesh_lossy.txt | wc -l) = 4 ] && bfile xl metadata.txt | grep -qx 'mesh_lossy=4' && bfile xl metadata.txt | grep -qx 'mesh_count=5'" \
    "rc=$rc $(grep -E 'Mesh|mesh_' <<<"$out" | tr '\n' '|')"
render xl; prc=$?
chk "dashboard: the lossy finding has its label; the Preflight header says pairs unreachable and lossy" "grep -q 'Rail IP loses some pings in the mesh' $W/xl.html && grep -q 'mesh: 0 of 24 pairs unreachable, 4 lossy' $W/xl.html" "rc=$prc $(grep -oE 'mesh: [^<|]*' $W/xl.html | head -n 1)"
# (n) a source that routes its same-rail peers out another NIC: a routing fault on that host, named
out=$(xrun xn env $M3 FAKE_MESHNOROUTE=198.19.1.21 timeout 120 $B $C 1); rc=$?
chk "FAKE_MESHNOROUTE: 4 pairs not pinged (2 cross-rail, 2 same-rail); finding mesh_no_route for 198.19.1.21 (2 same-rail peers out eno1)" \
    "grep -q '4 pairs not pinged.*: 2 cross-rail, 2 same-rail' <<<\"\$out\" && grep -q 'mesh_no_route rail IP 198.19.1.21 routes 2 same-rail peers out eno1, not its own NIC' <<<\"\$out\"" "rc=$rc $(grep -E 'Mesh|mesh_' <<<"$out" | tr '\n' '|')"
# (p) planted bugs, one line each: FF_CROSS_RAIL ignored; lossy taken as unreachable; pairs not pinged counted as pinged
perl -pe 's/if \[\[ \$FF_CROSS_RAIL == 0 \]\]; then$/if false; then/' $C > $W/x_cr.sh
out=$(xrun pc env $M3 FF_CROSS_RAIL=0 timeout 120 $B $W/x_cr.sh 1)
perl -pe 's/\$1 == "MESHLOSS" && \$4 >= \$5 \{/\$1 == "MESHLOSS" \&\& \$4 >= 1 {/' $C > $W/x_lo.sh
out2=$(xrun pl env $M3 FAKE_MESHLOSSY=198.19.1.22 timeout 120 $B $W/x_lo.sh 1)
perl -pe 's/^(\s*)awk .FILENAME == ARGV\[1\] \{x\[\$1 " " \$2\] = 1; next\}.*$/$1cp "\$WORK\/mesh_plan_\$w" "\$WORK\/mesh_probed_\$w"/' $C > $W/x_pr.sh
out3=$(xrun pp env $M3 FAKE_NOXROUTE=1 FAKE_MESHFAIL=198.19.2.22 timeout 120 $B $W/x_pr.sh 1)
chk "planted (1 line each): FF_CROSS_RAIL ignored -> 24 pairs; lossy as unreachable -> 4 unreachable; not-pinged pairs counted -> 'did not answer 2 of 4'" \
    "[ \$(diff $C $W/x_cr.sh | grep -c '^>') = 1 ] && grep -q 'Mesh: 24 pairs pinged' <<<\"\$out\" && [ \$(diff $C $W/x_lo.sh | grep -c '^>') = 1 ] && grep -q '4 unreachable, 0 lossy' <<<\"\$out2\" && [ \$(diff $C $W/x_pr.sh | grep -c '^>') = 1 ] && grep -q 'did not answer 2 of 4' <<<\"\$out3\"" \
    "cr=$(grep 'pairs pinged' <<<"$out") lo=$(grep 'pairs pinged' <<<"$out2") pr=$(grep 'did not answer' <<<"$out3")"
finish
