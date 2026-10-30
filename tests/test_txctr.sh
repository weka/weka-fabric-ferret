# sender TX reader on a fake sysfs: test_txctr.sh <collector.sh> <workdir>
# eth0/eth1 have port counters (100, 50); bond0 over both; vlan100 over bond0 (two levels); plain has none;
# badbond over eth0 + plain (one member without a port counter: na, no guess)
C=$1; T=$2/fakesys_tx; rm -rf "${T:?}"
for n in eth0 eth1 bond0 vlan100 plain badbond vf0; do mkdir -p $T/class/net/$n/statistics; done
echo 6600000 > $T/class/net/vf0/statistics/tx_packets   # vf0: an mlx5 VF, tx_packets_phy always 0 (lab run 3)
echo 1000 > $T/class/net/eth0/statistics/tx_packets; echo 500 > $T/class/net/eth1/statistics/tx_packets
echo 1500 > $T/class/net/bond0/statistics/tx_packets; echo 1500 > $T/class/net/vlan100/statistics/tx_packets
echo 7 > $T/class/net/plain/statistics/tx_packets; echo 1007 > $T/class/net/badbond/statistics/tx_packets
ln -s ../eth0 $T/class/net/bond0/lower_eth0; ln -s ../eth1 $T/class/net/bond0/lower_eth1
ln -s ../bond0 $T/class/net/vlan100/lower_bond0
ln -s ../eth0 $T/class/net/badbond/lower_eth0; ln -s ../plain $T/class/net/badbond/lower_plain
source "$C"
ethtool() { case $2 in eth0) echo "     tx_packets_phy: 100" ;; eth1) echo "     tx_packets_phy: 50" ;; vf0) echo "     tx_packets_phy: 0" ;; *) echo "     tx_packets: 3" ;; esac; }
hostname() { echo hx; }; ip() { :; }
export FF_SYSFS=$T; set -- eth0 bond0 vlan100 plain badbond vf0 nosuch -
( eval "$TXCTR_SCRIPT" )
