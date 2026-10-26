# ---------- collection ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
wait_all() { while [[ -n $(jobs -rp) ]]; do wait; done; }   # a trapped Ctrl-C ends a bare wait early
tmo() { if [[ -n $TO ]]; then "$TO" "$HOST_LIMIT" "$@"; else "$@"; fi; }
clean() { printf '%s' "${1//$'\r'/}" | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80; }   # ssh ends its errors with \r\n

# sample n: TEMP_SCRIPT on every target at once, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (sensor none = no data, why in status).
# A target with no answer at all gets a none row per source, the reason from ssh's exit code and last error line.
# rssh i: ssh to target i as its login, with its password from the environment when it has one (sshpass -e, else
# SSH_ASKPASS), never on a command line. Runs in its own background subshell, so the exports stay there.
rssh() {
    local i=$1; shift
    local -a o=("${SSH_OPTS[@]}" -l "${T_LOGIN[$i]}")
    if [[ -z ${T_PW[$i]+x} ]]; then tmo ssh "${o[@]}" -o BatchMode=yes "${TARGETS[$i]}" "$@"; return; fi
    o+=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
    if [[ -n $SSHPASS_CMD ]]; then export SSHPASS=${T_PW[$i]}; tmo "$SSHPASS_CMD" -e ssh "${o[@]}" "${TARGETS[$i]}" "$@"
    else export THERMCAP_PW=${T_PW[$i]} SSH_ASKPASS=$WORK/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none}
        tmo ssh "${o[@]}" "${TARGETS[$i]}" "$@"; fi
}

# rbmc j: the BMC's sensors out of band from here (ipmitool lanplus), the password in IPMI_PASSWORD (-E)
rbmc() {
    local j=$1
    export IPMI_PASSWORD=${B_PW[$j]}
    if [[ -n $TO ]]; then "$TO" "$FF_IPMI_TIMEOUT" ipmitool -I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}" -E sensor <<<""
    else ipmitool -I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}" -E sensor <<<""; fi
}

# ipmitool sensor output -> temps rows for one BMC (as the reader's @@IPMI lines), or one none row with the reason
BMC_AWK='#@awk tc_bmc'

sample() {
    local n=$1 lab=s$1 i o rc why host j
    echo "$lab $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/samples"
    for i in "${!TARGETS[@]}"; do
        throttle
        # a password login's password rides ahead of the reader on stdin (printf is a builtin: no argv, no temp file);
        # bash -s reads the script a line at a time, so the first line's read takes the second line
        { { [[ -n ${T_PW[$i]+x} ]] && printf 'IFS= read -r TC_PW\n%s\n' "${T_PW[$i]}"; printf '%s\n' "$TEMP_SCRIPT"; } \
              | rssh "$i" bash -s -- "$MODE" "$FF_IPMI_TIMEOUT" > "$WORK/o.$n.$i" 2> "$WORK/e.$n.$i"
          echo "${PIPESTATUS[1]}" > "$WORK/rc.$n.$i"; } &
    done
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
        # a target that took no connection: set aside, silent unless -v (see unreachable_targets)
        if [[ $rc == 255 ]] && grep -qE "$NO_CONNECT_RE" "$WORK/e.$n.$i"; then
            echo "$n ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")")" >> "$WORK/unreach.$i"; continue
        fi
        echo "$n ${TARGETS[$i]} $host host ${T_LOGIN[$i]} $( [[ -n ${T_PW[$i]+x} ]] && echo password || echo key)" >> "$WORK/hosts"
        case $rc in
            0) why=no_output ;;
            124) why=ssh_cut_off_after_${HOST_LIMIT}s ;;
            255) why=ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")") ;;
            *) why=remote_rc=${rc}_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")") ;;
        esac
        awk -v t="$lab" -v host="$host" -v why="$why" -v ipmi="$([[ $MODE == ipmi ]] && echo 1 || echo 0)" '
            function c(m) { return m == "-" ? "-" : sprintf("%.1f", m / 1000) }
            $1 == "@@HWMON" { hw = 1; print t, $2, "hwmon", $3, $4, $5, ($5 == "none" ? "-" : c($6)), c($7), c($8), ($5 == "none" ? "no_hwmon_temperature_sensors" : "-") }
            $1 == "@@GPU" && $3 == "none" { print t, $2, "gpu", "nvidia", "-", "none", "-", "-", "-", $4 }
            $1 == "@@GPU" && $3 != "none" { print t, $2, "gpu", "nvidia", $3, $4, sprintf("%.1f", $5), $6, $7, "-" }
            $1 == "@@IPMI" { im = 1 }
            $1 == "@@IPMI" && $3 == "none" { print t, $2, "ipmi", "bmc", "-", "none", "-", "-", "-", $4 }
            $1 == "@@IPMI" && $3 != "none" { print t, $2, "ipmi", "bmc", "-", $3, $4, $6, $7, $5 }
            END { if (!hw) print t, host, "hwmon", "-", "-", "none", "-", "-", "-", why
                  if (ipmi && !im) print t, host, "ipmi", "bmc", "-", "none", "-", "-", "-", why }' "$o" >> "$WORK/temps.txt"
    done
}
