# NIC_SUM_AWK: one row per data NIC, backends and clients alike (10-25). Columns: Same (backend to backend,
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

# bond_member_deltas label seconds: each bond member's counter changes over the iteration (the bond's own are empty),
# appended to bond_members.txt as "label host bond member speed seconds d_corrected_blocks d_uncorrectable_blocks
# d_corrected_bits d_symbol_errors rx_GB tx_GB rx_share_% tx_share_% d_rx_dropped d_rx_errors d_rx_discards_phy
# d_carrier_down pre_fec_ber flags" (share = of its bond's bytes; flags: uncorrectable, fec_over_limit, fec_watch,
# symbol_errors, rx_errors, discards, carrier_down, slow_link = below the bond's fastest member, idle_member = under 5%
# of a bond that moved 1 GB or more, reset; - = none). A member flagged is named in the log.
bond_member_deltas() {
    : > "$WORK/bmem_delta"
    awk -v t="$1" -v s="$2" -v watch=1e-5 -v limit=2.4e-4 '#@awk ff_bond_members' "$WORK/bmem_pre" "$WORK/bmem_post" > "$WORK/bmem_delta"
    [[ -s $WORK/bmem_delta ]] || return 0
    cat "$WORK/bmem_delta" >> "$COLLECT_DIR/bond_members.txt"
    local nb bad; nb=$(awk '{print $2, $3}' "$WORK/bmem_delta" | sort -u | wc -l | tr -d ' ')
    log "Bond members over ${2}s: $(wc -l < "$WORK/bmem_delta" | tr -d ' ') members of $nb bonds read (bond_members.txt; a bond's own counters are empty)"
    bad=$(awk '$20 != "-" {printf "#   %s %s %s: %s (rx %s%% / tx %s%% of the bond; symbol errors %s, uncorrectable %s, pre-FEC BER %s)\n", $2, $3, $4, $20, $13, $14, $10, $8, $19}' "$WORK/bmem_delta")
    if [[ -n $bad ]]; then
        log "WARNING: bond members flagged in $1 ($(wc -l <<<"$bad" | tr -d ' ')):"
        head -n 10 <<<"$bad" >&2
    fi
    return 0
}

# card_sample [iterN phase]: every NIC card's ports read now (CARD_SCRIPT); with a label and an earlier read, the change
# since that read appended to card_load.txt as "iterN phase host card ports tx_Gbps rx_Gbps slot_Gbps
# link(cur_GTsxW/max_GTsxW) d_rx_discards_phy d_rx_out_of_buffer d_rx_buffer_passed_thres_phy d_tx_pause_ctrl_phy
# d_pcie_errors flags" (a card = the ports on one PCIe device; Gb/s over the phase's run time; slot = the link's
# raw rate after line encoding; flags: near_slot = tx or rx at 80% or more of it, backpressure = the NIC's discard,
# out-of-buffer, buffer-threshold or pause counters rose, pcie_degraded = link below its maximum speed or width,
# pcie_errors = signal-integrity or stall counters rose; - = none). The phase's busiest card is logged, and every
# flagged one.
card_sample() {
    local now; collect_counters "$CARD_SCRIPT" "$WORK/card.cur"; now=$(date +%s)
    if [[ -n $1 && -s $WORK/card.prev ]]; then
        local it=${1%% *} ph=${1#* } secs=$(( now - CARD_T ))
        # the bytes moved between the reads are the phase's own (path checks and counter reads add next to nothing),
        # so the rate is over the phase's run time (phase_start..phase_end), not the longer time between the reads
        [[ -n $PT0S && -n $PT1S ]] && (( PT1S > PT0S && PT0S >= CARD_T )) && secs=$(( PT1S - PT0S ))
        awk -v it="$it" -v ph="$ph" -v s=$(( secs > 0 ? secs : 1 )) -v near=80 '#@awk ff_card_load' \
            "$WORK/card.prev" "$WORK/card.cur" | sort -k3,3 -k4,4 > "$WORK/card.delta"   # by host and card: a tie goes to the first
        if [[ -s $WORK/card.delta ]]; then
            cat "$WORK/card.delta" >> "$COLLECT_DIR/card_load.txt"
            log "  NIC cards in phase $ph ($(wc -l < "$WORK/card.delta" | tr -d ' '); card_load.txt): busiest $(awk '{t = $6 > $7 ? $6 : $7; if (NR == 1 || t > m) {m = t; r =$3 " " $4 " (" $5 "): tx " $6 " / rx " $7 " Gb/s of a " $8 " Gb/s slot"}} END {print r}' "$WORK/card.delta")"
            local bad; bad=$(awk '$15 != "-" {printf "#   %s %s (%s): %s (tx %s / rx %s Gb/s of %s; link %s; discards %s, out-of-buffer %s, buffer threshold %s, pause sent %s, PCIe errors %s)\n", $3, $4, $5, $15, $6, $7, $8, $9, $10, $11, $12, $13, $14}' "$WORK/card.delta")
            [[ -n $bad ]] && { log "  WARNING: NIC cards flagged in phase $ph ($(wc -l <<<"$bad" | tr -d ' ')):"; head -n 10 <<<"$bad" >&2; }
        fi
    fi
    mv "$WORK/card.cur" "$WORK/card.prev"; CARD_T=$now
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
