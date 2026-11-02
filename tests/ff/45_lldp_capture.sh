#!/opt/homebrew/bin/bash
# LLDP without lldpcli (FF_LLDP_CAPTURE=1, opt-in, 11-02): DIAG_SCRIPT run here on port p0 with fake host tools:
# one tcpdump frame fills the @@LLDP row, the LLDP group MAC is added and removed around
# it, never promiscuous; a NIC whose firmware LLDP agent eats the frames is not captured
# tier: fast
# checks: 11
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# diag <name> "<extra tools>" [VAR=value ...]: DIAG_SCRIPT on p0, PATH = the fakes + /usr/bin:/bin (no lldpcli, tcpdump,
# ip there on macOS); output $W/<name>.out, argv log $W/<name>.argv. FAKE_AWK picks the awk (bsd)
diag() { local n=$1 t; mkdir -p $W/bin.$n; for t in ip ethtool tcpdump timeout hostname $2; do ln -s $S/fake/lldp/tool $W/bin.$n/$t; done
         shift 2; : > $W/$n.argv
         env FAKE_LLDP_LOG=$W/$n.argv "$@" $B -c 'source "$1"; PATH=$2; shift 2; eval "$DIAG_SCRIPT"' diag $C "$W/bin.$n:$S/awkbin/${FAKE_AWK:-bsd}:/usr/bin:/bin" p0 > $W/$n.out 2>&1; }
row() { grep '^@@LLDP hx p0 ' $W/$1.out | cut -d' ' -f5-; }   # chassis portid portdesc sysdesc
calls() { grep -c "^$2" $W/$1.argv; }   # calls <name> <tool argv prefix>
seq_of() { awk '/^ip .*maddr show/ {s = s "show "} /^ip .*maddr add/ {s = s "add "} /^tcpdump / {s = s "tcpdump "} /^ip .*maddr del/ {s = s "del "} END {print s}' $W/$1.argv; }
want='leaf1.example swp7 uplink_to_hx Example_NOS_1.0'

# --- a frame: its four TLVs fill the row, under each awk the hosts may have ---
for v in bsd mawk gawk; do FAKE_AWK=$v diag cap.$v "" FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame; done
chk "capture: one LLDP frame's System Name, Port ID, Port Description and System Description fill p0's @@LLDP row, the same under bsd awk, mawk and gawk" \
    "[ \"\$(row cap.bsd)\" = \"\$want\" ] && [ \"\$(row cap.mawk)\" = \"\$want\" ] && [ \"\$(row cap.gawk)\" = \"\$want\" ]" "bsd: $(row cap.bsd) | mawk: $(row cap.mawk) | gawk: $(row cap.gawk)"
chk "capture: ip maddr show, add 01:80:c2:00:00:0e, one tcpdump, del, in that order" \
    "[ \"\$(seq_of cap.bsd)\" = 'show add tcpdump del ' ] && grep -qx 'ip maddr add 01:80:c2:00:00:0e dev p0' $W/cap.bsd.argv && grep -qx 'ip maddr del 01:80:c2:00:00:0e dev p0' $W/cap.bsd.argv" "$(seq_of cap.bsd)"
diag has "" FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame FAKE_MADDR_HAS=1
chk "capture, the group MAC already on p0: maddr show only, no add or del (control: the run above added and removed it)" \
    "[ \"\$(seq_of has)\" = 'show tcpdump ' ] && [ \"\$(row has)\" = \"\$want\" ]" "$(seq_of has) | $(row has)"
diag fail "" FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=fail
chk "capture fails (tcpdump rc 1): the group MAC is still removed and p0's @@LLDP row stays unknown" \
    "[ \"\$(seq_of fail)\" = 'show add tcpdump del ' ] && [ \"\$(row fail)\" = 'unknown unknown unknown unknown' ]" "$(seq_of fail) | $(row fail)"

# --- the NIC's firmware LLDP agent consumes the frames: no capture, the reason in the raw text ---
diag fw1 "" FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame FAKE_PRIV='fw-lldp-agent          : on'
diag fw2 "" FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame FAKE_PRIV='disable-fw-lldp        : off'
diag fw3 mlxconfig FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame FAKE_DRV=mlx5_core FAKE_MLX=on
diag fwoff mlxconfig FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame FAKE_DRV=mlx5_core FAKE_PRIV='fw-lldp-agent          : off'
for n in fw1 fw2 fw3; do
    chk "firmware LLDP agent on ($(case $n in fw1) echo 'ethtool fw-lldp-agent: on' ;; fw2) echo 'ethtool disable-fw-lldp: off' ;; *) echo 'mlxconfig LLDP_NB_* non-zero' ;; esac)): 0 tcpdump calls, p0 unknown, reason fw_lldp_on in the raw text (control: the flags-off run makes 1 call)" \
        "[ \$(calls $n tcpdump) = 0 ] && [ \"\$(row $n)\" = 'unknown unknown unknown unknown' ] && grep -qw fw_lldp_on $W/$n.out && [ \$(calls fwoff tcpdump) = 1 ]" "tcpdump $(calls $n tcpdump), fwoff $(calls fwoff tcpdump); $(row $n); fw_lldp_on lines $(grep -cw fw_lldp_on $W/$n.out)"
done
chk "control: fw-lldp-agent off and mlxconfig LLDP_NB_* all zero: 1 tcpdump call, p0's row filled, no fw_lldp_on" \
    "[ \$(calls fwoff tcpdump) = 1 ] && [ \"\$(row fwoff)\" = \"\$want\" ] && ! grep -qw fw_lldp_on $W/fwoff.out" "tcpdump $(calls fwoff tcpdump) | $(row fwoff) | fw_lldp_on lines $(grep -cw fw_lldp_on $W/fwoff.out)"

# --- off by default, and lldpcli wins when installed ---
diag off "" FAKE_TCPDUMP=frame
chk "FF_LLDP_CAPTURE unset: 0 tcpdump and 0 ip maddr calls, p0 unknown as before the capture existed (control: the capture runs above make both)" \
    "[ \$(calls off tcpdump) = 0 ] && [ \$(calls off 'ip maddr') = 0 ] && [ \"\$(row off)\" = 'unknown unknown unknown unknown' ] && [ \$(calls cap.bsd tcpdump) = 1 ] && [ \$(calls cap.bsd 'ip maddr') -ge 1 ]" "off: tcpdump $(calls off tcpdump), maddr $(calls off 'ip maddr'), $(row off); cap: tcpdump $(calls cap.bsd tcpdump)"
diag lc lldpcli FF_LLDP_CAPTURE=1 FAKE_TCPDUMP=frame
chk "lldpcli installed, FF_LLDP_CAPTURE=1: p0's row from lldpcli (leaf2.example swp9), 0 tcpdump and 0 ip maddr calls (control: the same run without lldpcli captures)" \
    "[ \"\$(row lc)\" = 'leaf2.example swp9 uplink_to_hx Example_NOS_2.0' ] && [ \$(calls lc tcpdump) = 0 ] && [ \$(calls lc 'ip maddr') = 0 ] && [ \$(calls cap.bsd tcpdump) = 1 ]" "$(row lc) | tcpdump $(calls lc tcpdump), maddr $(calls lc 'ip maddr')"

# --- every capture in this group: never promiscuous, one port, one frame, LLDP only, under 70 s ---
all=$(cat $W/*.argv | grep '^tcpdump '); n=$(cat $W/*.argv | grep -c '^tcpdump ')
chk "every tcpdump call here is 'tcpdump -p -i p0 -c 1 -vv -s 1500 ether proto 0x88cc' under 'timeout 70' ($n calls; control: more than 0)" \
    "[ $n -ge 5 ] && ! grep -v -x 'tcpdump -p -i p0 -c 1 -vv -s 1500 ether proto 0x88cc' <<<\"\$all\" | grep -q . && [ \$(cat $W/*.argv | grep -c '^timeout 70 tcpdump -p ') = $n ]" "$(sort <<<"$all" | uniq -c | tr '\n' '|') timeout lines: $(cat $W/*.argv | grep '^timeout' | sort | uniq -c | tr '\n' '|')"
finish
