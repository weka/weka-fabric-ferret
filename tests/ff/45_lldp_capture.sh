#!/opt/homebrew/bin/bash
# LLDP without lldpcli (FF_LLDP=1, opt-in, 11-02): DIAG_SCRIPT run here on port p0 with fake host tools:
# one tcpdump frame fills the @@LLDP row, the LLDP group MAC is added and removed around
# it, never promiscuous; a NIC whose firmware LLDP agent eats the frames is not captured
# tier: fast
# checks: 20
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# diag <name> "<extra tools>"|-<tool> [VAR=value ...]: DIAG_SCRIPT on p0, PATH = the fakes + /usr/bin:/bin (no lldpcli, tcpdump,
# timeout, ip there on macOS); output $W/<name>.out, argv log $W/<name>.argv. FAKE_AWK picks the awk (bsd)
diag() { local n=$1 t tools="ip ethtool tcpdump timeout hostname $2"
         mkdir -p $W/bin.$n; for t in $tools; do [[ $t == -* || -$t == "$2" ]] || ln -s $S/fake/lldp/tool $W/bin.$n/$t; done
         shift 2; : > $W/$n.argv
         timeout 30 env FAKE_LLDP_LOG=$W/$n.argv "$@" $B -c 'source "$1"; PATH=$2; shift 2; eval "$DIAG_SCRIPT"' diag $C "$W/bin.$n:$S/awkbin/${FAKE_AWK:-bsd}:/usr/bin:/bin" p0 > $W/$n.out 2>&1; }
row() { grep "^@@LLDP hx ${2:-p0} " $W/$1.out | cut -d' ' -f5-; }   # row <name> [port]: chassis portid portdesc sysdesc
why() { grep '^@@LLDPWHY ' $W/$1.out | cut -d' ' -f2- | paste -sd '|' -; }   # host port reason, rows joined by |
calls() { grep -c "^$2" $W/$1.argv; }   # calls <name> <tool argv prefix>
seq_of() { awk '/^ip .*maddr show/ {s = s "show "} /^ip .*maddr add/ {s = s "add "} /^tcpdump / {s = s "tcpdump "} /^ip .*maddr del/ {s = s "del "} END {print s}' $W/$1.argv; }
want='leaf1.example swp7 uplink_to_hx Example_NOS_1.0'

# --- a frame: its four TLVs fill the row, under each awk the hosts may have ---
for v in bsd mawk gawk; do FAKE_AWK=$v diag cap.$v "" FF_LLDP=1 FAKE_TCPDUMP=frame; done
chk "capture: one LLDP frame's System Name, Port ID, Port Description and System Description fill p0's @@LLDP row, the same under bsd awk, mawk and gawk" \
    "[ \"\$(row cap.bsd)\" = \"\$want\" ] && [ \"\$(row cap.mawk)\" = \"\$want\" ] && [ \"\$(row cap.gawk)\" = \"\$want\" ]" "bsd: $(row cap.bsd) | mawk: $(row cap.mawk) | gawk: $(row cap.gawk)"
chk "capture: ip maddr show, add 01:80:c2:00:00:0e, one tcpdump, del, in that order" \
    "[ \"\$(seq_of cap.bsd)\" = 'show add tcpdump del ' ] && grep -qx 'ip maddr add 01:80:c2:00:00:0e dev p0' $W/cap.bsd.argv && grep -qx 'ip maddr del 01:80:c2:00:00:0e dev p0' $W/cap.bsd.argv" "$(seq_of cap.bsd)"
diag has "" FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_MADDR_HAS=1
chk "capture, the group MAC already on p0: maddr show only, no add or del (control: the run above added and removed it)" \
    "[ \"\$(seq_of has)\" = 'show tcpdump ' ] && [ \"\$(row has)\" = \"\$want\" ]" "$(seq_of has) | $(row has)"
diag fail "" FF_LLDP=1 FAKE_TCPDUMP=fail
chk "capture fails (tcpdump rc 1): the group MAC is still removed and p0's @@LLDP row stays unknown" \
    "[ \"\$(seq_of fail)\" = 'show add tcpdump del ' ] && [ \"\$(row fail)\" = 'unknown unknown unknown unknown' ]" "$(seq_of fail) | $(row fail)"

# --- the NIC's firmware LLDP agent consumes the frames: no capture, the reason in the raw text ---
diag fw1 "" FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_PRIV='fw-lldp-agent          : on'
diag fw2 "" FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_PRIV='disable-fw-lldp        : off'
diag fw3 mlxconfig FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_DRV=mlx5_core FAKE_MLX=on
diag fwoff mlxconfig FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_DRV=mlx5_core
diag fwoffi "" FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_PRIV=$'fw-lldp-agent          : off\ndisable-fw-lldp        : on'
for n in fw1 fw2 fw3; do
    chk "firmware LLDP agent on ($(case $n in fw1) echo 'ethtool fw-lldp-agent: on' ;; fw2) echo 'ethtool disable-fw-lldp: off' ;; *) echo 'mlxconfig LLDP_NB_* non-zero' ;; esac)): 0 tcpdump calls, p0 unknown, reason fw_lldp_on in the raw text (control: the flags-off runs make 1 call each)" \
        "[ \$(calls $n tcpdump) = 0 ] && [ \"\$(row $n)\" = 'unknown unknown unknown unknown' ] && grep -qw fw_lldp_on $W/$n.out && [ \$(calls fwoff tcpdump) = 1 ] && [ \$(calls fwoffi tcpdump) = 1 ]" "tcpdump $(calls $n tcpdump), fwoff $(calls fwoff tcpdump), fwoffi $(calls fwoffi tcpdump); $(row $n); fw_lldp_on lines $(grep -cw fw_lldp_on $W/$n.out)"
done
chk "control: the agent off (ice: fw-lldp-agent off, disable-fw-lldp on; mlx5: LLDP_NB_* all zero): 1 tcpdump call each, p0's row filled, no fw_lldp_on" \
    "( for n in fwoff fwoffi; do [ \$(calls \$n tcpdump) = 1 ] && [ \"\$(row \$n)\" = \"\$want\" ] && ! grep -qw fw_lldp_on $W/\$n.out || exit 1; done )" "$(for n in fwoff fwoffi; do echo "$n: tcpdump $(calls $n tcpdump) | $(row $n) | fw_lldp_on lines $(grep -cw fw_lldp_on $W/$n.out);"; done)"
diag notd -tcpdump FF_LLDP=1
chk "FF_LLDP=1, no tcpdump on the host: 0 ip maddr calls, p0 unknown, reason tcpdump_absent in the raw text (control: the capture runs above make the maddr calls)" \
    "[ \$(calls notd 'ip maddr') = 0 ] && [ \"\$(row notd)\" = 'unknown unknown unknown unknown' ] && grep -qw tcpdump_absent $W/notd.out && [ \$(calls cap.bsd 'ip maddr') -ge 1 ]" "maddr $(calls notd 'ip maddr') | $(row notd) | tcpdump_absent lines $(grep -cw tcpdump_absent $W/notd.out)"

# --- off by default, and lldpcli wins when installed ---
diag off "" FAKE_TCPDUMP=frame
chk "FF_LLDP unset: 0 tcpdump and 0 ip maddr calls, p0 unknown as before the capture existed (control: the capture runs above make both)" \
    "[ \$(calls off tcpdump) = 0 ] && [ \$(calls off 'ip maddr') = 0 ] && [ \"\$(row off)\" = 'unknown unknown unknown unknown' ] && [ \$(calls cap.bsd tcpdump) = 1 ] && [ \$(calls cap.bsd 'ip maddr') -ge 1 ]" "off: tcpdump $(calls off tcpdump), maddr $(calls off 'ip maddr'), $(row off); cap: tcpdump $(calls cap.bsd tcpdump)"
diag lc lldpcli FF_LLDP=1 FAKE_TCPDUMP=frame
chk "lldpcli installed, FF_LLDP=1: p0's row from lldpcli (leaf2.example swp9), 0 tcpdump and 0 ip maddr calls (control: the same run without lldpcli captures)" \
    "[ \"\$(row lc)\" = 'leaf2.example swp9 uplink_to_hx Example_NOS_2.0' ] && [ \$(calls lc tcpdump) = 0 ] && [ \$(calls lc 'ip maddr') = 0 ] && [ \$(calls cap.bsd tcpdump) = 1 ]" "$(row lc) | tcpdump $(calls lc tcpdump), maddr $(calls lc 'ip maddr')"

# --- the reason row (11-02): a port with no neighbour gets one '@@LLDPWHY host port reason' after its @@LLDP row,
# the dashboard's text for it in place of "no switch seen"; bond p0's members p1 p2 come from FF_SYSFS ---
diag nott -timeout FF_LLDP=1 FAKE_TCPDUMP=frame
diag none "" FF_LLDP=1 FAKE_TCPDUMP=none
diag lcnone lldpcli FAKE_LLDPCLI_NONE=p0
mkdir -p $W/sys/class/net/p0/bonding; echo 'p1 p2' > $W/sys/class/net/p0/bonding/slaves
diag bond "" FF_LLDP=1 FAKE_TCPDUMP=frame FAKE_DRV=bonding FF_SYSFS=$W/sys
diag bondlc lldpcli FAKE_DRV=bonding FF_SYSFS=$W/sys FAKE_LLDPCLI_NONE=p0
chk "reason row, the firmware LLDP agent on (ice through ethtool, either flag; mlx5 through mlxconfig): one '@@LLDPWHY hx p0 fw_lldp_on' row in each run" \
    "[ \"\$(why fw1)\" = 'hx p0 fw_lldp_on' ] && [ \"\$(why fw2)\" = 'hx p0 fw_lldp_on' ] && [ \"\$(why fw3)\" = 'hx p0 fw_lldp_on' ]" "fw1: $(why fw1) | fw2: $(why fw2) | fw3: $(why fw3)"
chk "reason row, FF_LLDP=1 with no tcpdump on the host: one '@@LLDPWHY hx p0 tcpdump_absent' row" \
    "[ \"\$(why notd)\" = 'hx p0 tcpdump_absent' ]" "$(why notd)"
chk "FF_LLDP=1, no timeout command on the host: 0 tcpdump and 0 ip maddr calls, p0 unknown, reason timeout_absent in the raw text, one '@@LLDPWHY hx p0 timeout_absent' row (control: the capture runs above make both calls)" \
    "[ \$(calls nott tcpdump) = 0 ] && [ \$(calls nott 'ip maddr') = 0 ] && [ \"\$(row nott)\" = 'unknown unknown unknown unknown' ] && grep -qw timeout_absent $W/nott.out && [ \"\$(why nott)\" = 'hx p0 timeout_absent' ] && [ \$(calls cap.bsd tcpdump) = 1 ]" "tcpdump $(calls nott tcpdump), maddr $(calls nott 'ip maddr') | $(row nott) | timeout_absent lines $(grep -cw timeout_absent $W/nott.out) | $(why nott)"
chk "capture hears nothing in 70 s (tcpdump rc 124) or fails (rc 1): p0 unknown, the group MAC still removed, one '@@LLDPWHY hx p0 no_frame' row in each run" \
    "[ \"\$(seq_of none)\" = 'show add tcpdump del ' ] && [ \"\$(row none)\" = 'unknown unknown unknown unknown' ] && grep -q 'tcpdump rc=124' $W/none.out && [ \"\$(why none)\" = 'hx p0 no_frame' ] && [ \"\$(why fail)\" = 'hx p0 no_frame' ]" "none: $(seq_of none)| $(row none) | rc lines $(grep -c 'tcpdump rc=124' $W/none.out) | $(why none); fail: $(why fail)"
chk "reason row, no lldpcli and FF_LLDP unset: one '@@LLDPWHY hx p0 no_lldpcli' row, the line right after p0's @@LLDP row" \
    "[ \"\$(why off)\" = 'hx p0 no_lldpcli' ] && [ \"\$(grep -A1 '^@@LLDP hx p0 ' $W/off.out | sed -n 2p)\" = '@@LLDPWHY hx p0 no_lldpcli' ]" "$(why off) | next line: $(grep -A1 '^@@LLDP hx p0 ' $W/off.out | sed -n 2p)"
chk "reason row, lldpcli installed but it sees no neighbour on p0: p0 unknown, one '@@LLDPWHY hx p0 no_neighbour' row, 0 tcpdump calls" \
    "[ \"\$(row lcnone)\" = 'unknown unknown unknown unknown' ] && [ \"\$(why lcnone)\" = 'hx p0 no_neighbour' ] && [ \$(calls lcnone tcpdump) = 0 ]" "$(row lcnone) | $(why lcnone) | tcpdump $(calls lcnone tcpdump)"
chk "bond p0 with members p1 and p2: one '@@LLDPWHY hx p0 bond' row and none for the members, whose rows are filled, under tcpdump (2 calls, one per member, none on p0) and under lldpcli" \
    "[ \"\$(why bond)\" = 'hx p0 bond' ] && [ \"\$(row bond p1)\" = \"\$want\" ] && [ \"\$(row bond p2)\" = \"\$want\" ] && [ \$(calls bond 'tcpdump -p -i p[12] ') = 2 ] && [ \$(calls bond 'tcpdump -p -i p0 ') = 0 ] && [ \"\$(why bondlc)\" = 'hx p0 bond' ] && [ \"\$(row bondlc p1)\" = 'leaf2.example swp9 uplink_to_hx Example_NOS_2.0' ]" "tcpdump: $(why bond) | p1 $(row bond p1) | p2 $(row bond p2) | calls p1/p2 $(calls bond 'tcpdump -p -i p[12] ') p0 $(calls bond 'tcpdump -p -i p0 '); lldpcli: $(why bondlc) | p1 $(row bondlc p1)"
seen=$(cat $W/cap.bsd.out $W/cap.mawk.out $W/cap.gawk.out $W/has.out $W/fwoff.out $W/fwoffi.out $W/lc.out | grep -c '^@@LLDPWHY ')
chk "control: the 7 runs where p0 has a neighbour (capture under 3 awks, group MAC present, both agent-off runs, lldpcli) print 0 @@LLDPWHY rows ($seen; control: the no-lldpcli run prints 1)" \
    "[ $seen = 0 ] && [ \$(grep -c '^@@LLDPWHY ' $W/off.out) = 1 ]" "seen $seen, off $(grep -c '^@@LLDPWHY ' $W/off.out)"

# --- every capture in this group: never promiscuous, one port, one frame, LLDP only, under 70 s ---
all=$(cat $W/*.argv | grep '^tcpdump '); n=$(cat $W/*.argv | grep -c '^tcpdump ')
chk "every tcpdump call here is 'tcpdump -p -i <port> -c 1 -vv -s 1500 ether proto 0x88cc' on one port (p0, or bond member p1 or p2) under 'timeout 70' ($n calls; control: more than 0)" \
    "[ $n -ge 5 ] && ! grep -v -x -E 'tcpdump -p -i p[012] -c 1 -vv -s 1500 ether proto 0x88cc' <<<\"\$all\" | grep -q . && [ \$(cat $W/*.argv | grep -c '^timeout 70 tcpdump -p ') = $n ]" "$(sort <<<"$all" | uniq -c | tr '\n' '|') timeout lines: $(cat $W/*.argv | grep '^timeout' | sort | uniq -c | tr '\n' '|')"
finish
