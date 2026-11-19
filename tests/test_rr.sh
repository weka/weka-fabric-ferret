source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
# one rail group (GKEYS/GROT/GUPAIRS as rail_groups sets them): hosts 0..n-1 in ring order; n-1 rounds (strides)
for n in 2 3 4 5 6 7 8 9; do
    GKEYS=(AB); GROT=("$(seq 0 $((n-1)) | tr '\n' ' ')"); GROT[0]=${GROT[0]% }; GUPAIRS=("")
    rounds=$(( n - 1 )); declare -A seen=(); dup=0; links=0; bad=0
    for (( r = 0; r < rounds; r++ )); do
        round_pairs $r; declare -A snd=() rcv=()
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            a=${PC[p]} b=${PS[p]}
            [[ -n ${seen[$a,$b]+x} ]] && dup=$((dup+1)); seen[$a,$b]=1; links=$((links+1))
            snd[$a]=$(( ${snd[$a]:-0} + 1 )); rcv[$b]=$(( ${rcv[$b]:-0} + 1 ))
        done
        for (( h = 0; h < n; h++ )); do [[ ${snd[$h]:-0} == 1 && ${rcv[$h]:-0} == 1 ]] || bad=$((bad+1)); done
        unset snd rcv
    done
    echo "n=$n rounds=$rounds links=$links distinct=${#seen[@]} of $(( n * (n - 1) )) dup=$dup not_one_each=$bad"
    unset seen
done
# two rail groups: each its own ring; no link across them
GKEYS=(AB C); GROT=("a1 a2 a3 a4" "c1 c2 c3"); GUPAIRS=("0 1" "")
for t in 0 1 2; do round_pairs $t; o=""; for (( p = 0; p < ${#PC[@]}; p++ )); do o+="${PC[p]}>${PS[p]}(${GKEYS[${PG[p]}]}) "; done; echo "two groups t=$t: ${o% }"; done
