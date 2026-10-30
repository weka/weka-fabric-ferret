#!/opt/homebrew/bin/bash
# sender TX bucket (10-25: "build the sender TX bucket and rerun"): datagrams a sender NIC never put on
# the wire = sent - kernel tx packets (stack) + kernel tx - port tx packets (NIC), per phase, shared over its runs
# checks: 5
# secs: 83
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
CL="FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1"
# rows of udp_expected.txt: $2 phase, $4 src, $5 dst, $9 lost, $12 tx
txsum() { awk -v p="$2" -v s="$3" '$2 == p && $4 ~ s {t += $12} END {print t + 0}' <<<"$1"; }

# clean: counters read, no shortfall anywhere
out=$(xrun tc FAKE_UDP_LOST=600000 $CL timeout 300 $B $C 1); rc=$?
tx=$(bfile tc udp_tx.txt); ue=$(bfile tc udp_expected.txt)
chk "udp_tx.txt: a row per data NIC per UDP phase (U1 UC1 UC2), kernel and wire deltas numeric" "( for p in U1 UC1 UC2; do [ \$(awk -v p=\$p '\$2 == p && \$5 ~ /^[0-9]+\$/ && \$6 ~ /^[0-9]+\$/' <<<\"\$tx\" | wc -l) -ge 9 ] || exit 1; done )" "$(awk '{print $2}' <<<"$tx" | sort | uniq -c | tr '\n' ' ')"
chk "clean: tx 0 on every run; log 'sender TX 0' for UC1" "! awk '\$12 != 0' <<<\"\$ue\" | grep -q . && grep -qE '^#   UC1 loss: .*: sender TX 0, receiver socket' <<<\"\$out\"" "$(grep 'UC1 loss' <<<"$out")"

# the silent-NIC-drop run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_TX_DROP=c1

# one run for two senders that never share a phase's sending side (10-26: was runs ts and tb): c1's stack drops
# show in UC1, where only clients send; h21's NIC drops in U1, where only backends send
# drops before the driver on c1 (kernel count 200k per phase, under the 1M per run sent): capped at each run's loss
out=$(xrun ts FAKE_TX_STACK=c1 FAKE_TX_DROP=h21 FAKE_UDP_LOST=600000 $CL timeout 300 $B $C 1); rc=$?
ue=$(bfile ts udp_expected.txt)
chk "c1 stack drops: each of c1's UC1 runs charged up to its loss (600000)" "awk '\$2 == \"UC1\" && \$4 == \"198.19.10.1\" {n++; if (\$12 != \$9) b++} END {exit !(n > 0 && !b)}' <<<\"\$ue\"" "$(awk '$2 == "UC1" && $4 == "198.19.10.1"' <<<"$ue")"

ue_ts=$ue
# a driver with no port counter: the NIC stage can't be measured, so it isn't charged (no guess)
out=$(xrun tn FAKE_NO_PHY=1 FAKE_TX_DROP=c1 FAKE_UDP_LOST=600000 $CL timeout 300 $B $C 1); rc=$?
chk "no port counter: wire '-' in udp_tx.txt and c1 charged nothing" "awk '\$3 ~ /^c1_/ {n++; if (\$6 != \"-\") b++} END {exit !(n > 0 && !b)}' <<<\"\$(bfile tn udp_tx.txt)\" && [ \$(txsum \"\$(bfile tn udp_expected.txt)\" UC1 '^198\\\\.19\\\\.10\\\\.1\$') = 0 ]" "$(bfile tn udp_tx.txt | head -n 3)"

# backends too: h21's NIC drops in U1 (the ts run above)
ue=$ue_ts
chk "h21 NIC drops: its U1 runs carry 500000 per sending NIC" "[ \$(txsum \"\$ue\" U1 '^198\\\\.19\\\\.[12]\\\\.21\$') -ge 500000 ] && [ \$(txsum \"\$ue\" U1 '^198\\\\.19\\\\.[12]\\\\.22\$') = 0 ]" "$(awk '$2 == "U1"' <<<"$ue")"
finish
