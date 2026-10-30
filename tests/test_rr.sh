source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
# one rail group (GKEYS/GROT/GUPAIRS as rail_groups sets them): hosts 0..n-1, a bye "-" when odd
for n in 2 3 4 5 6 7 8 9; do
    rot=$(seq 0 $((n-1)) | tr '\n' ' '); (( n % 2 )) && rot+="-"
    GKEYS=(AB); GROT=("${rot% }"); GUPAIRS=("")
    m=$(( n + n % 2 )); rounds=$(( m - 1 )); declare -A seen=() sat=(); dup=0; pairs=0
    for (( r = 0; r < rounds; r++ )); do
        round_pairs $r
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            a=${PC[p]} b=${PS[p]}; (( a > b )) && { t=$a; a=$b; b=$t; }
            [[ -n ${seen[$a,$b]+x} ]] && dup=$((dup+1)); seen[$a,$b]=1; pairs=$((pairs+1))
        done
        s=${SITOUT# }; [[ -n $s ]] && sat[$s]=$(( ${sat[$s]:-0} + 1 ))
    done
    want=$(( n * (n - 1) / 2 )); sits=$(printf '%s\n' "${sat[@]}" | sort -u | tr '\n' ' ')
    echo "n=$n rounds=$rounds pairs=$pairs distinct=${#seen[@]} of $want dup=$dup sit-outs/host={${sits% }} hosts_sat=${#sat[@]}"
    unset seen sat
done
GKEYS=(AB); GROT=("fsl1 fsl2 fsl3 -"); GUPAIRS=(""); for r in 0 1 2; do round_pairs $r; echo "3 hosts round $((r+1)): ${PC[*]}<->${PS[*]} sits=${SITOUT# }"; done
# two rail groups: each its own circle and bye; no pair across them; the second cycle (t >= rounds) swaps client and server
GKEYS=(AB C); GROT=("a1 a2 a3 a4" "c1 c2 c3 -"); GUPAIRS=("0 1" "")
for t in 0 1 2 3; do round_pairs $t; o=""; for (( p = 0; p < ${#PC[@]}; p++ )); do o+="${PC[p]}>${PS[p]}(${GKEYS[${PG[p]}]}) "; done; echo "two groups t=$t: ${o% } sits=${SITOUT# }"; done
