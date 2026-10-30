# PRIO_SCRIPT ethtool filter on an mlx5 100G ethtool -S text (tools/mkmlx5.sh ethtool; was a real NIC's until step b, 10-29):
# test_prio_real.sh <collector.sh> <ethtool -S file>   (the file's first line is its "=== ethtool -S <nic>" header)
source "$1"; SF=${2:?ethtool -S file}   # kept outside the function: inside it, $2 is ethtool's own argument
ethtool() { tail -n +2 "$SF"; }; hostname() { echo hx; }
export FF_SYSFS=/nonexistent; set -- ens800f0np0
( eval "$PRIO_SCRIPT" ) | awk '{print $2}'
