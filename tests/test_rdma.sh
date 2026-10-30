# RDMA hw_counters reader on a fake sysfs: test_rdma.sh <collector.sh> <workdir>
# mlx5_0 on enp5s0np0, mlx5_1 on enp196s0np0; vlan100 over enp196s0np0; bond0 over both (no mapping)
C=$1; T=$2/fakesys; rm -rf "${T:?}"
mkdir -p $T/class/infiniband/mlx5_0/ports/1/{hw_counters,counters,gid_attrs/ndevs} $T/class/infiniband/mlx5_1/ports/1/{hw_counters,gid_attrs/ndevs} $T/class/net/{enp5s0np0,enp196s0np0,vlan100,bond0}
echo enp5s0np0 > $T/class/infiniband/mlx5_0/ports/1/gid_attrs/ndevs/0
echo enp196s0np0 > $T/class/infiniband/mlx5_1/ports/1/gid_attrs/ndevs/0
for c in np_ecn_marked_roce_packets:11 np_cnp_sent:7 rp_cnp_handled:5 out_of_sequence:2 local_ack_timeout_err:1 roce_adp_retrans:4 roce_slow_restart:0 out_of_buffer:9 req_transport_retries_exceeded:2 rx_write_requests:99; do echo ${c#*:} > $T/class/infiniband/mlx5_0/ports/1/hw_counters/${c%%:*}; done
echo 3 > $T/class/infiniband/mlx5_0/ports/1/counters/port_xmit_discards; echo 8 > $T/class/infiniband/mlx5_0/ports/1/counters/port_rcv_data
echo 6 > $T/class/infiniband/mlx5_1/ports/1/hw_counters/np_cnp_sent; echo "N/A" > $T/class/infiniband/mlx5_1/ports/1/hw_counters/packet_seq_err
ln -s ../enp196s0np0 $T/class/net/vlan100/lower_enp196s0np0
ln -s ../enp5s0np0 $T/class/net/bond0/lower_enp5s0np0; ln -s ../enp196s0np0 $T/class/net/bond0/lower_enp196s0np0
source "$C"
ethtool() { :; }; hostname() { echo hx; }
export FF_SYSFS=$T; set -- enp5s0np0 vlan100 bond0 nosuch -
( eval "$PRIO_SCRIPT" ) | sort
