source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
RAW=$1; shift
ethtool() { awk -v s="=== ethtool -S $2 ===" '$0==s {on=1; next} /^=== / {on=0} on' "$RAW"; }
hostname() { basename "$RAW" .txt; }
( eval "$PRIO_SCRIPT" )
