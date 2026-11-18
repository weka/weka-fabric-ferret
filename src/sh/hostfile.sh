# Every FF_* setting each tool reads (shared here so each can name the other's). Any other FF_* in the environment
# is a typo that would be silently ignored (a dropped letter, say), so fabric_ferret.sh stops the run on one
# (check_settings); both tools stop on one in a -t file's settings lines. A regress test keeps FF_KNOWN complete.
FF_KNOWN="FF_BUSY_CHECK FF_BUSY_OK FF_CLIENT_GBPS FF_CLIENT_NETS FF_CLIENT_NICS FF_CLIENT_RATIO FF_CLIENT_SPINE_GBPS FF_CLIENT_SPINE_LINKS FF_CLIENTS FF_CROSS_MAX FF_CROSS_RAIL FF_DURATION FF_EXPECT_CLIENTS FF_EXPECT_HOSTS FF_FERRET FF_HOSTS FF_IGNORE_LOCK FF_ITER FF_LABEL FF_LINE_GBPS FF_LLDP FF_LOCK_FILE FF_MAX_TARGETS FF_MESH FF_NICS FF_OK_PCT FF_OUT_DIR FF_PORT FF_RAILS FF_RDMA FF_RETR_PCT FF_RUNLOG FF_SKIP_IPERF FF_SLOW_PCT FF_SPINE_GBPS FF_SPINE_LINKS FF_SPINES FF_SSH_PARALLEL FF_SSH_RETRY_PARALLEL FF_SSH_USER FF_STREAMS FF_SYSFS FF_PROCFS FF_PROCNET FF_VIEWER FF_SYSINFO_TIMEOUT FF_TEMP_MARGIN FF_TEMP_RISE FF_TEMPS FF_THERMALS_ONLY FF_IPMI FF_IPMI_TIMEOUT FF_TOS FF_UDP FF_UDP_CONFIRM FF_UDP_CONFIRM_PCT FF_UDP_DURATION FF_PW_PROMPT"
TC_KNOWN="FF_HOSTS FF_SSH_USER FF_SSH_PARALLEL FF_MAX_TARGETS FF_IPMI FF_IPMI_TIMEOUT FF_TEMP_MARGIN FF_TEMP_RISE FF_LABEL FF_OUT_DIR FF_SYSFS FF_PROCFS FF_FERRET FF_VIEWER FF_PW_PROMPT"

# load_settings_lines file: a -t file's "FF_<setting>=value" lines (whole line, value verbatim), run once, first, by
# each tool, which exports what it sets (HF_SET): as on the command line. HF_ENV's names win (noted in HF_PRELOG);
# other tool's names skipped; bad names die by line, value unprinted.
load_settings_lines() {
    local f=$1 line ln=0 nm val; local -a skipped=()
    HF_SET=; HF_PRELOG=()
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(FF_[A-Z0-9_]+)[[:space:]]*=(.*)$ ]] || continue
        nm=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; val=${val#"${val%%[![:space:]]*}"}
        [[ $nm != FF_PW_PROMPT && $nm =~ PASS|PW|SECRET|TOKEN ]] && die "-t $f line $ln: $nm looks like a credential; a password goes in a row's pw field, never in a setting"
        [[ $nm == FF_HOSTS || $nm == FF_CLIENTS ]] && die "-t $f line $ln: $nm is not a setting here; list the targets as rows"
        if [[ " $HF_KNOWN " == *" $nm "* ]]; then
            if [[ " $HF_ENV " == *" $nm "* ]]; then HF_PRELOG+=("-t $f line $ln: $nm is set in the environment; the file's value is ignored")
            else
                printf -v "$nm" '%s' "$val"; HF_SET+="$nm "
                # the rows below expand against FF_MAX_TARGETS, so a file value is checked here, not after the load
                [[ $nm == FF_MAX_TARGETS ]] && { [[ $val =~ ^[0-9]+$ ]] && (( val > 0 )) || die "-t $f line $ln: FF_MAX_TARGETS must be a positive integer"; }
            fi
        elif [[ " $HF_OTHER " == *" $nm "* ]]; then skipped+=("$nm")
        else die "-t $f line $ln: unknown setting $nm; this tool reads: ${HF_KNOWN// /, }"; fi
    done < "$f"
    (( ${#skipped[@]} )) && HF_PRELOG+=("-t $f: ${#skipped[@]} setting line(s) for $HF_OTHER_NAME skipped: ${skipped[*]}")
    return 0
}

# settings_prepass file: each tool's first step with a -t file, before anything reads a setting: HF_ENV from the
# environment, the file's settings lines, every value taken exported (children see it). Its notes wait in
# HF_PRELOG for main's first log lines (run log and viewer get them).
settings_prepass() {
    local nm
    HF_PRELOG=()
    [[ -r $1 && -f $1 ]] || die "-t: cannot read '$1'"
    HF_ENV=" $(compgen -e | awk '/^FF_/ {printf "%s ", $0}')"
    load_settings_lines "$1"
    for nm in $HF_SET; do export "$nm"; done
}

# hf_row line: one -t row's fields, as load_target_file and pw_prompts both read them (one split, so the two cannot
# differ): HF_TY (lower case) HF_H HF_LG (ends trimmed) HF_PW (verbatim). Returns 1 for a line that is no row: blank,
# a # comment, a settings line (read by settings_prepass), "host,# ..." or "host," (commented out or empty).
hf_row() {
    local line=${1%$'\r'} rest k
    [[ $line =~ ^[[:space:]]*(#|$) ]] && return 1
    [[ $line =~ ^[[:space:]]*FF_[A-Z0-9_]+[[:space:]]*= ]] && return 1
    [[ $line == *,* ]] || line="backend,$line"   # a bare line is a backend with the defaults: a plain host list works
    [[ $line =~ ^[^,]*,[[:space:]]*(#|,*[[:space:]]*$) ]] && return 1
    HF_TY=${line%%,*}; rest=${line#*,}
    HF_H=${rest%%,*}; [[ $rest == *,* ]] && rest=${rest#*,} || rest=
    HF_LG=${rest%%,*}; [[ $rest == *,* ]] && HF_PW=${rest#*,} || HF_PW=
    # trim the ends only: a space inside a type, host or login is bad input, refused by the caller with its line number
    for k in HF_TY HF_H HF_LG; do local -n v=$k; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; unset -n v; done
    HF_TY=${HF_TY,,}
    return 0
}

# ---------- passwords asked on the terminal: --pw-prompt, FF_PW_PROMPT=1, or a -t row whose pw is ? ----------
# PW_ASK holds each password asked, in memory only (an unexported shell variable: never in a file, argv or the
# environment), keyed ssh:<login> (the ? rows of that login), bmc:<user> (the ? bmc rows of that BMC user) and all
# (--pw-prompt / FF_PW_PROMPT=1: every ssh target whose credential gives no password). Only a pw of exactly ? asks;
# ?abc or " ?" is a password as written. PW_NOASK=1 (--list, --help): nothing is asked and nothing reaches ssh.
declare -A PW_ASK=(); PW_NOASK=0
# pw_prompts tfile all: each tool's top level runs it before main, the run log and the viewer, so the prompts are on
# the terminal alone: one per key, read from /dev/tty without echo. No terminal, an empty password or end of input
# stops the run (rc 2), before any ssh.
pw_prompts() {
    local f=$1 all=$2 def=${FF_SSH_USER:-$(id -un)} me=$(id -un) line k label pw rc err
    local -a need=(); local -A seen=()
    if [[ -n $f && -r $f && -f $f ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            hf_row "$line" && [[ $HF_PW == '?' ]] || continue
            if [[ $HF_TY == bmc ]]; then k=bmc:${HF_LG:-$me}; else k=ssh:${HF_LG:-$def}; fi
            [[ -n ${seen[$k]} ]] || { seen[$k]=1; need+=("$k"); }
        done < "$f"
    fi
    (( all )) && need+=(all)
    (( ${#need[@]} && ! PW_NOASK )) || return 0
    err=$( { : < /dev/tty; } 2>&1 ) || die "a password prompt (--pw-prompt, FF_PW_PROMPT=1 or a -t pw of ?) needs a terminal, and there is none (${err##*: })"
    for k in "${need[@]}"; do
        case $k in
            ssh:*) label="Password for login ${k#ssh:} (the -t rows whose pw is ?): " ;;
            bmc:*) label="BMC password for user ${k#bmc:} (the -t bmc rows whose pw is ?): " ;;
            *)     label="Password for every ssh target with no password of its own (--pw-prompt): " ;;
        esac
        # read -p shows the prompt only once echo is off: a printf first left a window where a password typed at
        # once was echoed (17 of 60 runs under load, 2026-11-18)
        IFS= read -rs -p "$label" pw < /dev/tty 2> /dev/tty; rc=$?
        printf '\n' > /dev/tty
        (( rc == 0 )) || die "no password read (end of input): ${label%% (*}"
        [[ -n $pw ]] || die "empty password: ${label%% (*}"
        PW_ASK[$k]=$pw
    done
    pw=
}
# pw_fill_all: FF_HOSTS targets (no -t rows) under --pw-prompt: the asked password for each target without one (T_PW)
pw_fill_all() {
    local k
    [[ -n ${PW_ASK[all]+x} ]] || return 0
    for k in "${!TARGETS[@]}"; do [[ -n ${T_PW[$k]+x} ]] || T_PW[$k]=${PW_ASK[all]}; done
}

# load_target_file file deflogin: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped; FF_<setting>=value
# lines are settings, read by settings_prepass before, skipped here). type backend
# (host = backend) or client: ssh targets (IP, name, CIDR or range, as FF_HOSTS); bmc: one BMC address read out of
# band. A host field * or a glob (* ? [...], any case) is a credential row: it adds no targets. Type * = backend
# and client, never bmc. Each target takes the most specific row that gives a login or pw: one host > CIDR/range >
# glob > <type>,* > *,* > the default (deflogin, key; a bmc: the current user, empty password). That row is the
# credential, with no fallback. The pw is everything after the third comma, verbatim; exactly ? takes the password
# pw_prompts asked (PW_ASK), and --pw-prompt's gives every target that has none. Errors and warnings name
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
        ln=$(( ln + 1 ))
        hf_row "$line" || continue
        ty=$HF_TY; h=$HF_H; lg=$HF_LG; pw=$HF_PW
        [[ -z $lg || $lg =~ ^[A-Za-z0-9._@-]+$ ]] || die "-t $f line $ln: bad login (letters, digits . _ @ - only)"
        [[ $ty == host ]] && ty=backend
        if [[ $pw == '?' ]]; then   # asked on the terminal (pw_prompts, run first); the file holds no password
            if [[ $ty == bmc ]]; then k=bmc:${lg:-$me}; else k=ssh:${lg:-$def}; fi
            if [[ -n ${PW_ASK[$k]+x} ]]; then pw=${PW_ASK[$k]}
            elif (( ! PW_NOASK )); then die "-t $f line $ln: pw ? but no password was asked for it"; fi   # --list, --help: pw stays ?, unused
        elif [[ -n $pw ]]; then HAVE_PW=1; fi
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
        [[ -z ${T_PW[$k]+x} && -n ${PW_ASK[all]+x} ]] && T_PW[$k]=${PW_ASK[all]}   # --pw-prompt: every target without one
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
