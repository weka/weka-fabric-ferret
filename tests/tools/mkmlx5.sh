#!/usr/bin/env bash
# Synthetic mlx5 text for the unit drivers that used to read a real host's (03, 23; step b, 10-29): the section names and
# counter names are the driver's and ethtool's own vocabulary, every value and identifier is made here (vendor "Example
# Optics", part EX-400G-SR8, serial EX00000001, firmware 28.00.0000, leaf-r01-a, locally administered MACs).
# usage: tools/mkmlx5.sh raw <file> <host>   a host's raw_per_host text: two 400G rail NICs (enp5s0np0 on leaf-r01-a swp2s1
#                                            with an optic at 47.25 C, enp196s0np0 on leaf-r01-b with a DAC), the
#                                            sections DIAG_SCRIPT prints (ethtool / -i / -m / -S / lldpcli per NIC, hostname,
#                                            ip -br -4 a, ibstat)
#        tools/mkmlx5.sh dump <file>         a 100G hardware dump as test_hwdump.sh reads it: ens800f0np0 (FEC RS, counters 0,
#                                            a DAC without DDM: no module temperature) and ens300f0np0 (FEC Off)
#        tools/mkmlx5.sh ethtool <file>      "=== ethtool -S ens800f0np0" then a 100G NIC's statistics: the 54 prio / pause /
#                                            ECN / discard names PRIO_SCRIPT keeps, among per-ring and plain counters it drops
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "mkmlx5.sh: bash 4+ needed" >&2; exit 2; }
mode=${1:?usage: tools/mkmlx5.sh raw|dump|ethtool <file> [host]}; F=${2:?usage: tools/mkmlx5.sh raw|dump|ethtool <file> [host]}

# ethtool -S: the names the prio filter keeps (54: 8 x rx/tx prioN bytes/packets + rx discards, pause/ECN/discard/global
# pause/storm), plus names it must drop (per-ring chN_/rxN_/txN_, plain rx_/tx_ totals, the phy error counters)
stats() {   # $1 = a seed for the values
    local s=$1 p
    echo "NIC statistics:"
    printf '     %s: %s\n' rx_packets $(( s * 7919 )) rx_bytes $(( s * 1000003 )) tx_packets $(( s * 7907 )) tx_bytes $(( s * 999983 )) \
        rx_corrected_bits_phy 0 rx_err_lane_0_phy 0 rx_err_lane_1_phy 0 rx_err_lane_2_phy 0 rx_err_lane_3_phy 0 \
        link_down_events_phy 0 rx_pcs_symbol_err_phy 0 rx_symbol_err_phy 0 \
        rx_ecn_mark $(( s * 11 )) rx_xsk_ecn_mark 0 rx_out_of_buffer $(( s * 3 )) rx_pause_ctrl_phy 0 tx_pause_ctrl_phy 0 \
        rx_discards_phy 0 tx_discards_phy 0
    for p in 0 1 2 3 4 5 6 7; do
        printf '     %s: %s\n' rx_prio${p}_bytes $(( p == 3 ? s * 500009 : 0 )) rx_prio${p}_packets $(( p == 3 ? s * 4001 : 0 )) \
            rx_prio${p}_discards 0 tx_prio${p}_bytes $(( p == 3 ? s * 500029 : 0 )) tx_prio${p}_packets $(( p == 3 ? s * 4003 : 0 ))
    done
    printf '     %s: %s\n' rx_global_pause 0 rx_global_pause_duration 0 tx_global_pause 0 tx_global_pause_duration 0 \
        rx_global_pause_transition 0 tx_pause_storm_warning_events 0 tx_pause_storm_error_events 0 \
        ch0_poll $(( s * 101 )) ch0_arm $(( s * 97 )) rx0_packets $(( s * 1009 )) rx0_bytes $(( s * 100003 )) tx0_packets $(( s * 1013 )) tx0_xmit_more 0
}
settings() {   # $1 nic $2 speed (Mb/s) $3 port type word
    printf 'Settings for %s:\n\tSupported ports: [ %s ]\n\tSupported link modes:   %sbaseCR4/Full\n\t                        %sbaseSR4/Full\n' "$1" "$3" "$(( $2 / 1000 ))" "$(( $2 / 1000 ))"
    printf '\tSupported FEC modes: RS\n\tAdvertised link modes:  %sbaseCR4/Full\n\tSpeed: %sMb/s\n\tDuplex: Full\n\tAuto-negotiation: on\n\tPort: Direct Attach Copper\n\tPHYAD: 0\n\tTransceiver: internal\n\tLink detected: yes\n' "$(( $2 / 1000 ))" "$2"
}
drvinfo() {   # $1 bus address
    printf 'driver: mlx5_core\nversion: 24.10-0.0.0\nfirmware-version: 28.00.0000 (EXA0000000001)\nexpansion-rom-version: \nbus-info: %s\n' "$1"
    printf 'supports-statistics: yes\nsupports-test: yes\nsupports-eeprom-access: no\nsupports-register-dump: no\nsupports-priv-flags: yes\n'
}
optic() {   # an OSFP optic with DDM: module temperature 47.25 C, rx power per channel
    local c
    printf '\tIdentifier                                : 0x19 (OSFP 8X Pluggable Transceiver)\n\tConnector                                 : 0x27 (MPO Parallel Optic)\n'
    printf '\tTransmitter technology                    : 0x00 (850 nm VCSEL)\n\tVendor name                               : Example Optics\n\tVendor OUI                                : 02:00:00\n'
    printf '\tVendor PN                                 : EX-400G-SR8\n\tVendor rev                                : A0\n\tVendor SN                                 : EX00000001\n\tDate code                                 : 260101\n'
    printf '\tModule State                              : 0x03 (ModuleReady)\n\tModule temperature                        : 47.25 degrees C / 117.05 degrees F\n\tModule voltage                            : 3.2812 V\n'
    for c in 1 2 3 4; do printf '\tLaser tx bias current (Channel %s)         : 6.500 mA\n' $c; done
    for c in 1 2 3 4; do printf '\tTransmit avg optical power (Channel %s)    : 1.0000 mW / 0.00 dBm\n' $c; done
    for c in 1 2 3 4; do printf '\tRcvr signal avg optical power (Channel %s) : 0.8%s00 mW / -0.9%s dBm\n' $c $c $c; done
    printf '\tModule temperature high alarm             : Off\n\tModule temperature high alarm threshold   : 80.00 degrees C / 176.00 degrees F\n'
}
dac() {   # a passive DAC: no monitoring at all
    printf '\tIdentifier                                : 0x11 (QSFP28)\n\tExtended identifier                       : 0x00\n\tConnector                                 : 0x23 (No separable connector)\n'
    printf '\tTransceiver type                          : 100G Ethernet: 100G Base-CR4\n\tEncoding                                  : 0x05 (64B/66B)\n\tBR, Nominal                               : 25500Mbps\n'
    printf '\tLength (Copper or Active cable)           : 2m\n\tTransmitter technology                    : 0xa0 (Copper cable unequalized)\n\tVendor name                               : Example Cables\n'
    printf '\tVendor OUI                                : 02:00:01\n\tVendor PN                                 : EX-100G-DAC2M\n\tVendor rev                                : A\n\tVendor SN                                 : EX00000002\n\tDate code                                 : 260101\n'
}
lldp() {   # $1 nic $2 leaf $3 port
    printf -- '-------------------------------------------------------------------------------\nLLDP neighbors:\n-------------------------------------------------------------------------------\n'
    printf 'Interface:    %s, via: LLDP, RID: 1, Time: 10 days, 01:02:03\n  Chassis:     \n    ChassisID:    mac 02:00:00:ff:00:01\n    SysName:      %s\n    SysDescr:     Cumulus Linux\n    MgmtIP:       198.18.200.1\n    Capability:   Bridge, on\n    Capability:   Router, on\n  Port:        \n    PortID:       ifname %s\n    PortDescr:    %s.example - FE2/1\n    TTL:          120\n' "$1" "$2" "$3" "$2"
    printf -- '-------------------------------------------------------------------------------\n'
}
case $mode in
raw)
    h=${3:?usage: tools/mkmlx5.sh raw <file> <host>}
    {
        echo "=== ethtool enp5s0np0 ==="; settings enp5s0np0 400000 FIBRE
        echo "=== ethtool -i enp5s0np0 ==="; drvinfo 0000:05:00.0
        echo "=== ethtool -m enp5s0np0 ==="; optic
        echo "=== ethtool -S enp5s0np0 ==="; stats 11 | grep -E "rx_|tx_|link_down|pcs_symbol|prio|pause" | grep -v "ch[0-9]"
        echo "=== lldpcli enp5s0np0 ==="; lldp enp5s0np0 leaf-r01-a swp2s1
        echo "=== ethtool enp196s0np0 ==="; settings enp196s0np0 400000 DAC
        echo "=== ethtool -i enp196s0np0 ==="; drvinfo 0000:c4:00.0
        echo "=== ethtool -m enp196s0np0 ==="; dac
        echo "=== ethtool -S enp196s0np0 ==="; stats 13 | grep -E "rx_|tx_|link_down|pcs_symbol|prio|pause" | grep -v "ch[0-9]"
        echo "=== lldpcli enp196s0np0 ==="; lldp enp196s0np0 leaf-r01-b swp2s1
        echo "=== hostname ==="; echo "$h"
        echo "=== ip addr ==="
        printf 'lo               UNKNOWN        127.0.0.1/8 \neno1.100@eno1    UP             198.18.100.1/23 \nenp5s0np0        UP             198.19.1.1/31 \nenp196s0np0      UP             198.19.2.1/31 \n'
        echo "=== ibstat ==="
        for c in 0 1; do printf "CA 'mlx5_%s'\n\tCA type: MT4129\n\tNumber of ports: 1\n\tFirmware version: 28.00.0000\n\tHardware version: 0\n\tNode GUID: 0x0200000000000%s0\n\tPort 1:\n\t\tState: Active\n\t\tPhysical state: LinkUp\n\t\tRate: 400\n\t\tLink layer: Ethernet\n" $c $c; done
    } > "$F" ;;
dump)
    {
        echo "=== host hx kernel 6.8.0-00-generic bash 5.2.21(1)-release"
        for n in ens800f0np0 ens300f0np0; do
            echo "=== ethtool  $n"; settings $n 100000 DAC
            echo "=== ethtool -i $n"; drvinfo $( [ $n = ens800f0np0 ] && echo 0000:81:00.0 || echo 0000:31:00.0 )
            echo "=== ethtool -m $n"; dac
            echo "=== ethtool -I --show-fec $n"
            printf 'FEC parameters for %s:\nSupported/Configured FEC encodings: Auto\n' $n
            if [ $n = ens800f0np0 ]; then printf 'Active FEC encoding: RS\nStatistics:\n  corrected_blocks: 0\n  uncorrectable_blocks: 0\n  corrected_bits: 0\n'; else echo 'Active FEC encoding: Off'; fi
            echo "=== ethtool -S $n"; stats $( [ $n = ens800f0np0 ] && echo 17 || echo 19 )
        done
        echo "=== lldpcli show neighbors"; echo "LLDP neighbors:"
    } > "$F" ;;
ethtool) { echo "=== ethtool -S ens800f0np0"; stats 23; } > "$F" ;;
*) echo "mkmlx5.sh: unknown mode $mode" >&2; exit 2 ;;
esac
