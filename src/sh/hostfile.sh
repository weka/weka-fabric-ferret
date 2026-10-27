# load_target_file file deflogin: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped). type backend
# (host = backend) or client: ssh targets (IP, name, CIDR or range, as FF_HOSTS); bmc: one BMC address read out of
# band. A host field * or a glob (* ? [...], any case) is a credential row: it adds no targets. Type * = backend
# and client, never bmc. Each target takes the most specific row that gives a login or pw: one host > CIDR/range >
# glob > <type>,* > *,* > the default (deflogin, key; a bmc: the current user, empty password). That row is the
# credential, with no fallback. The pw is everything after the third comma, verbatim. Errors and warnings name
# line numbers, never the text (it may hold a password). Sets TARGETS T_TYPE T_LOGIN T_PW T_LINE, BMCS B_LOGIN
# B_PW B_LINE (T_LINE/B_LINE: the line whose credential it took, or "default").
load_target_file() {
    local f=$1 def=$2 line ln=0 ty h lg pw rest k r t g n tier me
    local -a R_LN=() R_TY=() R_H=() R_LG=() R_PW=() R_TIER=() wild=()
    local -A tidx=() bidx=() warned=()
    [[ -r $f && -f $f ]] || die "-t: cannot read '$f'"
    [[ $def =~ ^[A-Za-z0-9._@-]+$ ]] || die "FF_SSH_USER: bad login (letters, digits . _ @ - only)"
    me=$(id -un); T_ROW=(); B_ROW=()
    # also set: HF_RANGES[backend|client] (1 once a row of that type has a CIDR or range: INPUT_RANGES per type, so a
    # backend range never makes a dead client look normal) and HF_WILD_LINES (the credential rows' line numbers)
    declare -gA HF_RANGES=([backend]=0 [client]=0); declare -ga HF_WILD_LINES=()
    # _offer T|B idx row: the row's credentials for that target if more specific than what it has; an equal one
    # that differs keeps the first, warned once per pair of lines
    _offer() {
        local -n rw=${1}_ROW; local o=${rw[$2]}
        if [[ -z $o ]] || (( R_TIER[$3] > R_TIER[o] )); then rw[$2]=$3
        elif (( R_TIER[$3] == R_TIER[o] && o != $3 )) && [[ ${R_LG[$3]} != "${R_LG[o]}" || ${R_PW[$3]} != "${R_PW[o]}" ]] && [[ -z ${warned[$o,$3]} ]]; then
            warned[$o,$3]=1; log "WARNING: -t $f lines ${R_LN[o]} and ${R_LN[$3]} give a target different credentials at the same specificity; line ${R_LN[o]}'s are used"
        fi
    }
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *,* ]] || line="backend,$line"   # a bare line is a backend with the defaults: a plain host list works
        [[ $line =~ ^[^,]*,[[:space:]]*(#|,*[[:space:]]*$) ]] && continue   # "host,# ...", "host," : commented out or empty
        ty=${line%%,*}; rest=${line#*,}
        h=${rest%%,*}; [[ $rest == *,* ]] && rest=${rest#*,} || rest=
        lg=${rest%%,*}; [[ $rest == *,* ]] && pw=${rest#*,} || pw=
        # trim the ends only: a space inside a type, host or login is bad input, refused below with its line number
        for k in ty h lg; do local -n v=$k; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; unset -n v; done
        ty=${ty,,}
        [[ -z $lg || $lg =~ ^[A-Za-z0-9._@-]+$ ]] || die "-t $f line $ln: bad login (letters, digits . _ @ - only)"
        [[ -n $pw ]] && HAVE_PW=1
        [[ $ty == host ]] && ty=backend
        [[ $ty =~ ^(backend|client|bmc|\*)$ ]] || die "-t $f line $ln: type must be backend, client, bmc (host = backend) or *"
        [[ -n $h ]] || die "-t $f line $ln: no host"
        r=${#R_LN[@]}; R_LN[r]=$ln; R_TY[r]=$ty; R_H[r]=$h; R_LG[r]=$lg; R_PW[r]=$pw
        if [[ $h == *[\*\?\[]* ]]; then   # a credential row: matched against the targets once all are read
            [[ $h =~ ^[][A-Za-z0-9.*?!^-]+$ ]] || die "-t $f line $ln: bad host pattern (letters, digits . - and * ? [...] only)"
            [[ -n $lg || -n $pw ]] || die "-t $f line $ln: a wildcard row adds no targets, so it needs a login or pw"
            if [[ $h != '*' ]]; then tier=3; elif [[ $ty != '*' ]]; then tier=2; else tier=1; fi
            R_TIER[r]=$tier; wild+=("$r"); HF_WILD_LINES+=("$ln"); continue
        fi
        [[ $ty == '*' ]] && die "-t $f line $ln: type * takes a host of * or a glob (it adds no targets)"
        if [[ $ty == bmc ]]; then
            is_ip "$h" || [[ $h =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || die "-t $f line $ln: a bmc line takes one IP or hostname, or a glob (no CIDR or range)"
            R_TIER[r]=5
            [[ -n ${bidx[$h]+x} ]] || { bidx[$h]=${#BMCS[@]}; BMCS+=("$h"); }
            [[ -n $lg || -n $pw ]] && _offer B "${bidx[$h]}" "$r"
            continue
        fi
        # an ssh target row, expanded onto the list; _COVER (expand.sh) names every target it covers, listed before or not
        R_TIER[r]=5; [[ $h == */* || ( $h =~ ^[0-9.-]+$ && $h == *-* ) ]] && R_TIER[r]=4
        local ir=$INPUT_RANGES n0=${#TARGETS[@]}
        EXPANDING="-t $f line $ln"; INPUT_RANGES=0; _TRACK=1; _COVER=()
        expand_entry "$h"; _TRACK=0
        (( HF_RANGES[$ty] |= INPUT_RANGES, INPUT_RANGES |= ir ))   # this row's range flag, kept per type too
        for (( k = n0; k < ${#TARGETS[@]}; k++ )); do tidx[${TARGETS[k]}]=$k; T_TYPE[k]=$ty; T_FROM[k]=$ln; done
        for t in "${_COVER[@]}"; do
            [[ ${T_TYPE[${tidx[$t]}]} == "$ty" ]] || die "-t $f line $ln: a target here is already listed as ${T_TYPE[${tidx[$t]}]} on line ${T_FROM[${tidx[$t]}]}"
            [[ -n $lg || -n $pw ]] && _offer T "${tidx[$t]}" "$r"
        done
    done < "$f"
    # credential rows (globs, <type>,*, *,*): * never reaches a bmc; a row that matches no target is warned
    for r in "${wild[@]}"; do
        n=0; g=${R_H[r],,}
        if [[ ${R_TY[r]} == bmc ]]; then
            for k in "${!BMCS[@]}"; do t=${BMCS[$k],,}; [[ $t == $g ]] && { n=$(( n + 1 )); _offer B "$k" "$r"; }; done
        else
            for k in "${!TARGETS[@]}"; do
                [[ ${R_TY[r]} == '*' || ${R_TY[r]} == "${T_TYPE[$k]}" ]] || continue
                t=${TARGETS[$k],,}; [[ $t == $g ]] && { n=$(( n + 1 )); _offer T "$k" "$r"; }
            done
        fi
        (( n )) || log "WARNING: -t $f line ${R_LN[r]} matches no target"
    done
    # the chosen row is THE credential: its login (else the default) and its pw (else key ssh / an empty BMC password)
    for k in "${!TARGETS[@]}"; do
        r=${T_ROW[$k]}
        if [[ -n $r ]]; then T_LOGIN[$k]=${R_LG[r]:-$def}; T_LINE[$k]=${R_LN[r]}; [[ -n ${R_PW[r]} ]] && T_PW[$k]=${R_PW[r]}
        else T_LOGIN[$k]=$def; T_LINE[$k]=default; fi
    done
    for k in "${!BMCS[@]}"; do
        r=${B_ROW[$k]}
        if [[ -n $r ]]; then B_LOGIN[$k]=${R_LG[r]:-$me}; B_PW[$k]=${R_PW[r]}; B_LINE[$k]=${R_LN[r]}
        else B_LOGIN[$k]=$me; B_PW[$k]=; B_LINE[$k]=default; fi
    done
    if (( HAVE_PW )); then
        local p; p=$(ls -ln "$f" | awk '{print $1}')
        [[ ${p:4:6} == ------ ]] || log "WARNING: $f holds passwords and is readable by group or others ($p); chmod 600 it"
    fi
}
