NR==FNR {pre[$1" "$2]=$3; next}
    ($1" "$2) in pre && $3 > pre[$1" "$2] {print it, $1, $2, $3 - pre[$1" "$2]}
