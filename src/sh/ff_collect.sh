# host_nics k: host k's data NICs ("-" = none on that rail): its rail NICs, or a client's data NICs
host_nics() {
    local k=$1 r
    if [[ -n ${IS_CL[$k]} ]]; then for (( r = 0; r < ${CN[$k]:-0}; r++ )); do echo "${CNIC[$k,$r]}"; done
    else for r in "${RAILS[@]}"; do echo "${RNIC[$k,$r]}"; done; fi
}

collect_counters() {  # script outfile [k...]: run a counter script on every tested host and client (or hosts k...)
    local script=$1 outfile=$2 k; shift 2
    local -a ks=("$@"); (( ${#ks[@]} )) || ks=("${ELIG[@]}" "${CLI[@]}")
    : > "$outfile"
    for k in "${ks[@]}"; do
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$script" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
}

# collect_temps label [ipmi]: thermals_capture.sh's reader on every tested host and client, and hosts with no root
# for the tests, as the login; ipmitool alone escalated inside the reader: root directly, the sweep's escalator, or
# sudo -S with the row's password. Nothing back: a none row per source
collect_temps() {
    (( FF_TEMPS )) || return 0
    local label=$1 mode=- ipmi=0 k i j n t o rc why last lim=$(( FF_IPMI_TIMEOUT + 30 )); local -a tgt=() hn=() e=()
    [[ $2 == ipmi ]] && (( FF_IPMI )) && { mode=ipmi; ipmi=1; }
    local out=$WORK/temps.$label
    for k in "${ELIG[@]}" "${CLI[@]}"; do tgt+=("${T_TARGET[$k]}"); hn+=("${T_HOST[$k]}"); done
    for i in "${UNUSE_I[@]}"; do tgt+=("${TARGETS[$i]}"); hn+=(-); done   # temperatures only: the reader names the host
    for n in "${!tgt[@]}"; do
        t=${tgt[n]}; o=$out.$n
        if [[ ${TESC[$t]-} == S && -z ${TPW[$t]+x} ]]; then : > "$o"; : > "$o.err"; echo nopw > "$o.rc"; continue; fi
        {   if [[ ${TESC[$t]-} == S ]]; then   # the password ahead of the reader on stdin (printf: a builtin, no argv)
                { printf 'IFS= read -r TC_PW\n%s\n' "${TPW[$t]}"; printf '%s\n' "$TEMP_SCRIPT"; } | rlogin_bash -T "$lim" "$t" "$mode" "$FF_IPMI_TIMEOUT"
                rc=${PIPESTATUS[1]}
            else e=(); [[ -n ${TESC[$t]-} ]] && e=("${TESC[$t]// /_}"); [[ ${hn[n]} == - ]] && e=(none)   # none: the sweep found no escalator
                rlogin_bash -T "$lim" "$t" "$mode" "$FF_IPMI_TIMEOUT" "${e[@]}" <<<"$TEMP_SCRIPT"; rc=$?; fi
            echo "$rc" > "$o.rc"; } > "$o" 2> "$o.err" &
    done
    for j in "${!BMCS[@]}"; do
        (( ipmi )) && [[ -n $LOCAL_IPMITOOL ]] || break
        { rbmc "$j" > "$out.bmc$j" 2>&1; echo $? > "$out.bmc$j.rc"; } &
    done
    wait
    for n in "${!tgt[@]}"; do
        o=$out.$n; rc=$(cat "$o.rc" 2>&1); cat "$o.err" >> "$RUNLOG_SSH"
        last=$(awk 'NF && !/^Warning: Permanently added/ {l = $0} END {printf "%s", l}' "$o.err" | tr -d '\r' | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)
        case $rc in
            0) why=no_output ;;
            nopw) why=no_password_in_memory ;;
            124) why=ssh_cut_off_after_${lim}s ;;
            255) why=ssh_failed_${last:-rc255_no_message} ;;
            *) why=remote_rc=${rc}_$last ;;
        esac
        if [[ ${hn[n]} == - ]]; then   # a temperatures-only host: its name from the reader, else the target
            hn[n]=$(awk '$1 ~ /^@@(HWMON|IPMI|GPU)$/ {print $2; exit}' "$o"); hn[n]=${hn[n]:-${tgt[n]}}
            echo "${hn[n]}" >> "$WORK/temps_only"
        fi
        awk -v t="$label" -v host="${hn[n]}" -v why="$why" -v ipmi="$ipmi" '#@awk tc_sample' "$o"
    done >> "$COLLECT_DIR/temps.txt"
    (( ipmi )) || return 0
    for j in "${!BMCS[@]}"; do
        if [[ -z $LOCAL_IPMITOOL ]]; then echo "$label ${BMCS[$j]} ipmi bmc lanplus none - - - ipmitool_not_installed_here"; continue; fi
        awk -v t="$label" -v h="${BMCS[$j]}" -v rc="$(cat "$out.bmc$j.rc" 2>&1)" -v to="$FF_IPMI_TIMEOUT" "$BMC_AWK" "$out.bmc$j"
    done >> "$COLLECT_DIR/temps.txt"
}

# temp_summary: temps_summary.txt from temps.txt (summarize_temps, tc_summary.sh: seven types, flags, Min_C); the
# bundle's temps.txt stays as read, the high = 95% of crit copy is work only
temp_summary() {
    (( FF_TEMPS )) || return 0
    summarize_temps "$COLLECT_DIR/temps.txt" "$WORK/temps.hi" "$COLLECT_DIR/temps_summary.txt"
    # the hosts read for temperatures only (no root for the tests), one name a line
    [[ -s $WORK/temps_only ]] && sort -u "$WORK/temps_only" > "$COLLECT_DIR/temps_only.txt"
    return 0
}

# System info per tested host, split into $SI/<host>/<item> (SYSINFO_SCRIPT)
collect_sysinfo() {
    local k f t
    log "System info: capturing on $(( ${#ELIG[@]} + ${#CLI[@]} )) hosts, at most ${FF_SYSINFO_TIMEOUT}s each (bundle: sysinfo/<host>/)..."
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        ( rbash -T "$FF_SYSINFO_TIMEOUT" "${T_TARGET[$k]}" $(host_nics $k) \
              <<<"$SYSINFO_SCRIPT" > "$WORK/si.$k" 2>> "$RUNLOG_SSH"; echo $? > "$WORK/si_rc.$k" ) &
    done
    wait
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        f=$WORK/si.$k
        if ! grep -q '^=== SYSINFO ' "$f"; then log "WARNING: ${T_HOST[$k]}: no system info captured (see ssh_errors.log)"; continue; fi
        if [[ $(cat "$WORK/si_rc.$k") == 124 ]]; then
            log "WARNING: ${T_HOST[$k]}: system info cut off after ${FF_SYSINFO_TIMEOUT}s (FF_SYSINFO_TIMEOUT); the partial capture is kept"
            SI_CUT[${T_HOST[$k]}]=1
        fi
        t=$(awk '/^=== SYSINFO / {s = $3} /^n\/a: .* timed out after/ {printf "%s%s", c, s; c = " "}' "$f")
        [[ -n $t ]] && log "WARNING: ${T_HOST[$k]}: system info items timed out: $t"
        mkdir -p "$SI/${T_HOST[$k]}"
        awk -v d="$SI/${T_HOST[$k]}" '/^=== SYSINFO [^ \/]+ ===$/ {if (o) close(o); o = d "/" $3; next} o {print > o}' "$f"
    done
}

# Rail NIC receive config from the sysinfo capture: "host rail numa ring_cur/max pcie_GTs x width cur/max"
rx_config() {
    local k r
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RNIC[$k,$r]} != - ]] && rx_one "${T_HOST[$k]}" "$(rail_letter $r)" "$SI/${T_HOST[$k]}/nic-${RNIC[$k,$r]}"
    done; done
    return 0
}

rx_one() {  # host slot sysinfo_nic_file: one rx config line (slot: rail letter, or a client's NIC number)
    [[ -f $3 ]] || return 0
    awk -v h="$1" -v r="$2" '
            $1 == "numa_node" { numa = $2 }
            $1 ~ /^(current|max)_link_(speed|width)$/ { v = $2; sub(/[^0-9.].*/, "", v); L[$1] = v }
            /^--- / { sec = $3; g = "" }
            sec == "-g" && /^Pre-set maximums/ { g = "max" }
            sec == "-g" && /^Current hardware/ { g = "cur" }
            sec == "-g" && $1 == "RX:" && g != "" && !(g in R) { R[g] = $2 }
            END { ring = ("cur" in R && "max" in R) ? R["cur"] "/" R["max"] : "-"
                  pc = (L["current_link_speed"] != "" && L["max_link_speed"] != "") ? \
                       L["current_link_speed"] "x" L["current_link_width"] "/" L["max_link_speed"] "x" L["max_link_width"] : "-"
                  print h, r, (numa ~ /^-?[0-9]+$/ ? numa : "-"), ring, pc }' "$3"
}

# hostctr_delta label pre post: receive counters that rose -> host_counters.txt "label host key delta"
hostctr_delta() {
    awk -v t="$1" '#@awk ff_hostctr_delta' "$2" "$3" > "$WORK/hc_delta"
    cat "$WORK/hc_delta" >> "$COLLECT_DIR/host_counters.txt"
    # who answered this read, and with AER counters: a counter never read shows as "-" in host_rx.txt, not 0
    awk '{n[$1]++; if ($2 ~ /^aer_/) a[$1] = 1} END {for (h in n) print h, ((h in a) ? 1 : 0)}' "$3" >> "$WORK/hc_reads"
    HC_READS=$(( HC_READS + 1 ))
}

# hc_log what snapshot: one line on the receive drop counters in $WORK/hc_delta (squeezes stay in the table only)
hc_log() {
    local hd; hd=$(awk '$3 ~ /^(softnet_dropped|TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop|TCPMemoryPressures|aer_)/' "$WORK/hc_delta" | sort -k4 -rn)
    if [[ -n $hd ]]; then
        log "  Host receive drops in $1 ($(echo "$hd" | wc -l | tr -d ' ') counters rose; top 5): $(echo "$hd" | head -n 5 | awk '{printf "%s%s %s +%d", s, $2, $3, $4; s = "; "}')"
    else log "  No host receive drop counter rose in $1 ($(wc -l < "$2" | tr -d ' ') counters read)"; fi
}

# Kernel log per host since its own sysinfo epoch -> $SI/<host>/kernel-log
collect_klog() {
    local k e
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        e=$(cat "$SI/${T_HOST[$k]}/epoch" 2>&1); [[ $e =~ ^[0-9]+$ ]] || continue
        throttle
        rbash "${T_TARGET[$k]}" "$e" <<<"$KLOG_SCRIPT" > "$SI/${T_HOST[$k]}/kernel-log" 2>> "$RUNLOG_SSH" &
    done
    wait
}
