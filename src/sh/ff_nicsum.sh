# NIC_SUM_AWK: one row per data NIC, backends and clients alike (Frank 10-25). Columns: Same (backend to backend,
# same rail), Cross (rail to rail), CB_Out / CB_In (client<->backend waves, this NIC sending / receiving), All_Out /
# All_In (the all-at-once phase). Each run is judged at its expected rate: its rail's line (Cross: the slower rail's),
# a client run min(client line, backend rail line / flows sharing that backend NIC). Status: each column's average
# share of expected, worst; (cross) = only Cross is that bad. Retr: TCP retransmits over the runs this NIC sent;
# Retr_%: of the segments it sent (bytes / (MTU - 52)); (retr) when above rl (FF_RETR_PCT). A NIC with no runs shows
# its rail state (no address, link down) or no_result. Files: data NIC map (key role host nic rail line_gbps mtu
# state; key = ip, or none_<host>_<rail> without one), backend results, client results. Prints a sort key first.
NIC_SUM_AWK='
#@awk ff_nic_sum'

# client_summary: per client data NIC, its runs each way judged at min(client line, backend rail line / share)
# Files: client map (ip host nic line_gbps), rail map (ip host rail), client results.
CLIENT_SUM_AWK='
#@awk ff_client_sum'

# fec_deltas label seconds: per-NIC FEC counter changes over the iteration, appended to
# fec_rates.txt as "label host_nic seconds d_corrected_blocks d_uncorrectable_blocks d_corrected_bits d_symbol_errors"
# (na = not exposed, reset = counter went backwards). Links carry symbols even when idle, so wall time is the right base.
fec_deltas() {
    awk -v t="$1" -v s="$2" '#@awk ff_fec_deltas' "$WORK/fec_pre" "$WORK/fec_post" > "$WORK/fec_delta"
    cat "$WORK/fec_delta" >> "$COLLECT_DIR/fec_rates.txt"
    local seen unc off
    seen=$(awk '$4 ~ /^[0-9]+$/ || $6 ~ /^[0-9]+$/' "$WORK/fec_delta" | wc -l | tr -d ' ')
    off=$(awk '$4 == "off"' "$WORK/fec_delta" | wc -l | tr -d ' ')
    unc=$(awk '$5 ~ /^[0-9]+$/ && $5 > 0 {printf "%s(%s) ", $2, $5}' "$WORK/fec_delta")
    log "FEC over ${2}s: counters exposed on $seen of $(wc -l < "$WORK/fec_delta" | tr -d ' ') rail NICs$( (( off )) && echo "; FEC off on $off")"
    [[ -n $unc ]] && log "WARNING: uncorrectable FEC blocks (errors reach the host): $unc"
    return 0
}

collect_drops() {  # outfile [k...]
    local outfile=$1 k; shift
    local -a ks=("$@"); (( ${#ks[@]} )) || ks=("${ELIG[@]}" "${CLI[@]}")
    : > "$outfile"
    for k in "${ks[@]}"; do
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$DROPS_SCRIPT" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
    sort -o "$outfile" "$outfile"
}

compute_drops() {
    awk -v label="$3" '#@awk ff_compute_drops' "$1" "$2"
}
