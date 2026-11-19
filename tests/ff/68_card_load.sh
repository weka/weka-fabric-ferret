#!/opt/homebrew/bin/bash
# NIC card load (issue 9, 2026-11-19): each phase, every NIC card's ports (a card = the ports on one PCIe device) are
# read and judged against the slot: card_load.txt rows, near_slot / backpressure / pcie_degraded flags, the log's busiest
# card and flagged cards, the rate over the phase's run time; and the remote CARD_SCRIPT itself on a fake sysfs.
# Fake: rails A and B share card 0000:05:00, Gen4 x16; FAKE_CARD_HOT=h: 1 TB each way per port per read and rising
# discard and pause counters on h's 05:00 card; FAKE_CARD_SLOW=h: h's links at 8.0 GT/s x8.
# checks: 6
# secs: 45
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# hot: h21's card carries 1 TB each way per port per read; h22 is the control
out=$(xrun hot FAKE_CARD_HOT=h21 FAKE_CARD_SLOW=h22 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 timeout 120 $B $C 1); rc=$?
cl=$(bfile hot card_load.txt); pt=$(bfile hot phase_times.txt)
chk "card_load.txt: one row per card per phase (2 hosts x 1 card x phases 1 and 2 = 4), 15 columns, each row's ports 'enp5s0np0,enp196s0np0' (rails A and B on one card)" \
    "[ \$(grep -c . <<<\"\$cl\") = 4 ] && [ \$(awk 'NF != 15' <<<\"\$cl\" | grep -c .) = 0 ] && [ \$(awk '\$4 == \"0000:05:00\" && \$5 == \"enp5s0np0,enp196s0np0\"' <<<\"\$cl\" | grep -c .) = 4 ]" \
    "rc=$rc rows $(grep -c . <<<"$cl"): $(head -n 2 <<<"$cl" | tr '\n' '|')"
chk "flags: h21's card near_slot and backpressure (discards and pause rose) in each phase; h22's card pcie_degraded only (8.0x8 of 16.0x16, slot 63 Gb/s), its counters flat" \
    "[ \$(awk '\$3 == \"h21\" && \$15 ~ /near_slot/ && \$15 ~ /backpressure/ && \$10 > 0 && \$13 > 0' <<<\"\$cl\" | grep -c .) = 2 ] && [ \$(awk '\$3 == \"h22\" && \$15 == \"pcie_degraded\" && \$9 == \"8.0x8/16.0x16\" && int(\$8) == 63 && \$10 == 0' <<<\"\$cl\" | grep -c .) = 2 ]" \
    "$(awk '{print $3, $8, $9, $10, $13, $15}' <<<"$cl" | tr '\n' '|')"
chk "log: per phase a 'NIC cards in phase N (2; card_load.txt): busiest h21 0000:05:00' line and 'WARNING: NIC cards flagged in phase N (2):' naming h21's backpressure and h22's pcie_degraded" \
    "[ \$(grep -cE '^#   NIC cards in phase [12] \\(2; card_load.txt\\): busiest h21 0000:05:00 ' <<<\"\$out\") = 2 ] && [ \$(grep -cE '^#   WARNING: NIC cards flagged in phase [12] \\(2\\):' <<<\"\$out\") = 2 ] && grep -qE '^#   h21 0000:05:00 .*near_slot,backpressure|^#   h21 0000:05:00 .*backpressure' <<<\"\$out\" && grep -qE '^#   h22 0000:05:00 .*pcie_degraded' <<<\"\$out\"" \
    "$(grep -E 'NIC cards|0000:05:00' <<<"$out" | head -n 6 | cut -c1-160 | tr '\n' '|')"
# rate: each read adds 1e12 bytes per port, 2 ports: 16000 Gb each way per phase. A TCP run takes 2 s
# (FAKE_IPERF_SECS) and each card read 3 s (FAKE_CARD_DELAY), so the time between the reads is 3 s or more longer than
# the phase's run time (phase_times.txt); the rate must use the run time (the seconds it used: 16000 / tx)
out=$(xrun rt FAKE_CARD_HOT=h21 FAKE_IPERF_SECS=2 FAKE_CARD_DELAY=3 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 FF_CROSS_RAIL=0 timeout 120 $B $C 1)
want=$(bfile rt phase_times.txt | awk '$2 == 1 && $3 != "-" {split($3, a, /[T:Z]/); split($4, b, /[T:Z]/); print (b[2] * 3600 + b[3] * 60 + b[4]) - (a[2] * 3600 + a[3] * 60 + a[4])}')
used=$(bfile rt card_load.txt | awk '$2 == 1 && $3 == "h21" && $6 > 0 {printf "%.2f", 16000 / $6}')
chk "rate over the phase's run time: h21's phase 1 tx gives the seconds it used (16000 Gb / tx = $used) within 1 s of the phase's $want s (2 s or more), not the 5 s or more between the reads" \
    "[[ \"$want\" =~ ^[0-9]+\$ && \"$used\" =~ ^[0-9.]+\$ ]] && [ $want -ge 2 ] && awk -v u=$used -v w=$want 'BEGIN {d = u - w; exit !(d <= 1 && d >= -1)}'" \
    "phase 1 secs '$want', used '$used'; h21 row: $(bfile rt card_load.txt | awk '$2 == 1 && $3 == "h21"')"
# unit: CARD_SCRIPT on a fake sysfs (FF_SYSFS) with a stub ethtool: a bond expands to its members, the bus is the
# device link's name, link speed and width come from "16.0 GT/s PCIe" / "16", a counter ethtool lacks reads na,
# a port with no sysfs entry prints nothing
U=$W/sys; mkdir -p $U/devices/0000:9f:00.0 $U/devices/0000:9f:00.1 $W/bin
for f in 0 1; do d=$U/devices/0000:9f:00.$f; echo '16.0 GT/s PCIe' > $d/current_link_speed; echo 8 > $d/current_link_width; echo '16.0 GT/s PCIe' > $d/max_link_speed; echo 16 > $d/max_link_width; done
for p in p0 p1; do mkdir -p $U/class/net/$p/statistics; done
ln -s ../../../devices/0000:9f:00.0 $U/class/net/p0/device; ln -s ../../../devices/0000:9f:00.1 $U/class/net/p1/device
echo 111 > $U/class/net/p0/statistics/rx_bytes; echo 222 > $U/class/net/p0/statistics/tx_bytes
echo 333 > $U/class/net/p1/statistics/rx_bytes; echo 444 > $U/class/net/p1/statistics/tx_bytes
mkdir -p $U/class/net/bond0/bonding; echo 'p0 p1' > $U/class/net/bond0/bonding/slaves
printf '%s\n' '#!/usr/bin/env bash' 'echo "NIC statistics:"; echo "     rx_discards_phy: 7"; echo "     rx_out_of_buffer: 9"; echo "     tx_pause_ctrl_phy: 5"' > $W/bin/ethtool; chmod +x $W/bin/ethtool
cs=$(sed -n "/^read -r -d '' CARD_SCRIPT <<'EOF'\$/,/^EOF\$/p" $C | sed '1d;$d')
uo=$(FF_SYSFS=$U PATH=$W/bin:$PATH bash -c "$cs" _ bond0 nosuch 2>&1); h=$(hostname -s)
chk "CARD_SCRIPT unit: bond0 reads its 2 members p0 and p1 on 0000:9f:00.0/.1, link '16.0 8 16.0 16', bytes from statistics, discards 7, out-of-buffer 9, buffer threshold na, pause 5, the PCIe counters na; 'nosuch' prints nothing" \
    "[ \"\$(tr '\n' '|' <<<\"\$uo\")\" = '@@CARD $h p0 0000:9f:00.0 16.0 8 16.0 16 111 222 7 9 na 5 na na na na|@@CARD $h p1 0000:9f:00.1 16.0 8 16.0 16 333 444 7 9 na 5 na na na na|' ]" \
    "$(tr '\n' '|' <<<"$uo" | cut -c1-300)"
# the awk on that read (the bytes of the first read zeroed): the card's ports joined, its x8 link flagged pcie_degraded
ca=$(awk -v it=iter1 -v ph=1 -v s=1 -v near=80 -f $S/../src/awk/ff_card_load.awk <(sed 's/ 111 222 / 0 0 /; s/ 333 444 / 0 0 /' <<<"$uo") <(echo "$uo") 2>&1)
chk "CARD_SCRIPT unit: ff_card_load makes one card row (0000:9f:00, ports p0,p1) and flags its 16.0x8 link pcie_degraded" \
    "[ \$(grep -c . <<<\"\$ca\") = 1 ] && grep -qE '^iter1 1 $h 0000:9f:00 p0,p1 .* 16\\.0x8/16\\.0x16 .*pcie_degraded' <<<\"\$ca\"" "$ca"
finish
