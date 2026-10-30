# usage: test_lldp.sh <lldp_file> <host_list>   (the site sample's layout: A=enp5s0np0 B=enp196s0np0)
source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
WORK=$(mktemp -d); COLLECT_DIR=$WORK
declare -A T_HOST RNIC; ELIG=(); k=0; RAILS=(0 1); NR=2   # v3 collectors loop over RAILS
while read -r h rest; do T_HOST[$k]=$h; RNIC[$k,0]=enp5s0np0; RNIC[$k,1]=enp196s0np0; ELIG+=($k); k=$((k+1)); done < "$2"
: > "$COLLECT_DIR/rail_anomalies.txt"
lldp_rail_check "$1" 2>&1
echo "anomalies: $(grep -c lldp_wrong_rail "$COLLECT_DIR/rail_anomalies.txt")"
rm -rf "${WORK:?}"
