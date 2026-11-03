# DSCP check (FF_RDMA=1): per planned backend path a TOS-marked probe (iperf3 UDP, 1 Mbit/s for 2 s; ping -Q when
# iperf3 is missing or saw under 5 packets); tcpdump on the receiving NIC reads the byte.
# dscp_check.txt: src dst nic probe tos_sent tos_seen verdict note
dscp_check() {
    local tos=${FF_TOS:-96} srcd out=$COLLECT_DIR/dscp_check.txt D=$WORK/dscp k sk sr dk dr i w nw=0 st n t
    srcd=$([[ -n $FF_TOS ]] && echo "FF_TOS=$FF_TOS" || echo default)
    local -a keys=() A=() B=() WAVE=(); local -A NOTE=() PROBE=() SEEN=() IP3=() seen=()
    (( $# )) && mapfile -t keys < <(printf '%s\n' "$@" | sort -n -k1,1 -k2,2 -k3,3 -k4,4)   # args: planned paths "sk sr dk dr"
    mkdir -p "$D/paths"; : > "$out"
    log "DSCP check: ${#keys[@]} planned paths, DSCP $(( tos >> 2 )) ($srcd) as TOS $tos, iperf3 UDP probe (1 Mbit/s, 2 s), ping fallback"
    local PATHS=$D/paths   # check_path writes here
    for (( i = 0; i < ${#keys[@]}; i++ )); do read -r sk sr dk dr <<<"${keys[i]}"; throttle; check_path d$i $sk $sr $dk $dr; done
    wait
    for k in "${ELIG[@]}"; do section "${DISC[$k]}" tools | grep -q '^iperf3 /' && IP3[$k]=1; done
    for (( i = 0; i < ${#keys[@]}; i++ )); do
        read -r sk sr dk dr <<<"${keys[i]}"; st=$(cat "$PATHS/d$i" 2>&1)
        if [[ $st == DOWN* ]]; then NOTE[$i]=rail_down
        elif [[ $st != OK ]]; then NOTE[$i]=path_check_failed
        elif [[ -n ${IP3[$sk]} && -n ${IP3[$dk]} ]]; then
            A+=("$i"); w=${seen[${RIP[$dk,$dr]}]:-0}; WAVE[i]=$w; seen[${RIP[$dk,$dr]}]=$(( w + 1 )); (( w + 1 > nw )) && nw=$(( w + 1 ))
        else NOTE[$i]=iperf3_absent; B+=("$i"); fi
    done
    # A: one probe per receiving IP at a time (its iperf3 server takes one test at a time)
    (( ${#A[@]} )) && log "  ${#A[@]} iperf3 probes in $nw wave$( (( nw != 1 )) && echo s) (one per receiving IP at a time)"
    for (( w = 0; w < nw; w++ )); do
        for i in "${A[@]}"; do (( WAVE[i] == w )) || continue; throttle; dscp_probe "$i" iperf3 & done
        wait
    done
    for i in "${A[@]}"; do
        n=0 t=; read -r n t < "$D/$i.iperf3.res"
        if (( ${n:-0} >= 5 )); then PROBE[$i]=iperf3; SEEN[$i]=$t
        elif grep -q '^@@DSCP_RX \(tcpdump\|timeout\)_absent' "$D/$i.iperf3.rx"; then NOTE[$i]=$(awk '/^@@DSCP_RX /{print $2; exit}' "$D/$i.iperf3.rx")
        else NOTE[$i]=iperf3_failed; B+=("$i"); fi
    done
    # B: ping needs no server, so one throttled wave
    for i in "${B[@]}"; do throttle; dscp_probe "$i" ping & done
    wait
    for i in "${B[@]}"; do
        n=0 t=; read -r n t < "$D/$i.ping.res"
        if (( ${n:-0} >= 5 )); then PROBE[$i]=ping; SEEN[$i]=$t
        elif grep -q '^@@DSCP_RX \(tcpdump\|timeout\)_absent' "$D/$i.ping.rx"; then NOTE[$i]=$(awk '/^@@DSCP_RX /{print $2; exit}' "$D/$i.ping.rx")
        else NOTE[$i]=both_failed; fi
    done
    local K=0 R=0 S=0 U=0 v; local -a bad=(); local -A H=()   # H: sender hosts whose iperf3 probe failed and ping got through
    for (( i = 0; i < ${#keys[@]}; i++ )); do
        read -r sk sr dk dr <<<"${keys[i]}"
        if [[ -n ${SEEN[$i]} ]]; then
            if (( SEEN[$i] >> 2 == tos >> 2 )); then v=kept; K=$(( K + 1 ))
            elif (( SEEN[$i] >> 2 == 0 )); then v=stripped; S=$(( S + 1 ))
            else v=rewritten; R=$(( R + 1 )); fi
            [[ $v != kept ]] && bad+=("${T_HOST[$sk]} ${RIP[$sk,$sr]} -> ${T_HOST[$dk]} ${RIP[$dk,$dr]}: DSCP $(( tos >> 2 )) $v$([[ $v == rewritten ]] && echo " to $(( SEEN[$i] >> 2 ))")")
        else v=unknown; U=$(( U + 1 )); fi
        [[ ${PROBE[$i]} == ping && ${NOTE[$i]} == iperf3_failed ]] && H[${T_HOST[$sk]}]=1
        echo "${RIP[$sk,$sr]} ${RIP[$dk,$dr]} ${RNIC[$dk,$dr]} ${PROBE[$i]:-none} $tos ${SEEN[$i]:--} $v ${NOTE[$i]:--}"
    done > "$out"
    log "DSCP check: $K of ${#keys[@]} paths kept DSCP $(( tos >> 2 )) ($srcd); $R rewritten; $S stripped; $U unknown (dscp_check.txt)"
    (( ${#bad[@]} )) && { log "WARNING: DSCP not kept on $(( R + S )) paths$( (( ${#bad[@]} > 10 )) && echo ", first 10"):"; printf '#   %s\n' "${bad[@]:0:10}" >&2; }
    (( ${#H[@]} )) && log "iperf3 DSCP probe failed on ${#H[@]} hosts, ping probe used (dscp_check.txt)"
    return 0
}

# dscp_probe i iperf3|ping: one probe of path keys[i]; the receiver's tcpdump starts first, the sender once it
# listens (up to 8 s). Writes $D/<i>.<probe>.rx/.tx and .res: "<packets with a TOS byte> <first TOS, decimal>"
dscp_probe() {
    local i=$1 pr=$2 sk sr dk dr f=$D/$1.$2 rp n t
    read -r sk sr dk dr <<<"${keys[i]}"
    rbash -T 25 "${T_TARGET[$dk]}" "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "${RNIC[$dk,$dr]}" "$FF_PORT" "$pr" <<<"$DSCP_RX_SCRIPT" > "$f.rx" 2>&1 & rp=$!
    for (( n = 0; n < 40; n++ )); do
        grep -q '^tcpdump: listening on' "$f.rx" && break
        jobs -rp | grep -qx "$rp" || break
        sleep 0.2
    done
    grep -q '^tcpdump: listening on' "$f.rx" &&
        rbash -T 20 "${T_TARGET[$sk]}" "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$tos" "$pr" <<<"$DSCP_TX_SCRIPT" > "$f.tx" 2>&1
    wait "$rp"
    n=$(grep -c 'IP (tos 0x' "$f.rx"); t=$(grep -m1 -o 'IP (tos 0x[0-9a-fA-F]*' "$f.rx"); t=${t##*0x}
    echo "$n ${t:+$(( 16#$t ))}" > "$f.res"
}
