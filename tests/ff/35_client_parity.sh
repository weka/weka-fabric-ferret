#!/opt/homebrew/bin/bash
# client parity (10-24: clients get every report backends get): host and priority counters around client
# phases, sysinfo and kernel log, client_rx.txt, Retr columns, client NICs in the drop and counter reads
# checks: 2
# secs: 46
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24

# the parity run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_SOFTNET_DROP and FAKE_BUF_DISCARD
# on c1

# FF_CLIENT_GBPS: the off-speed rules (c4 at 100G not listed, the 200G-only control) are units in 60 on
# ff_main.client_offspeed; this run keeps the wiring: the header line, an unknown speed in clients.txt, the listing
out=$(xrun cgu FAKE_CLIENT_NOSPEED=c2 FF_CLIENT_GBPS=100 FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "FF_CLIENT_GBPS=100, c2 speed unknown: c2 not listed off-speed (as backends), c1 and c3 are" "grep -q 'Client NICs not at 100G:' <<<\"\$out\" && bfile cgu clients.txt | awk '\$1 == \"c2\" {exit !(\$7 == \"unknown\")}' && ! grep -qE '^#   c2 ' <<<\"\$out\" && [ \$(grep -cE '^#   c[13] bond0 ' <<<\"\$out\") = 2 ]" "$(bfile cgu clients.txt | grep c2) | $(grep -A5 'Client NICs not at' <<<"$out")"
out=$(xrun w1 FF_RAILS=198.19.1.0/24 FF_CLIENT_RATIO=2 FF_CLIENT_NETS=198.19.10.0/24 FF_CLIENTS=198.18.1.1-3 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 240 $B $C 1); rc=$?
chk "log: one wave prints '1 wave each way' (item 4)" "grep -qE -- '---- Clients, iteration 1: 1 wave each way' <<<\"\$out\"" "$(grep -- '---- Clients' <<<"$out")"

# item 3 (10-24, Gbps below 1 Tbps, Tbps above) is a unit in 60 on ff_main.client_totals; golden-C prints the
# all-at-once lines end to end. The no-clients control (no client_rx.txt, no client count) is in 50, on golden-B.
finish
