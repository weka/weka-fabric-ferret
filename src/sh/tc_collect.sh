# ---------- collection ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
wait_all() { while [[ -n $(jobs -rp) ]]; do wait; done; }   # a trapped Ctrl-C ends a bare wait early
tmo() { tmo_s "$HOST_LIMIT" "$@"; }   # tmo_s: tc_bmc.sh
clean() { printf '%s' "${1//$'\r'/}" | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80; }   # ssh ends its errors with \r\n

# sample n: TEMP_SCRIPT on every target at once, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (sensor none = no data, why in status).
# A target with no answer at all gets a none row per source, the reason from ssh's exit code and last error line.
# (write_askpass and pwfifo: src/sh/auth.sh, shared with fabric_ferret.sh)
# rssh i: ssh to target i as its login; a password login reads its password through the askpass helper from a fifo,
# never from an environment variable or a command line. Runs in its own background subshell.
rssh() {
    local i=$1 rc; shift
    local -a o=("${SSH_OPTS[@]}" -l "${T_LOGIN[$i]}")
    if [[ -z ${T_PW[$i]+x} ]]; then tmo ssh "${o[@]}" -o BatchMode=yes "${TARGETS[$i]}" "$@"; return; fi
    o+=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
    pwfifo "t$i.$BASHPID" "${T_PW[$i]}" || return 255
    THERMCAP_PW_FIFO=$PWFIFO SSH_ASKPASS=$AUTH/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none} \
        tmo $SETSID ssh "${o[@]}" "${TARGETS[$i]}" "$@"; rc=$?
    exec 4>&-; rm -f "$PWFIFO" "$PWFIFO.used"; return $rc
}

# rbmc and BMC_AWK (the BMC out of band): tc_bmc.sh, shared with fabric_ferret.sh

# read_target n i: the reader on target i for sample n, in the background (o/e/rc.n.i)
read_target() {
    local n=$1 i=$2 esc=
    # a password login's password rides ahead of the reader on stdin (printf is a builtin: no argv, no temp file);
    # bash -s reads the script a line at a time, so the first line's read takes the second line
    # the escalator an earlier sample found on this host (esc.<i>) skips the probe: one probe per host per run
    [[ -r $WORK/esc.$i ]] && esc=$(<"$WORK/esc.$i")
    { { [[ -n ${T_PW[$i]+x} ]] && printf 'IFS= read -r TC_PW\n%s\n' "${T_PW[$i]}"; printf '%s\n' "$TEMP_SCRIPT"; } \
          | rssh "$i" bash -s -- "$MODE" "$FF_IPMI_TIMEOUT" "$esc" > "$WORK/o.$n.$i" 2> "$WORK/e.$n.$i"
      echo "${PIPESTATUS[1]}" > "$WORK/rc.$n.$i"; } &
}
# refusals under fan-out look like dead hosts (sshd MaxStartups, kex resets, a control master that died as it opened):
# those targets get one more try, 8 at a time (as fabric_ferret.sh's sweep does)
RETRY_RE='Failed to connect to new control master|Connection reset|kex_exchange_identification|ssh_exchange_identification|Connection closed by|too many'
sample() {
    local n=$1 lab=s$1 i o rc why host j
    echo "$lab $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/samples"
    for i in "${!TARGETS[@]}"; do throttle; read_target "$n" "$i"; done
    wait_all
    local -a retry=()
    for i in "${!TARGETS[@]}"; do
        [[ $(<"$WORK/rc.$n.$i") == 255 ]] && grep -qiE "$RETRY_RE" "$WORK/e.$n.$i" && retry+=("$i")
    done
    if (( ${#retry[@]} )); then
        local keep=$FF_SSH_PARALLEL rec=0; FF_SSH_PARALLEL=8
        for i in "${retry[@]}"; do throttle; mv -f "$WORK/e.$n.$i" "$WORK/e1.$n.$i"; read_target "$n" "$i"; done
        wait_all; FF_SSH_PARALLEL=$keep
        for i in "${retry[@]}"; do [[ $(<"$WORK/rc.$n.$i") == 255 ]] || rec=$(( rec + 1 )); done
        log "sample $n: ${#retry[@]} target(s) refused ssh under load (control master, reset, kex); retried 8 at a time, recovered $rec"
    fi
    for j in "${!BMCS[@]}"; do
        [[ -n $LOCAL_IPMITOOL ]] || break
        throttle
        { rbmc "$j" > "$WORK/b.$n.$j" 2>&1; echo $? > "$WORK/brc.$n.$j"; } &
    done
    wait_all
    for j in "${!BMCS[@]}"; do
        echo "$n ${BMCS[$j]} ${BMCS[$j]} bmc ${B_LOGIN[$j]} $( [[ -n ${B_PW[$j]} ]] && echo password || echo none)" >> "$WORK/hosts"
        if [[ -z $LOCAL_IPMITOOL ]]; then
            echo "$lab ${BMCS[$j]} ipmi bmc lanplus none - - - ipmitool_not_installed_here"; continue
        fi
        awk -v t="$lab" -v h="${BMCS[$j]}" -v rc="$(cat "$WORK/brc.$n.$j" 2>&1)" -v to="$FF_IPMI_TIMEOUT" "$BMC_AWK" "$WORK/b.$n.$j"
    done >> "$WORK/temps.txt"
    for i in "${!TARGETS[@]}"; do
        o=$WORK/o.$n.$i; rc=$(cat "$WORK/rc.$n.$i" 2>&1)
        host=$(awk '$1 ~ /^@@(HWMON|IPMI)$/ {print $2; exit}' "$o")
        if [[ -n $host ]]; then : > "$WORK/answered.$i"; else host=${TARGETS[$i]}; fi
        [[ -e $WORK/esc.$i ]] || awk '$1 == "@@ESC" {print $3; exit}' "$o" > "$WORK/esc.$i.new"
        [[ -s $WORK/esc.$i.new ]] && mv -f "$WORK/esc.$i.new" "$WORK/esc.$i"; rm -f "$WORK/esc.$i.new"
        # a target that took no connection: set aside, silent unless -v (see unreachable_targets)
        if [[ $rc == 255 ]] && grep -qE "$NO_CONNECT_RE" "$WORK/e.$n.$i"; then
            echo "$n ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")")" >> "$WORK/unreach.$i"; continue
        fi
        echo "$n ${TARGETS[$i]} $host ${T_TYPE[$i]:-backend} ${T_LOGIN[$i]} $( [[ -n ${T_PW[$i]+x} ]] && echo password || echo key)" >> "$WORK/hosts"
        case $rc in
            0) why=no_output ;;
            124) why=ssh_cut_off_after_${HOST_LIMIT}s ;;
            255) why=ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")"); [[ $why == ssh_failed_ ]] && why=ssh_failed_rc255_no_message ;;
            *) why=remote_rc=${rc}_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")") ;;
        esac
        awk -v t="$lab" -v host="$host" -v why="$why" -v ipmi="$([[ $MODE == ipmi ]] && echo 1 || echo 0)" '#@awk tc_sample' "$o" >> "$WORK/temps.txt"
    done
}
