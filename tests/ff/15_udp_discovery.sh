#!/opt/homebrew/bin/bash
# UDP host counters above the loss; a stop at discovery lists the left-out hosts
# checks: 2
# secs: 9
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# host counters larger than the loss (they count the whole phase): said, not hidden in a floored unaccounted. The
# bucket arithmetic is also a unit in 60 (ff_udp_attr "over"); this run keeps the log line's wiring, which no golden
# run prints
fresh; out=$(cd $W && PATH=$S/fake:$PATH FAKE_UDP_LOST=1 FF_UDP=1 FF_UDP_DURATION=1 FF_HOSTS=198.18.0.1,198.18.0.2 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=1 timeout 120 $B $C 1 2>&1)
chk "UDP: host counters above the loss are reported" "grep -q 'Lost datagrams 4 of 4000000: .*unaccounted [0-9]*; host counters exceed the loss by [0-9]' <<<\"\$out\"" "$(grep 'Lost datagrams' <<<"$out")"
# stop at discovery: the left-out hosts are printed, not a pointer into the work dir that the stop removes
fresh; out=$(cd $W && PATH=$S/fake:$PATH FF_HOSTS=198.18.0.1,198.18.0.2 FF_RAILS='198.19.8.0/24;198.19.9.0/24' timeout 60 $B $C 1 2>&1)
chk "STOPPED at discovery lists the left-out hosts inline" "grep -q 'Left out (first 20):' <<<\"\$out\" && grep -q -E '^#   198.18.0.1 h1 not on data rails' <<<\"\$out\" && ! grep -q 'excluded.txt' <<<\"\$out\"" "$(grep -E 'ERROR|Left out' <<<"$out")"
finish
