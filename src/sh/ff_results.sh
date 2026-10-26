# cross_summary ipmap results: the inter-rail total (an iteration's cross-rail runs share the path between
# the rails at once) and, when only cross-rail runs miss the OK cut-off, where to look.
cross_summary() {
    local x xm am bm
    x=$(awk -F'[, ]+' 'NR == FNR { rail[$1] = $3; next }
        /^### / { split($2, a, ":"); it = a[2]; if ($4 ~ /^wave:/) it = it "w" substr($4, 6); next }
        { g = -1; rt = 0
          for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^retransmits:/) { split($i, q, ":"); rt = q[2] + 0 } }
          if (g >= 0 && ($1 in rail) && ($2 in rail)) print (rail[$1] == rail[$2] ? rail[$1] : rail[$1] ">" rail[$2]), it, g, rt }' "$1" "$2")
    [[ $x == *'>'* ]] || return 0
    awk -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v cm="${FF_CROSS_MAX:-0}" '
        function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
        function k(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e4 ? sprintf("%.1fk", n / 1e3) : n) }
        function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return ""
            for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
            return sprintf("%.1f", n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2) }
        BEGIN { nr = split(lines, q, " "); for (i = 1; i <= nr; i++) { split(q[i], kv, "="); R[i] = kv[1]; L[kv[1]] = kv[2] + 0 } }
        $1 ~ />/ { nx++; d[$1]++; tot[$2] += $3; xr += $4; xv = xv " " $3; if (index($2, "w")) wv = 1; next }
        { sr += $4; sv[$1] = sv[$1] " " $3 }
        END { for (i in tot) { ni++; s += tot[i]; if (ni == 1 || tot[i] < lo) lo = tot[i]; if (ni == 1 || tot[i] > hi) hi = tot[i] }
              if (ni == 1) printf "  Cross-rail total: %s over %d flows run at once", bw(s), nx
              else if (wv) printf "  Cross-rail total per wave (FF_CROSS_MAX=%d flows at once): largest %s, %s on average (%s to %s over %d waves), %d flows", cm, bw(hi), bw(s / ni), bw(lo), bw(hi), ni, nx
              else printf "  Cross-rail total per iteration: %s on average (%s to %s over %d iterations), %d flows", bw(s / ni), bw(lo), bw(hi), ni, nx
              # directions: every one with two rails (as before), the ones that ran with more
              ds = ""; for (i = 1; i <= nr; i++) for (j = 1; j <= nr; j++) if (i != j && (nr == 2 || (R[i] ">" R[j]) in d))
                  ds = ds sprintf("%s%s->%s %d", ds == "" ? "" : ", ", R[i], R[j], d[R[i] ">" R[j]])
              xm = med(xv)
              printf " (%s); median %s Gbps per flow; retransmits %s cross-rail vs %s same-rail\n", ds, xm, k(xr), k(sr + 0)
              lx = 0; for (i = 1; i <= nr; i++) if (i == 1 || L[R[i]] < lx) lx = L[R[i]]
              cx = lx * ok / 100; any = 0; allok = 1; sm = ""
              for (i = 1; i <= nr; i++) { m = med(sv[R[i]]); sm = sm sprintf("%s%s (%s)", i > 1 ? " / " : "", m == "" ? "-" : m, R[i])
                  if (m != "") { any = 1; if (m + 0 < L[R[i]] * ok / 100) allok = 0 } }
              if (lx > 0 && xm + 0 < cx && any && allok)
                  printf "  Same-rail runs are OK, cross-rail runs are not: cross-rail median %s Gbps per flow (OK >= %g), same-rail median %s Gbps. The hosts pass on their own rail, so the likely limit is the shared path between the rails (switch inter-link or spine), not the hosts.\n", xm, cx, sm }' <<<"$x"
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
    awk -v t="iter$ITER $ph" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
        ($1, 2) in p {printf "%s %s", t, $1; for (i = 2; i <= 5; i++) printf " %d", $i - p[$1, i]; print ""}' \
        "$a.host" "$b.host" >> "$COLLECT_DIR/udp_host_counters.txt"
    awk -v t="iter$ITER $ph" 'NR==FNR {rx[$1] = $3; oob[$1] = $5; next} ($1 in rx) {
            drx = ($3 ~ /^[0-9]+$/ && rx[$1] ~ /^[0-9]+$/) ? $3 - rx[$1] : 0
            doob = ($5 ~ /^[0-9]+$/ && oob[$1] ~ /^[0-9]+$/) ? $5 - oob[$1] : 0
            print t, $1, drx, doob }' "$a.nic" "$b.nic" >> "$COLLECT_DIR/udp_nic_drops.txt"
    # "iterN phase host_nic ip d_kernel_tx d_wire_tx" ("-" = not read)
    awk -v t="iter$ITER $ph" 'NR==FNR {k[$1] = $3; w[$1] = $4; next} ($1 in k) {
            dk = ($3 ~ /^[0-9]+$/ && k[$1] ~ /^[0-9]+$/) ? $3 - k[$1] : "-"
            dw = ($4 ~ /^[0-9]+$/ && w[$1] ~ /^[0-9]+$/) ? $4 - w[$1] : "-"
            print t, $1, $2, dk, dw }' "$a.tx" "$b.tx" >> "$COLLECT_DIR/udp_tx.txt"
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
