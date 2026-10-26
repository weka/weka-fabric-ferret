# ---------- rail spec ----------

# Rails: RAIL_SPEC[r] = rail r's CIDRs (space separated) or NIC name; NR rails, labelled A, B, C...
LETTERS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
rail_letter() { echo "${LETTERS:$1:1}"; }
parse_rails() {
    if [[ -n $FF_NICS ]]; then
        RAIL_MODE=nic; _words "$FF_NICS"; RAIL_SPEC=("${WORDS[@]}")
        local n m
        for n in "${RAIL_SPEC[@]}"; do [[ $n =~ ^[A-Za-z0-9_.:-]+$ ]] || die "bad NIC name in FF_NICS: '$n'"; done
        for (( n = 0; n < ${#RAIL_SPEC[@]}; n++ )); do for (( m = n + 1; m < ${#RAIL_SPEC[@]}; m++ )); do
            [[ ${RAIL_SPEC[n]} != "${RAIL_SPEC[m]}" ]] || die "FF_NICS names the same NIC twice: ${RAIL_SPEC[n]}"
        done; done
    elif [[ -n $FF_RAILS ]]; then
        RAIL_MODE=cidr; RAIL_SPEC=()
        local -a parts; local p
        IFS=';' read -r -a parts <<<"$FF_RAILS"
        for p in "${parts[@]}"; do
            _words "$p"; (( ${#WORDS[@]} )) || die "FF_RAILS has an empty rail: '$FF_RAILS' (';' between rails, ',' between a rail's subnets)"
            RAIL_SPEC+=("${WORDS[*]}")
        done
    else
        RAIL_MODE=none; RAIL_SPEC=(); NR=0; RAILS=(); return
    fi
    NR=${#RAIL_SPEC[@]}; RAILS=($(seq 0 $(( NR - 1 ))))
    (( NR >= 1 && NR <= 26 )) || die "need 1 to 26 rails, got $NR"
    [[ $RAIL_MODE == cidr ]] || return 0
    # a rail is a set of CIDRs; no CIDR of one rail may overlap one of another
    local ca cb a b r s
    for r in "${RAILS[@]}"; do for ca in ${RAIL_SPEC[r]}; do [[ -n $(cidr_bounds "$ca") ]] || die "bad rail CIDR: '$ca'"; done; done
    for r in "${RAILS[@]}"; do for (( s = r + 1; s < NR; s++ )); do
        for ca in ${RAIL_SPEC[r]}; do for cb in ${RAIL_SPEC[s]}; do
            a=$(cidr_bounds "$ca"); b=$(cidr_bounds "$cb")
            if (( ${a% *} <= ${b#* } && ${b% *} <= ${a#* } )); then
                die "rail $(rail_letter $r) $ca overlaps rail $(rail_letter $s) $cb, so the rails can't be told apart; list each rail's subnets or set FF_NICS"
            fi
        done; done
    done; done
}

# Client data NICs: CLIENT_MODE nets (CLIENT_SPEC = CIDRs) or nics (names); none when FF_CLIENTS is unset
parse_clients() {
    CLIENT_MODE=none; CLIENT_SPEC=()
    [[ -n $FF_CLIENTS ]] || { [[ -n $FF_CLIENT_NETS$FF_CLIENT_NICS ]] && die "FF_CLIENT_NETS/FF_CLIENT_NICS need FF_CLIENTS (the client ssh targets)"; return 0; }
    local c
    if [[ -n $FF_CLIENT_NICS ]]; then
        CLIENT_MODE=nics; _words "$FF_CLIENT_NICS"; CLIENT_SPEC=("${WORDS[@]}")
        for c in "${CLIENT_SPEC[@]}"; do [[ $c =~ ^[A-Za-z0-9_.:-]+$ ]] || die "bad NIC name in FF_CLIENT_NICS: '$c'"; done
    elif [[ -n $FF_CLIENT_NETS ]]; then
        CLIENT_MODE=nets; _words "$FF_CLIENT_NETS"; CLIENT_SPEC=("${WORDS[@]}")
        for c in "${CLIENT_SPEC[@]}"; do [[ -n $(cidr_bounds "$c") ]] || die "bad client CIDR in FF_CLIENT_NETS: '$c'"; done
    else
        CLIENT_MODE=list   # sweep, list the clients' subnets, stop
    fi
    [[ -z $FF_CLIENT_RATIO || $FF_CLIENT_RATIO =~ ^([1-9][0-9]*|full|[1-9][0-9]*:full)$ ]] ||
        die "FF_CLIENT_RATIO must be N, full or N:full (N = client NICs per backend NIC per wave), got '$FF_CLIENT_RATIO'"
    : "${FF_CLIENT_RATIO:=1}"
    CL_WAVES=1; CL_FULL=0; CL_R=${FF_CLIENT_RATIO%%:*}
    [[ $FF_CLIENT_RATIO == full ]] && { CL_WAVES=0; CL_FULL=1; CL_R=0; }
    [[ $FF_CLIENT_RATIO == *:full ]] && CL_FULL=1
    [[ -z $FF_CLIENT_GBPS || $FF_CLIENT_GBPS =~ ^[1-9][0-9]*$ ]] || die "FF_CLIENT_GBPS must be a positive integer, got '$FF_CLIENT_GBPS'"
    [[ -z $FF_EXPECT_CLIENTS || $FF_EXPECT_CLIENTS =~ ^[1-9][0-9]*$ ]] || die "FF_EXPECT_CLIENTS must be a positive integer"
    return 0
}

# exit 1 = WEKA not installed or no container running, 0 = one is Running, 2 = CLI failed
WEKA_BUSY_CHECK='[ -n "$(command -v weka)" ] || exit 1; s=$(weka local ps --no-header -o name,state) || exit 2; echo "$s" | grep -qw Running'
