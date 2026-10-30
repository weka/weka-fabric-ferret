# Run a collector's per-NIC scripts against a real hardware dump: test_hwdump.sh <collector.sh> <dump> <script var> <nic>...
# ethtool [opt] nic is answered from the dump section "=== ethtool <opt> <nic>"
source "$1"; DUMP=$2; VAR=$3; shift 3
ethtool() { local o=; [ $# -gt 1 ] && o="${*:1:$#-1}"; awk -v s="=== ethtool $o ${!#}" '$0==s {on=1; next} /^=== / {on=0} on' "$DUMP"; }
# lldpcli show neighbors ports <nic> is answered from "=== lldpcli <nic>" (none in the dump: no neighbour)
lldpcli() { awk -v s="=== lldpcli ${!#}" '$0==s {on=1; next} /^=== / {on=0} on' "$DUMP"; }
ip() { echo "6: x inet 192.0.2.1/24 scope global x"; }
hostname() { echo hx; }; : "${FF_SYSFS:=/nonexistent}"; export FF_SYSFS   # a caller's FF_SYSFS (a bond's members) stands
( eval "${!VAR}" )
