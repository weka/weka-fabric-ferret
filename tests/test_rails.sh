# usage: bash test_rails.sh <discdir> <host_list> [hosts_file]  (rail env vars set by caller; hosts_file: only these hosts)
# bash 4.3+: the version check is fabric_ferret.sh's own first lines, which the source below runs before any declare -A
source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
declare -A DISC RNIC RIP RMTU RSTATE
parse_rails
k=0; declare -A HOSTK
for f in "$1"/*; do
    [[ -n $3 ]] && ! grep -qx "$(basename $f)" "$3" && continue
    DISC[$k]=$f; HOSTK[$k]=$(basename $f); k=$((k+1))
done
ok=0; bad=0; down=0
declare -A WANT_A WANT_B
while read -r h m a b; do WANT_A[$h]=$a; WANT_B[$h]=$b; done < "$2"
for ((i = 0; i < k; i++)); do
    rail_lookup $i 0; rail_lookup $i 1; h=${HOSTK[$i]}
    [[ ${RSTATE[$i,0]} == "link DOWN"* || ${RSTATE[$i,1]} == "link DOWN"* ]] && down=$((down+1))
    if [[ ${RIP[$i,0]} == "${WANT_A[$h]}" && ${RIP[$i,1]} == "${WANT_B[$h]}" ]]; then ok=$((ok+1))
    else bad=$((bad+1)); (( bad <= 3 )) && echo "  MISMATCH $h: got A=${RIP[$i,0]} (${RSTATE[$i,0]}) B=${RIP[$i,1]} (${RSTATE[$i,1]}) want ${WANT_A[$h]} ${WANT_B[$h]}"; fi
done
echo "mode=$RAIL_MODE hosts=$k match=$ok mismatch=$bad hosts_with_a_down_rail=$down"
