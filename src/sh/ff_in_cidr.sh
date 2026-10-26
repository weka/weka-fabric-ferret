in_cidr() {  # ip cidr; no subshells, it runs per address per host
    is_ip "$1" || return 1
    local -a o; IFS=. read -ra o <<<"$1"
    local n=$(( (10#${o[0]} << 24) + (10#${o[1]} << 16) + (10#${o[2]} << 8) + 10#${o[3]} ))
    local b=${_CIDR_CACHE[$2]}
    [[ -n $b ]] || { b=$(cidr_bounds "$2") || return 1; _CIDR_CACHE[$2]=$b; }
    (( n >= ${b% *} && n <= ${b#* } ))
}
declare -A _CIDR_CACHE=()
