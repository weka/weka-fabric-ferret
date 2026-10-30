#!/opt/homebrew/bin/bash
# RDMA counters counted when none rose; FF_BUSY_CHECK blocking
# checks: 3
# secs: 13
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

fresh; out=$(cd $W && PATH=$S/fake:$PATH FF_HOSTS=198.18.0.2,198.18.0.3 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=1 timeout 60 $B $C 1 2>&1)
chk "RDMA counters counted when none rose" "grep -q 'counter rose in iteration 1 (28 counters read, 8 of them RDMA)' <<<\"\$out\"" "$(grep 'counter rose' <<<"$out")"
out=$(PATH=$S/fake:$PATH FAKE_BUSY=h3 FF_HOSTS=198.18.0.1-5 FF_RAILS='198.19.1.0/24;198.19.2.0/24' timeout 60 $B $C 1 2>&1)
chk "busy host blocks" "grep -q 'FF_BUSY_CHECK: 1 hosts in use' <<<\"\$out\" && ! grep -q 'first 10' <<<\"\$out\"" "$(grep FF_BUSY <<<"$out" | head -n 1)"
out=$(PATH=$S/fake:$PATH FAKE_BUSY=h21,h22,h23,h24,h25,h26,h27,h28,h29,h30,h31,h32 FF_HOSTS=198.18.0.21-32 FF_RAILS='198.19.1.0/24;198.19.2.0/24' timeout 60 $B $C 1 2>&1)
chk "busy list over 10 says first 10 of N" "grep -qF 'FF_BUSY_CHECK: 12 hosts in use or check failed (first 10 of 12): h21(in use) h22(in use)' <<<\"\$out\" && grep -qF 'h30(in use). Line-rate' <<<\"\$out\"" "$(grep FF_BUSY <<<"$out" | head -n 1)"
finish
