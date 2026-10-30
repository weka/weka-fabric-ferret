# usage: bash test_diag.sh <raw_host_file> nic...   runs the collector's DIAG_SCRIPT with shimmed tools
source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
RAW=$1; shift
sec() { awk -v s="=== $1 ===" '$0==s {on=1; next} /^=== / {on=0} on' "$RAW"; }
ethtool() { case $1 in -i|-m|-S) sec "ethtool $1 $2" ;; *) sec "ethtool $1" ;; esac; }
lldpcli() { sec "lldpcli $4"; }
ip() { if [[ $* == *"show dev"* ]]; then sec "ip addr" | awk -v n="$6" '$1==n {print "2: " n "    inet " $3 " scope global " n}'; else sec "ip addr"; fi; }
hostname() { basename "$RAW" .txt; }
( eval "$DIAG_SCRIPT" ) | grep '^@@'
