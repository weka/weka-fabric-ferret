# cross_summary ipmap results: the inter-rail total (an iteration's cross-rail runs share the path between
# the rails at once) and, when only cross-rail runs miss the OK cut-off, where to look.
cross_summary() {
    local x xm am bm
    x=$(awk -F'[, ]+' '#@awk ff_cross_summary.flows' "$1" "$2")
    [[ $x == *'>'* ]] || return 0
    awk -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v cm="${FF_CROSS_MAX:-0}" '#@awk ff_cross_summary' <<<"$x"
}

# uplink_summary ipmap lldp nicdiag results: per leaf (its LLDP neighbour) and phase, the runs that cross
# to another leaf, out by the source's leaf and in by the destination's. With FF_SPINES/FF_SPINE_LINKS/
# FF_SPINE_GBPS, judged against C = spines x links x Gbps per direction. NICs without LLDP stay out.
UPLINK_AWK='
#@awk ff_uplink'

# uplink_summary [client] ipmap lldp nicdiag results: "client" = the client runs, each leaf judged by its side
uplink_summary() {
    local mode=; [[ $1 == client ]] && { mode=client; shift; }
    awk -F'[, ]+' -v mode="$mode" -v C="${UPLINK_GBPS:-0}" -v CC="${CL_UPLINK_GBPS:-0}" -v N="$FF_SPINES" -v M="$FF_SPINE_LINKS" -v S="$FF_SPINE_GBPS" \
        -v CM="$FF_CLIENT_SPINE_LINKS" -v CS="$FF_CLIENT_SPINE_GBPS" -v lines="$RAIL_LINES" -v cgb="${FF_CLIENT_GBPS:-0}" \
        -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT" "$UPLINK_AWK" "$@"
}

# xgroup_summary ipmap results: phase 3 per rail pair (both groups' rails): flows, average, median, OK/SLOW/CRITICAL
# against the exp: each run carries
xgroup_summary() {
    awk -F'[, ]+' -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT" '#@awk ff_xgroup_summary' "$1" "$2"
}

# UDP phases U1 (same rail), U2 (cross) and U3 (cross-group, when group pairs exist) on the current pairs, with host
# and NIC counters read around each phase so lost datagrams can be placed.
udp_phases() {
    local u p ck sk a=$WORK/udp.0 stale=0
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"
    for u in 1 2 3; do
        PHASE=U$u; PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
        if [[ $u == 2 && $CROSS != on ]]; then log "Phase U2: skipped (cross-rail $CROSS)"; phase_skip U2; continue; fi
        [[ $u == 3 ]] && (( ${#XGL[@]} == 0 )) && continue
        # confirm runs came after the last phase's counters were read: read them again, or this phase is charged their traffic
        (( stale )) && { collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"; stale=0; }
        phase_start
        if [[ $u == 1 ]]; then log "Phase U1: UDP $(same_desc) at once (-b 0), start $PT0"
        elif [[ $u == 2 ]]; then log "Phase U2: UDP cross-rail, $(cross_desc) at once (-b 0), start $PT0"
        else log "Phase U3: UDP cross-group, each rail pair both ways (-b 0), start $PT0"; fi
        echo "### iteration:${ITER} phase:${PHASE}" >> "$UDP_RESULTS"
        if [[ $u == 1 ]]; then
            for (( p = 0; p < ${#PC[@]}; p++ )); do p1_paths $p run udp; done
            wait
        elif [[ $u == 2 ]]; then xwaves "$UDP_RESULTS" udp
        else xg_waves "$UDP_RESULTS" udp; fi
        phase_end $PHASE
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        local errs b=$WORK/udp.$u; errs=$(grep -c ',ERROR' "$PHASE_OUT")
        (( errs > 0 )) && { log "WARNING: $errs UDP runs in phase $PHASE returned no result (lines with ERROR above):"; log_hist "$PHASE_OUT"; }
        collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"; collect_counters "$TXCTR_SCRIPT" "$b.tx"
        collect_temps "iter${ITER}_$PHASE"
        udp_close $PHASE "$a" "$b"
        a=$b; stale=$UDP_CONFIRMED
    done
}

# udp_close phase pre post: the phase's host and NIC counter deltas, appended to udp_host_counters.txt
# ("iterN phase host dInErrors dRcvbufErrors dSndbufErrors dSoftnet") and udp_nic_drops.txt ("iterN phase host_nic drx doob"),
# then its confirm runs, if its loss calls for them (udp_confirm; UDP_CONFIRMED=1 then), and its loss lines
udp_close() {
    local ph=$1 a=$2 b=$3 r at; UDP_CONFIRMED=0
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.counters' \
        "$a.host" "$b.host" >> "$COLLECT_DIR/udp_host_counters.txt"
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.nic' "$a.nic" "$b.nic" >> "$COLLECT_DIR/udp_nic_drops.txt"
    # "iterN phase host_nic ip d_kernel_tx d_wire_tx" ("-" = not read)
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.tx' "$a.tx" "$b.tx" >> "$COLLECT_DIR/udp_tx.txt"
    udp_expect
    at=$(udp_attr "iter$ITER $ph" "$FF_UDP_CONFIRM"); read -r -a r <<<"${at%%$'\n'*}"
    if [[ $FF_UDP_CONFIRM == 1 ]] && udp_confirm "$ph" "$at"; then UDP_CONFIRMED=1; read -r -a r <<<"$(udp_attr "iter$ITER $ph")"; fi
    log "  $ph loss: ${r[0]} of ${r[1]} datagrams lost ($(awk -v l="${r[0]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * l / s : 0}')%): sender TX ${r[9]}, receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
    log "  $ph expected from overload: ${r[7]} ($(awk -v e="${r[7]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * e / s : 0}')%)$( (( UDP_CONFIRMED )) && echo "; rate limit between the hosts (paced run): ${r[10]}"); unaccounted beyond it (likely fabric): ${r[8]}"
    (( UDP_CONFIRMED )) || return 0
    log "  $ph paced confirm runs: $(wc -l < "$WORK/uconf.$ITER.$ph.pick" | tr -d ' '), each at 80% of what its run delivered, $UDP_CONFIRM_SECS s:"
    sed 's/^/# /' "$WORK/uconf.$ITER.$ph.log" >&2
}

# udp_confirm phase attr_output (FF_UDP_CONFIRM=1): 0 when confirm runs happened. Every run into a host that
# triggers (ff_udp_confirm.pick) runs again for UDP_CONFIRM_SECS s at 80% of what it delivered, a wave's runs at
# once; a rate limit no host counter shows loses nothing at that rate. Rows: udp_confirm.txt.
udp_confirm() {
    local ph=$1 w=$WORK/uconf.$ITER.$1 plan=$WORK/uplan.$ITER.$1 cf=$COLLECT_DIR/udp_confirm.txt
    [[ -s $plan ]] || return 1
    echo "$2" > "$w.hosts"
    awk -v t="iter$ITER $ph" -v pct="$FF_UDP_CONFIRM_PCT" -v streams="$FF_STREAMS" '#@awk ff_udp_confirm.pick' \
        "$w.hosts" "$WORK/uipmap" "$COLLECT_DIR/udp_expected.txt" "$plan" > "$w.pick"
    [[ -s $w.pick ]] || return 1
    local g bps c src dst port len tgt cur=
    : > "$w.out"
    while read -r g bps c src dst port len tgt; do
        [[ $g == "$cur" ]] || { wait; cur=$g; }
        ( out=$(rbash -T $(( UDP_CONFIRM_SECS + 30 )) "$tgt" \
                  "$src" "$dst" "$port" "$FF_STREAMS" "$UDP_CONFIRM_SECS" "$len" "$bps" "$FF_TOS" <<<"$UDPC_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "$c $src $dst ${out%%$'\n'*}" >> "$w.out" ) &
    done < "$w.pick"
    wait
    [[ -e $cf ]] || echo "# iter phase wave src dst paced_gbps lost sent loss_pct secs limit_gbps moved reading" > "$cf"
    awk -v t="iter$ITER $ph" -v secs="$UDP_CONFIRM_SECS" -v streams="$FF_STREAMS" -v rows="$cf" '#@awk ff_udp_confirm.place' \
        "$w.hosts" "$WORK/uipmap" "$COLLECT_DIR/udp_expected.txt" "$w.pick" "$w.out" > "$w.log"
}

# udp_expect: udp_expected.txt, per UDP run "iterN phase wave src dst offered rx expected lost sent gbps tx".
# tx = this run's share of the datagrams its sender NIC never put on the wire in that phase (udp_tx.txt):
# stack = sent - kernel tx packets, NIC = kernel tx - wire tx, each floored at 0 (other traffic only adds
# packets, so a shortfall is real), shared over the NIC's runs by datagrams sent, at most the run's loss.
# offered = what the runs sending to that dst at once (same phase and wave) put on the wire: each run's
# received Gbps x (sent - tx) / delivered; rx = the dst's line rate; expected = 1 - rx/offered when
# offered > rx (uncapped UDP has no backoff: that much is lost to overload alone), else 0. A run that
# delivered nothing, or a dst line rate not known: offered "-", expected 0, so no loss is excused.
UDP_EXPECT_AWK='
#@awk ff_udp_expect'
udp_expect() {
    awk "$UDP_EXPECT_AWK" "$WORK/iplines" "$COLLECT_DIR/udp_tx.txt" "$UDP_RESULTS" > "$COLLECT_DIR/udp_expected.txt"
}
