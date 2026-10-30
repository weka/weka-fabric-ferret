#!/opt/homebrew/bin/bash
# FF_MESH ping mesh (clean, dead IP, ICMP block, off by default)
# checks: 3
# secs: 31
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FF_MESH=1 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull); chk "mesh clean: 64 pings, 0 failed" "grep -q 'Mesh: 64 pings, 0 failed' <<<\"\$out\""
# the dead-IP run, its card and "mesh on by default" moved to 50_golden_B.sh (10-26): golden-B leaves FF_MESH unset
# and carries FAKE_MESHFAIL=198.19.2.3
out=$(FF_MESH=0 FF_HOSTS=198.18.0.1,198.18.0.2 FF_ITER=1 frunfull); chk "FF_MESH=0: no mesh" "! grep -q 'Mesh' <<<\"\$out\""
out=$(FF_MESH=1 FAKE_ICMP_BLOCK=198.19.2.3 FF_HOSTS=198.18.0.1-5 FF_ITER=1 frunfull)
chk "mesh ICMP block: source named, no innocent IPs" "grep -q 'h3 mesh_no_replies rail IP 198.19.2.3' <<<\"\$out\" && grep -q 'did not answer 7 of 7' <<<\"\$out\" && [ \$(grep -c 'mesh_unreachable' <<<\"\$out\") = 1 ]"
finish
