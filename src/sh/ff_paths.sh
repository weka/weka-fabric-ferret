# round_pairs r: round r of the circle method over ROT (even length, "-" = bye).
# ROT[0] stays put and the rest rotate one place per round, so no pair repeats
# until every pair has met (${#ROT[@]} - 1 rounds). Sets PC/PS (client/server), PI (pair slot) and SITOUT.
round_pairs() {
    local r=$1 m=${#ROT[@]} i a b
    local -a arr=("${ROT[0]}")
    for (( i = 0; i < m - 1; i++ )); do arr+=("${ROT[1 + (i + r) % (m - 1)]}"); done
    PC=(); PS=(); PI=(); SITOUT=""
    for (( i = 0; i < m / 2; i++ )); do
        a=${arr[i]}; b=${arr[m - 1 - i]}
        if [[ $a == - ]]; then SITOUT=$b
        elif [[ $b == - ]]; then SITOUT=$a
        else PC+=("$a"); PS+=("$b"); PI+=("$i"); fi
    done
}

# xpaths p: pair p's two phase 2 runs, one each way across the rails, in X1/X2 (src_k src_r dst_k dst_r).
# Odd: client A <-> server B; even: client B <-> server A. A rotating host moves one slot per round, so slot
# parity swaps its NIC each iteration; slot 0 (the fixed host) swaps by iteration.
# With more than two rails, the rail pair (XA, XB) comes from UPAIRS by pairing cycle (set per iteration).
xpaths() {
    local c=${PC[$1]} s=${PS[$1]} i=${PI[$1]} a=${XA:-0} b=${XB:-1}
    if (( i ? i % 2 : (RND + 1) % 2 )); then X1=($c $a $s $b); X2=($s $b $c $a); else X1=($c $b $s $a); X2=($s $a $c $b); fi
}

# cross_waves npairs: XW = phase 2 waves under FF_CROSS_MAX (1 when unset). A pair's two flows (one each
# way) stay in one wave, so every wave is balanced A->B / B->A; a cap of 1 runs the flows one at a time.
cross_waves() {
    local np=$1 cap=${FF_CROSS_MAX:-0}
    if (( cap == 0 || 2 * np <= cap )); then XW=1
    elif (( cap == 1 )); then XW=$(( 2 * np ))
    else XW=$(( (np + cap / 2 - 1) / (cap / 2) )); fi
}

# xwaves results [udp]: the current pairs' cross-rail runs in XW waves (pair p in wave p % XW). TCP results
# get a "wave:w/W" marker per wave, so totals only add up flows that ran at the same time.
xwaves() {
    local res=$1 mode=$2 w p all=$PHASE_OUT
    cross_waves ${#PC[@]}
    (( XW > 1 && ITER == 1 )) && log "  $(( 2 * ${#PC[@]} )) cross-rail flows in $XW waves of at most $FF_CROSS_MAX (FF_CROSS_MAX), $( (( FF_CROSS_MAX == 1 )) && echo "one flow at a time" || echo "each wave A->B and B->A balanced")"
    for (( w = 0; w < XW; w++ )); do
        PHASE_OUT=$all.w$w; : > "$PHASE_OUT"
        [[ $mode == udp ]] || echo "### iteration:${ITER} phase:${PHASE}$( (( XW > 1 )) && echo " wave:$(( w + 1 ))/$XW")" >> "$res"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            xpaths $p
            if (( ${FF_CROSS_MAX:-0} == 1 && XW > 1 )); then   # cap 1: wave 2p runs X1, 2p+1 runs X2
                (( p == w / 2 )) || continue
                if (( w % 2 )); then run_path p2b_$p "${X2[@]}" $mode; else run_path p2a_$p "${X1[@]}" $mode; fi
            else
                (( p % XW == w )) || continue
                run_path p2a_$p "${X1[@]}" $mode; run_path p2b_$p "${X2[@]}" $mode
            fi
        done
        wait
        [[ $mode == udp ]] || column -t < "$PHASE_OUT" | tee -a "$res"
        cat "$PHASE_OUT" >> "$all"
    done
    PHASE_OUT=$all
}

# p1_paths p check|run [mode]: pair p's same-rail paths, one per rail: client->server on even rails,
# server->client on odd ones (two rails: A c->s, B s->c), so each host sends on some rails and receives on others
p1_paths() {
    local p=$1 fn=${2}_path mode=$3 r
    for r in "${RAILS[@]}"; do
        if (( r % 2 )); then $fn p1${r}_$p ${PS[p]} $r ${PC[p]} $r $mode
        else $fn p1${r}_$p ${PC[p]} $r ${PS[p]} $r $mode; fi
    done
}
# "A->A and B->B" / "A->B and B->A" for the log
same_desc() { local r o=""; for r in "${RAILS[@]}"; do o+="$( (( r == 0 )) || { (( r == NR - 1 )) && echo " and " || echo ", "; })$(rail_letter $r)->$(rail_letter $r)"; done; echo "$o"; }
cross_desc() { echo "$(rail_letter ${XA:-0})->$(rail_letter ${XB:-1}) and $(rail_letter ${XB:-1})->$(rail_letter ${XA:-0})"; }

# check_path key src_k src_r dst_k dst_r: writes OK or a reason to $PATHS/key
check_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5
    if ! rail_ok $sk $sr; then echo "DOWN ${T_HOST[$sk]}: ${RSTATE[$sk,$sr]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $dk $dr; then echo "DOWN ${T_HOST[$dk]}: ${RSTATE[$dk,$dr]}" > "$PATHS/$key"; return; fi
    local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
    # same rail: the larger MTU, so a 1500/9000 pair fails here, not pass at 1472 and run with retransmits.
    # Cross-rail (routed): the smaller of the two rails' MTUs (each rail at its highest host MTU, as its
    # router side would be), so a 4220 RDMA rail to a 9000 rail passes but a 1500 host on a 9000 rail fails.
    local r1=${RAIL_MTU[$sr]:-$m1} r2=${RAIL_MTU[$dr]:-$m2}
    local size=$(( (sr == dr ? (m1 > m2 ? m1 : m2) : (r1 < r2 ? r1 : r2)) - 28 ))
    ( out=$(rbash "${T_TARGET[$sk]}" "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "${RNIC[$sk,$sr]}" $size <<<"$PATH_SCRIPT" 2>&1)
      echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
}

# run_path key src_k src_r dst_k dst_r [udp]: one iperf3 run, appends to $PHASE_OUT
run_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5 mode=${6:-tcp} st
    st=$(cat "$PATHS/$key")
    if [[ $st != OK ]]; then
        echo "$ITER $PHASE ${T_HOST[$sk]} ${RIP[$sk,$sr]} ${T_HOST[$dk]} ${RIP[$dk,$dr]} $st" >> "$PATH_EXCL"
        log "  skip ${T_HOST[$sk]} ${RIP[$sk,$sr]} -> ${T_HOST[$dk]} ${RIP[$dk,$dr]}: $st"
        return
    fi
    if [[ $mode == check ]]; then echo "${RIP[$sk,$sr]} ${RIP[$dk,$dr]}" >> "$WORK/paths_ok"; return; fi   # FF_SKIP_IPERF=1
    if [[ $mode == udp ]]; then
        local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
        local len=$(( (m1 < m2 ? m1 : m2) - 28 ))   # largest datagram that needs no fragmenting
        ( out=$(timeout $(( FF_UDP_DURATION + 30 )) ssh "${SSH_OPTS[@]}" "${T_TARGET[$sk]}" $SUDO bash -s -- \
                  "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_UDP_DURATION" "$len" "$FF_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(timeout $(( FF_DURATION + 30 )) ssh "${SSH_OPTS[@]}" "${T_TARGET[$sk]}" $SUDO bash -s -- \
              "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_DURATION" "$FF_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
}
