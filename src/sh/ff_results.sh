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

# UDP phases U1 (same rail) and U2 (cross) on the current pairs, with host and NIC
# counters read around each phase so lost datagrams can be placed.
udp_phases() {
    local u p ck sk a=$WORK/udp.0
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"
    for u in 1 2; do
        PHASE=U$u; PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
        if [[ $u == 2 && $CROSS != on ]]; then log "Phase U2: skipped (cross-rail $CROSS)"; phase_skip U2; continue; fi
        phase_start
        [[ $u == 1 ]] && log "Phase U1: UDP $(same_desc) at once (-b 0), start $PT0" || log "Phase U2: UDP cross-rail, $(cross_desc) at once (-b 0), start $PT0"
        echo "### iteration:${ITER} phase:${PHASE}" >> "$UDP_RESULTS"
        if [[ $u == 1 ]]; then
            for (( p = 0; p < ${#PC[@]}; p++ )); do p1_paths $p run udp; done
            wait
        else xwaves "$UDP_RESULTS" udp; fi
        phase_end $PHASE
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        local b=$WORK/udp.$u
        collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"; collect_counters "$TXCTR_SCRIPT" "$b.tx"
        collect_temps "iter${ITER}_$PHASE"
        udp_close $PHASE "$a" "$b"
        a=$b
    done
}

# udp_close phase pre post: the phase's host and NIC counter deltas, appended to udp_host_counters.txt
# ("iterN phase host dInErrors dRcvbufErrors dSndbufErrors dSoftnet") and udp_nic_drops.txt ("iterN phase host_nic drx doob"),
# then its loss line
udp_close() {
    local ph=$1 a=$2 b=$3 r
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.counters' \
        "$a.host" "$b.host" >> "$COLLECT_DIR/udp_host_counters.txt"
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.nic' "$a.nic" "$b.nic" >> "$COLLECT_DIR/udp_nic_drops.txt"
    # "iterN phase host_nic ip d_kernel_tx d_wire_tx" ("-" = not read)
    awk -v t="iter$ITER $ph" '#@awk ff_udp_close.tx' "$a.tx" "$b.tx" >> "$COLLECT_DIR/udp_tx.txt"
    udp_expect
    read -r -a r <<<"$(udp_attr "iter$ITER $ph")"
    log "  $ph loss: ${r[0]} of ${r[1]} datagrams lost ($(awk -v l="${r[0]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * l / s : 0}')%): sender TX ${r[9]}, receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
    log "  $ph expected from overload: ${r[7]} ($(awk -v e="${r[7]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * e / s : 0}')%); unaccounted beyond it (likely fabric): ${r[8]}"
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
