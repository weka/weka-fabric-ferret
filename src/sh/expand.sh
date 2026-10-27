declare -a TARGETS=()
INPUT_RANGES=0   # 1 once FF_HOSTS has a CIDR or range: unanswered addresses are then normal
declare -A _SEEN=()
_emit() {
    [[ -n ${_SEEN[$1]+x} ]] && return
    _SEEN[$1]=1; TARGETS+=("$1")
    (( ${#TARGETS[@]} <= FF_MAX_TARGETS )) || die "$EXPANDING expands past FF_MAX_TARGETS=$FF_MAX_TARGETS; narrow it or raise the cap"
}
_need() {  # refuse a range before looping over it
    (( ${#TARGETS[@]} + $1 <= FF_MAX_TARGETS )) || die "$EXPANDING: '$2' adds $1 targets, past FF_MAX_TARGETS=$FF_MAX_TARGETS"
}

expand_entry() {
    local e=$1 b lo hi n
    [[ $e == *:* ]] && die "$EXPANDING: IPv6 is not supported: '$e'"
    if [[ $e == */* ]]; then
        b=$(cidr_bounds "$e") || die "$EXPANDING: bad CIDR: '$e'"
        lo=${b% *}; hi=${b#* }
        (( hi - lo >= 2 )) && { lo=$(( lo + 1 )); hi=$(( hi - 1 )); }
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^([0-9.]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}  # is_ip resets BASH_REMATCH
        is_ip "$from" && is_ip "$to" || die "$EXPANDING: bad IP range: '$e'"
        lo=$(ip2int "$from"); hi=$(ip2int "$to")
        (( lo <= hi )) || die "$EXPANDING: range runs backwards: '$e'"
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?$ ]]; then
        local -a lo4 hi4; local IFS=. o i count=1 a b c d
        local -a oct=($e)
        for i in 0 1 2 3; do
            o=${oct[$i]}
            lo4[$i]=$(( 10#${o%-*} )); hi4[$i]=$(( 10#${o#*-} ))
            (( lo4[i] <= hi4[i] && hi4[i] <= 255 )) || die "$EXPANDING: bad octet '$o' in '$e'"
            count=$(( count * (hi4[i] - lo4[i] + 1) ))
        done
        unset IFS
        (( count > 1 )) && INPUT_RANGES=1
        _need $count "$e"
        for (( a = lo4[0]; a <= hi4[0]; a++ )); do for (( b = lo4[1]; b <= hi4[1]; b++ )); do
        for (( c = lo4[2]; c <= hi4[2]; c++ )); do for (( d = lo4[3]; d <= hi4[3]; d++ )); do
            _emit "$a.$b.$c.$d"
        done; done; done; done
    elif [[ $e =~ ^[0-9.-]+$ ]]; then
        die "$EXPANDING: not a valid IP, range or CIDR: '$e'"
    elif [[ $e =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _emit "$e"
    else
        die "$EXPANDING: not a hostname, IP, range or CIDR: '$e'"
    fi
}

# split on commas and whitespace, no globbing
_words() { local IFS=$', \t\n'; set -f; WORDS=($1); set +f; }

# expand_targets value [setting name, FF_HOSTS]: fills TARGETS and INPUT_RANGES
expand_targets() {
    local w line
    EXPANDING=${2:-FF_HOSTS}; TARGETS=(); _SEEN=(); INPUT_RANGES=0
    [[ -n $1 ]] || die "$EXPANDING is empty"
    _words "$1"
    local -a top=("${WORDS[@]}")
    for w in "${top[@]}"; do
        if [[ $w == @* ]]; then
            [[ -r ${w#@} ]] || die "$EXPANDING: cannot read host file '${w#@}'"
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%%#*}
                _words "$line"
                for e in "${WORDS[@]}"; do
                    [[ $e == @* ]] && die "$EXPANDING: nested @file not supported: '$e' in ${w#@}"
                    expand_entry "$e"
                done
            done < "${w#@}"
        else
            expand_entry "$w"
        fi
    done
    (( ${#TARGETS[@]} > 0 )) || die "$EXPANDING expanded to zero targets"
}
