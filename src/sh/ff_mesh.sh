# FF_MESH=1: every usable rail IP of each tested host pings every other tested host's usable rail IPs (its own rail
# only with FF_CROSS_RAIL=0), and every usable client data NIC IP pings every backend rail IP. A pair whose route
# leaves another NIC than the source's own is not pinged (counted as not routed: on rails that are separate fabrics
# every cross-rail pair is one); every other pair gets MESH_COUNT pings: all lost = unreachable, some lost = lossy.
MESH_COUNT=5
# mesh_call k out plan src_a src_b dst...: one remote mesh run (sources ip@nic; "none" = no second source) in the
# background; its planned pairs ("src dst") go to plan first
mesh_call() {
    local k=$1 out=$2 plan=$3 a=$4 b=$5 s d; shift 5
    for s in "$a" "$b"; do [[ $s == none ]] && continue; for d in "$@"; do echo "${s%@*} $d"; done; done >> "$plan"
    throttle
    ( rbash "${T_TARGET[$k]}" "$a" "$b" "$MESH_COUNT" "$@" <<<"$MESH_SCRIPT" > "$out" 2>&1 ) &
}
mesh_check() {
    local k j r q
    local -A host_of=() chost_of=()
    local -a bdst=() dst=() src=()
    : > "$WORK/mesh_plan_b"; : > "$WORK/mesh_plan_c"; : > "$WORK/meshmap"
    for j in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do rail_ok $j $r || continue
        host_of[${RIP[$j,$r]}]=${T_HOST[$j]}; bdst+=("${RIP[$j,$r]}"); echo "${RIP[$j,$r]} ${T_HOST[$j]} $r" >> "$WORK/meshmap"
    done; done
    if [[ $FF_CROSS_RAIL == 0 ]]; then log "Mesh: every rail IP pings the other tested hosts' rail IPs on its own rail (FF_CROSS_RAIL=0), $MESH_COUNT pings each..."
    else log "Mesh: every rail IP pings the ${#host_of[@]} rail IPs of the other tested hosts, $MESH_COUNT pings each..."; fi
    for k in "${ELIG[@]}"; do
        if [[ $FF_CROSS_RAIL == 0 ]]; then
            for r in "${RAILS[@]}"; do rail_ok $k $r || continue
                dst=(); for j in "${ELIG[@]}"; do [[ $j != "$k" ]] && rail_ok $j $r && dst+=("${RIP[$j,$r]}"); done
                (( ${#dst[@]} )) && mesh_call "$k" "$WORK/mesh.$k.$r" "$WORK/mesh_plan_b" "${RIP[$k,$r]}@${RNIC[$k,$r]}" none "${dst[@]}"
            done
            continue
        fi
        dst=(); src=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] || continue; for r in "${RAILS[@]}"; do rail_ok $j $r && dst+=("${RIP[$j,$r]}"); done; done
        for r in "${RAILS[@]}"; do rail_ok $k $r && src+=("${RIP[$k,$r]}@${RNIC[$k,$r]}"); done
        (( ${#src[@]} && ${#dst[@]} )) || continue
        # the script takes two sources ("none" = no such rail): one call per two rails
        for (( q = 0; q < ${#src[@]}; q += 2 )); do mesh_call "$k" "$WORK/mesh.$k.$q" "$WORK/mesh_plan_b" "${src[q]}" "${src[q+1]:-none}" "${dst[@]}"; done
    done
    # clients: every usable client data NIC pings every backend rail IP (clients never ping each other)
    for k in "${CLI[@]}"; do
        src=()
        for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j && { src+=("${CIP[$k,$j]}@${CNIC[$k,$j]}"); chost_of[${CIP[$k,$j]}]=${T_HOST[$k]}; echo "${CIP[$k,$j]} ${T_HOST[$k]} c" >> "$WORK/meshmap"; }; done
        (( ${#src[@]} && ${#bdst[@]} )) || continue
        for (( q = 0; q < ${#src[@]}; q += 2 )); do mesh_call "$k" "$WORK/cmesh.$k.$q" "$WORK/mesh_plan_c" "${src[q]}" "${src[q+1]:-none}" "${bdst[@]}"; done
    done
    (( ${#CLI[@]} )) && log "Mesh: and the ${#chost_of[@]} client data NIC IPs ping every backend rail IP..."
    wait
    # remote lines -> unreachable (mesh_b/mesh_c: "hs s hd d [client]"), lossy ("... lost count [client]"), not routed
    # ("hs s hd d dev cross|same|client"); probed pairs = planned minus not routed
    local w
    for w in b c; do
        : > "$WORK/mesh_$w"; : > "$WORK/mesh_l$w"; : > "$WORK/mesh_u$w"; : > "$WORK/mesh_x$w"
        local pre=mesh sfx=""; [[ $w == c ]] && { pre=cmesh; sfx=" client"; }
        cat "$WORK"/$pre.* > "$WORK/mesh_out_$w" 2>&1   # no such file (no clients): its one error line matches nothing
        awk -v sfx="$sfx" -v fb="$WORK/mesh_$w.u" -v fl="$WORK/mesh_l$w.u" -v fu="$WORK/mesh_u$w.u" -v fx="$WORK/mesh_x$w" \
            '#@awk ff_mesh_parse' "$WORK/meshmap" "$WORK/mesh_out_$w"
        local x; for x in "$w" "l$w" "u$w"; do [[ -f $WORK/mesh_$x.u ]] && sort -V "$WORK/mesh_$x.u" > "$WORK/mesh_$x"; done
        awk 'FILENAME == ARGV[1] {x[$1 " " $2] = 1; next} !(($1 " " $2) in x)' "$WORK/mesh_x$w" "$WORK/mesh_plan_$w" > "$WORK/mesh_probed_$w"
    done
    cat "$WORK/mesh_b" "$WORK/mesh_c" > "$COLLECT_DIR/mesh_failures.txt"
    cat "$WORK/mesh_lb" "$WORK/mesh_lc" > "$COLLECT_DIR/mesh_lossy.txt"
    cat "$WORK/mesh_ub" "$WORK/mesh_uc" > "$COLLECT_DIR/mesh_unrouted.txt"
    local fails cfails lossy clossy probed cprobed unr ux us uc
    fails=$(wc -l < "$COLLECT_DIR/mesh_failures.txt" | tr -d ' '); cfails=$(wc -l < "$WORK/mesh_c" | tr -d ' ')
    lossy=$(wc -l < "$COLLECT_DIR/mesh_lossy.txt" | tr -d ' '); clossy=$(wc -l < "$WORK/mesh_lc" | tr -d ' ')
    probed=$(( $(wc -l < "$WORK/mesh_probed_b") + $(wc -l < "$WORK/mesh_probed_c") )); cprobed=$(wc -l < "$WORK/mesh_probed_c" | tr -d ' ')
    unr=$(wc -l < "$COLLECT_DIR/mesh_unrouted.txt" | tr -d ' ')
    ux=$(awk '$6 == "cross"' "$COLLECT_DIR/mesh_unrouted.txt" | wc -l | tr -d ' '); us=$(awk '$6 == "same"' "$COLLECT_DIR/mesh_unrouted.txt" | wc -l | tr -d ' ')
    uc=$(awk '$6 == "client"' "$COLLECT_DIR/mesh_unrouted.txt" | wc -l | tr -d ' ')
    log "Mesh: $probed pairs pinged ($MESH_COUNT pings each), $fails unreachable, $lossy lossy$( (( ${#CLI[@]} )) && echo " (from clients: $cfails of $cprobed unreachable, $clossy lossy)")"
    (( unr )) && log "Mesh: $unr pairs not pinged, their route leaves another NIC than the source's own (mesh_unrouted.txt): $ux cross-rail, $us same-rail$( (( ${#CLI[@]} )) && echo ", $uc from clients")"
    MESH_PINGS=$probed; MESH_FAILS=$fails; MESH_CPINGS=$cprobed; MESH_CFAILS=$cfails
    MESH_LOSSY=$lossy; MESH_CLOSSY=$clossy; MESH_UNROUTED=$unr
    (( fails + lossy + us )) || return 0
    : > "$WORK/mesh_anom"
    if (( cfails )); then
        # A client IP failing to every backend rail IP it pinged gets no replies at all; otherwise a backend rail IP
        # failing from many client IPs points at that rail as clients reach it
        awk '#@awk ff_mesh_check.clients' "$WORK/meshmap" "$WORK/mesh_probed_c" "$WORK/mesh_c" | sort -k2,2 -k7,7rn > "$WORK/mesh_anom"
    fi
    if [[ -s $WORK/mesh_b ]]; then
        # A source whose pings fail to every peer it pinged gets no replies at all (its inbound ICMP or rail is
        # blocked): report it once as the source and keep its failures out of the destination counts.
        # Otherwise a destination failing from many sources points at that rail. Peers and sources count the
        # pairs pinged (mesh_probed_b), so pairs not routed out the source's NIC never count.
        awk '#@awk ff_mesh_check.backends' "$WORK/meshmap" "$WORK/mesh_probed_b" "$WORK/mesh_b" | sort -k2,2 -k7,7rn > "$WORK/mesh_banom"
        cat "$WORK/mesh_banom" "$WORK/mesh_anom" > "$WORK/mesh_all"; mv "$WORK/mesh_all" "$WORK/mesh_anom"
    fi
    # lossy: a destination that lost some (not all) of its pings, from how many of the IPs that pinged it
    awk -v kind=mesh_lossy -v who="pinging rail IPs" '#@awk ff_mesh_check.lossy' "$WORK/meshmap" "$WORK/mesh_probed_b" "$WORK/mesh_lb" | sort -k9,9rn >> "$WORK/mesh_anom"
    awk -v kind=mesh_client_lossy -v who="client IPs" '#@awk ff_mesh_check.lossy' "$WORK/meshmap" "$WORK/mesh_probed_c" "$WORK/mesh_lc" | sort -k9,9rn >> "$WORK/mesh_anom"
    # same-rail pairs whose route leaves another NIC: a routing fault on that host (cross-rail ones are the rails' design)
    awk '$6 == "same" {k = $1 " " $2 " " $5; n[k]++} END {for (k in n) {split(k, a, " "); printf "%s mesh_no_route rail IP %s routes %d same-rail peers out %s, not its own NIC\n", a[1], a[2], n[k], (a[3] == "-" ? "nowhere (no route)" : a[3])}}' \
        "$COLLECT_DIR/mesh_unrouted.txt" | sort -V >> "$WORK/mesh_anom"
    cat "$WORK/mesh_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    log "WARNING: mesh findings (silent sources first, then unreachable and lossy destinations, worst first):"
    sed 's/^/#   /' "$WORK/mesh_anom" | head -n 10 >&2
}

# LLDP: a rail NIC whose switch most hosts reach on the other rail is cabled to the wrong rail. A bond's
# member rows carry the bond's IP, so the map also names it: a member is checked against its bond's rail.
lldp_rail_check() {
    local railmap=$WORK/railmap k r
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r) ${RIP[$k,$r]}"
    done; done > "$railmap"
    # compared with the rail most NICs on that switch use (with two rails: the other one)
    awk '#@awk ff_lldp_rail_check' \
        "$railmap" "$1" > "$WORK/lldp_anom"
    if [[ -s $WORK/lldp_anom ]]; then
        log "WARNING: $(wc -l < "$WORK/lldp_anom" | tr -d ' ') rail NICs are cabled to a switch that serves the other rail (LLDP):"
        sed 's/^/#   /' "$WORK/lldp_anom" | head -n 10 >&2
        cat "$WORK/lldp_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}
