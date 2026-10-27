# FF_MESH=1: every usable rail IP of each tested host pings every other tested host's usable rail IPs,
# and every usable client data NIC IP pings every backend rail IP.
mesh_check() {
    local k j r total=0 a b
    local -A host_of=()
    for j in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do rail_ok $j $r && host_of[${RIP[$j,$r]}]=${T_HOST[$j]}; done; done
    log "Mesh: every rail IP pings the ${#host_of[@]} rail IPs of the other tested hosts..."
    for k in "${ELIG[@]}"; do
        local -a dst=() src=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] || continue; for r in "${RAILS[@]}"; do rail_ok $j $r && dst+=("${RIP[$j,$r]}"); done; done
        for r in "${RAILS[@]}"; do rail_ok $k $r && src+=("${RIP[$k,$r]}"); done
        (( ${#src[@]} )) || continue
        total=$(( total + ${#src[@]} * ${#dst[@]} ))
        # the script takes two sources ("none" = no such rail): one call per two rails
        local q
        for (( q = 0; q < ${#src[@]}; q += 2 )); do
            a=${src[q]}; b=${src[q+1]:-none}
            throttle
            ( rbash "${T_TARGET[$k]}" "$a" "$b" "${dst[@]}" <<<"$MESH_SCRIPT" > "$WORK/mesh.$k.$q" 2>&1 ) &
        done
    done
    # clients: every usable client data NIC pings every backend rail IP (clients never ping each other)
    local ctotal=0; local -A chost_of=(); local -a bdst=("${!host_of[@]}")
    for k in "${CLI[@]}"; do
        local -a src=()
        for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j && { src+=("${CIP[$k,$j]}"); chost_of[${CIP[$k,$j]}]=${T_HOST[$k]}; }; done
        (( ${#src[@]} && ${#bdst[@]} )) || continue
        ctotal=$(( ctotal + ${#src[@]} * ${#bdst[@]} ))
        for (( q = 0; q < ${#src[@]}; q += 2 )); do
            a=${src[q]}; b=${src[q+1]:-none}
            throttle
            ( rbash "${T_TARGET[$k]}" "$a" "$b" "${bdst[@]}" <<<"$MESH_SCRIPT" > "$WORK/cmesh.$k.$q" 2>&1 ) &
        done
    done
    (( ${#CLI[@]} )) && log "Mesh: and the ${#chost_of[@]} client data NIC IPs ping every backend rail IP..."
    wait
    cat "$WORK"/mesh.* 2>&1 | awk '$1 == "MESHFAIL" {print $2, $3}' | while read -r s d; do
        echo "${host_of[$s]:-?} $s ${host_of[$d]:-?} $d"
    done | sort -V > "$WORK/mesh_b"
    : > "$WORK/mesh_c"
    if (( ${#CLI[@]} )); then
        cat "$WORK"/cmesh.* 2>&1 | awk '$1 == "MESHFAIL" {print $2, $3}' | while read -r s d; do
            echo "${chost_of[$s]:-?} $s ${host_of[$d]:-?} $d client"
        done | sort -V > "$WORK/mesh_c"
    fi
    cat "$WORK/mesh_b" "$WORK/mesh_c" > "$COLLECT_DIR/mesh_failures.txt"
    local fails cfails; fails=$(wc -l < "$COLLECT_DIR/mesh_failures.txt" | tr -d ' '); cfails=$(wc -l < "$WORK/mesh_c" | tr -d ' ')
    total=$(( total + ctotal ))
    log "Mesh: $total pings, $fails failed$( (( ${#CLI[@]} )) && echo " (from clients: $cfails of $ctotal)")"
    MESH_PINGS=$total; MESH_FAILS=$fails; MESH_CPINGS=$ctotal; MESH_CFAILS=$cfails
    (( fails )) || return 0
    : > "$WORK/mesh_anom"
    if (( cfails )); then
        # A client IP failing to every backend rail IP gets no replies at all; otherwise a backend rail IP
        # failing from many client IPs points at that rail as clients reach it
        local ip; for ip in "${!chost_of[@]}"; do echo "$ip ${chost_of[$ip]}"; done > "$WORK/cmeship"
        awk -v nb=${#bdst[@]} '#@awk ff_mesh_check.clients' "$WORK/cmeship" "$WORK/mesh_c" | sort -k2,2 -k7,7rn > "$WORK/mesh_anom"
    fi
    if [[ -s $WORK/mesh_b ]]; then
        local ip; for ip in "${!host_of[@]}"; do echo "$ip ${host_of[$ip]}"; done > "$WORK/meship"   # backends only
        # A source whose pings fail to every peer gets no replies at all (its inbound ICMP or rail is
        # blocked): report it once as the source and keep its failures out of the destination counts.
        # Otherwise a destination failing from many sources points at that rail.
        # Peers of an IP = every rail IP except its own host's; sources of a destination likewise,
        # minus the silent sources on other hosts.
        awk '#@awk ff_mesh_check.backends' "$WORK/meship" "$WORK/mesh_b" | sort -k2,2 -k7,7rn > "$WORK/mesh_banom"
        cat "$WORK/mesh_banom" "$WORK/mesh_anom" > "$WORK/mesh_all"; mv "$WORK/mesh_all" "$WORK/mesh_anom"
    fi
    cat "$WORK/mesh_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    log "WARNING: mesh findings (silent sources first, then destinations, worst first):"
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
