# load_target_file file: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped). type host: an ssh
# target (IP, name, CIDR or range, as FF_HOSTS); bmc: one BMC address read out of band. No login = the current
# user; no pw = key login (host) or an empty password (bmc). The pw is everything after the third comma, verbatim.
# Errors name the line number, never its text (it may hold a password).
load_target_file() {
    local f=$1 line ln=0 ty h lg pw rest n0 k me
    [[ -r $f && -f $f ]] || die "-t: cannot read '$f'"
    me=$(id -un)
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *,* ]] || line="host,$line"   # a bare line is a host with the defaults: a plain host list works
        [[ $line =~ ^[^,]*,[[:space:]]*(#|,*[[:space:]]*$) ]] && continue   # "host,# ...", "host," : commented out or empty
        ty=${line%%,*}; rest=${line#*,}
        h=${rest%%,*}; [[ $rest == *,* ]] && rest=${rest#*,} || rest=
        lg=${rest%%,*}; [[ $rest == *,* ]] && pw=${rest#*,} || pw=
        ty=${ty//[[:space:]]/}; h=${h//[[:space:]]/}; lg=${lg//[[:space:]]/}; lg=${lg:-$me}
        [[ $lg =~ ^[A-Za-z0-9._@-]+$ ]] || die "-t $f line $ln: bad login (letters, digits . _ @ - only)"
        [[ -n $pw ]] && HAVE_PW=1
        case $ty in
            host)
                [[ -n $h ]] || die "-t $f line $ln: no host"
                n0=${#TARGETS[@]}; EXPANDING="-t $f line $ln"
                if [[ -n ${_SEEN[$h]+x} ]]; then   # one host already listed (FF_HOSTS, a range): this line's login/pw win
                    for k in "${!TARGETS[@]}"; do [[ ${TARGETS[$k]} == "$h" ]] && break; done
                    T_LOGIN[$k]=$lg; unset 'T_PW[k]'; [[ -n $pw ]] && T_PW[$k]=$pw; continue
                fi
                expand_entry "$h"
                for (( k = n0; k < ${#TARGETS[@]}; k++ )); do T_LOGIN[$k]=$lg; [[ -n $pw ]] && T_PW[$k]=$pw; done ;;
            bmc)
                is_ip "$h" || [[ $h =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || die "-t $f line $ln: a bmc line takes one IP or hostname (no CIDR or range)"
                BMCS+=("$h"); B_LOGIN+=("$lg"); B_PW+=("$pw") ;;
            *) die "-t $f line $ln: type must be host or bmc" ;;
        esac
    done < "$f"
    if (( HAVE_PW )); then
        local p; p=$(ls -ln "$f" | awk '{print $1}')
        [[ ${p:4:6} == ------ ]] || log "WARNING: $f holds passwords and is readable by group or others ($p); chmod 600 it"
    fi
}
