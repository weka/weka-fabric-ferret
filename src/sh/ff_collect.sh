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

# collect_temps label [ipmi]: TEMP_SCRIPT on every tested host and client, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (source hwmon|ipmi; sensor none = no data, why in status)
collect_temps() {
    (( FF_TEMPS )) || return 0
    local label=$1 mode=-; [[ $2 == ipmi ]] && (( FF_IPMI )) && mode=ipmi
    local out=$WORK/temps.$label k
    : > "$out"
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        rbash "${T_TARGET[$k]}" "$mode" "$FF_IPMI_TIMEOUT" <<<"$TEMP_SCRIPT" >> "$out" 2>> "$RUNLOG_SSH" &
    done
    wait
    awk -v t="$label" 'function c(m) { return m == "-" ? "-" : sprintf("%.1f", m / 1000) }
        $1 == "@@HWMON" { print t, $2, "hwmon", $3, $4, $5, ($5 == "none" ? "-" : c($6)), c($7), c($8), ($5 == "none" ? "no_hwmon_temperature_sensors" : "-") }
        $1 == "@@IPMI" && $3 == "none" { print t, $2, "ipmi", "bmc", "-", "none", "-", "-", "-", $4 }
        $1 == "@@IPMI" && $3 != "none" { print t, $2, "ipmi", "bmc", "-", $3, $4, $6, $7, $5 }' "$out" >> "$COLLECT_DIR/temps.txt"
}

# temp_summary: temps_summary.txt, one row per sensor over the run: "Host Source Type Chip Dev Sensor First_C Max_C
# Last_C High_C Crit_C Flag". Type cpu|nvme|nic|bmc|other. Flag (worst first): crit (at or above crit, or the BMC says
# cr/nr), high (at or above high, or BMC nc), near (within FF_TEMP_MARGIN of high), then +rise (max - first over
# FF_TEMP_RISE); "-" when none. A threshold of 0 counts as unset. A host/source with no reading at all gets one row,
# Sensor none, Flag nodata:<why>.
TEMP_SUM_AWK='
#@awk temp_summary'
temp_summary() {
    (( FF_TEMPS )) || return 0
    awk -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" "$TEMP_SUM_AWK" "$COLLECT_DIR/temps.txt" > "$COLLECT_DIR/temps_summary.txt"
}

# System info per tested host, split into $SI/<host>/<item> (SYSINFO_SCRIPT)
collect_sysinfo() {
    local k f t
    log "System info: capturing on $(( ${#ELIG[@]} + ${#CLI[@]} )) hosts, at most ${FF_SYSINFO_TIMEOUT}s each (bundle: sysinfo/<host>/)..."
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        ( timeout "$FF_SYSINFO_TIMEOUT" ssh "${SSH_OPTS[@]}" "${T_TARGET[$k]}" $SUDO bash -s -- $(host_nics $k) \
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
    awk -v t="$1" 'NR == FNR {p[$1 " " $2] = $3; next}
        ($1 " " $2) in p && $3 ~ /^[0-9]+$/ && $3 > p[$1 " " $2] {print t, $1, $2, $3 - p[$1 " " $2]}' "$2" "$3" > "$WORK/hc_delta"
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
