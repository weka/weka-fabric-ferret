# rail_has k r: host k holds rail r (a NIC with an address on it; it may still be DOWN, which is a per-path skip)
rail_has() { case ${RSTATE[$1,$2]} in "no NIC "*|"no IPv4 on "*|"no address in "*) return 1 ;; esac; return 0; }

# rail_groups: the eligible hosts (ORDER) grouped by the rails they hold (HR[k], rail indices), in ORDER's
# order. A rail set held by one host joins the largest group whose rails include it (its pairs plan only the
# rails it holds: JOINED notes "host: rail B not addressed, tested on A only"); a lone host no group contains
# has no partner. Per group g: GKEYS[g] its rail letters, GN[g] hosts, GROT[g] its round-robin circle (a bye
# "-" when odd, none for a lone host), GRAILS[g] rail indices, GROUNDS[g] rounds to meet every pair,
# GPER[g] pairs per iteration, GUPAIRS[g] rail pairs for phase 2 ("0 1;0 2;1 2"), GNUP[g] their count
# (1 with no cross phase), GPPP[g] paths per pair per iteration (a pair with a joined host has fewer).
rail_groups() {
    local k r key g h best
    local -A gi=()
    local -a keys=() n=() rot=() rails=()
    HR=(); JOINED=""
    for k in "${ORDER[@]}"; do
        key=""; HR[$k]=""; for r in "${RAILS[@]}"; do rail_has $k $r && { key+=$(rail_letter $r); HR[$k]+="${HR[$k]:+ }$r"; }; done
        [[ -n $key ]] || key=none
        if [[ -z ${gi[$key]} ]]; then gi[$key]=${#keys[@]}; keys+=("$key"); n+=(0); rot+=(""); rails+=("${HR[$k]}"); fi
        g=${gi[$key]}; n[g]=$(( n[g] + 1 )); rot[g]+="${rot[g]:+ }$k"
    done
    for (( g = 0; g < ${#keys[@]}; g++ )); do
        (( n[g] == 1 )) || continue
        best=-1
        for (( h = 0; h < ${#keys[@]}; h++ )); do
            (( h != g && n[h] > 0 )) || continue
            local ok=1; for r in ${rails[g]}; do [[ " ${rails[h]} " == *" $r "* ]] || ok=0; done
            (( ok )) && { (( best < 0 || n[h] > n[best] )) && best=$h; }
        done
        (( best >= 0 )) || continue
        k=${rot[g]}; local lack="" held=""
        for r in ${rails[best]}; do [[ " ${rails[g]} " == *" $r "* ]] && held+=$(rail_letter $r) || lack+="${lack:+,}$(rail_letter $r)"; done
        JOINED+="${JOINED:+; }${T_HOST[$k]}: rail $lack not addressed, tested on $held only"
        rot[best]+=" $k"; n[best]=$(( n[best] + 1 )); n[g]=0
    done
    GKEYS=(); GN=(); GROT=(); GRAILS=(); GROUNDS=(); GPER=(); GUPAIRS=(); GNUP=(); GPPP=(); GDPER=()
    for (( h = 0; h < ${#keys[@]}; h++ )); do
        (( n[h] > 0 )) || continue
        g=${#GKEYS[@]}; GKEYS+=("${keys[h]}"); GN+=("${n[h]}"); GROT+=("${rot[h]}"); GRAILS+=("${rails[h]}")
        local nn=${GN[g]} nr=0 up="" ua ub m
        (( nn > 1 && nn % 2 )) && GROT[g]+=" -"
        m=$(( nn > 1 ? nn + nn % 2 : 1 ))
        GROUNDS[g]=$(( m > 1 ? m - 1 : 0 )); GPER[g]=$(( nn / 2 ))
        for r in ${GRAILS[g]}; do nr=$(( nr + 1 )); done
        if [[ $CROSS == on ]] && (( nr > 1 )); then
            for ua in ${GRAILS[g]}; do for ub in ${GRAILS[g]}; do (( ub > ua )) && up+="${up:+;}$ua $ub"; done; done
            GUPAIRS[g]=$up; GNUP[g]=$(( (nr * (nr - 1)) / 2 )); GPPP[g]=$(( nr + 2 )); GDPER[g]=$(( nr * nr ))
        else GUPAIRS[g]=""; GNUP[g]=1; GPPP[g]=$nr; GDPER[g]=$nr; fi
    done
}

# pair_rails a b: the rails both hosts hold, in PRL (indices) and PRN (their count)
pair_rails() {
    local r; PRL=""; PRN=0
    for r in ${HR[$1]}; do [[ " ${HR[$2]} " == *" $r "* ]] && { PRL+="${PRL:+ }$r"; PRN=$(( PRN + 1 )); }; done
}

# round_pairs t: iteration t (from 0) of every rail group's circle method over GROT[g] (even length, "-" =
# bye). Slot 0 stays put and the rest rotate one place per round, so no pair repeats until every pair has
# met (GROUNDS[g] rounds); the next cycle repeats the pairings with client and server swapped, and each
# further pair of cycles takes the group's next rail pair for phase 2. Sets, per pair p: PC/PS (client/
# server), PI (pair slot), PR (the round), PG (group), PRAILS (the rails both hosts hold), PXA/PXB (phase 2
# rail pair when both hold it, else empty), PPATHS (its paths this iteration); SITOUT the hosts (one per odd
# group) that sit this iteration out; GXA/GXB per group for the log.
round_pairs() {
    local t=$1 g m i a b rr cyc
    PC=(); PS=(); PI=(); PR=(); PG=(); PRAILS=(); PPATHS=(); PXA=(); PXB=(); GXA=(); GXB=(); SITOUT=""; XA=; XB=
    for (( g = 0; g < ${#GKEYS[@]}; g++ )); do
        local -a rot=(${GROT[g]}) up=()
        m=${#rot[@]}; (( m > 1 )) || continue
        rr=$(( t % (m - 1) )); cyc=$(( t / (m - 1) ))
        local xa="" xb=""
        if [[ -n ${GUPAIRS[g]} ]]; then
            IFS=';' read -r -a up <<<"${GUPAIRS[g]}"
            read -r xa xb <<<"${up[$(( cyc / 2 % ${#up[@]} ))]}"
            [[ -n $XA ]] || { XA=$xa; XB=$xb; }
        fi
        GXA[g]=$xa; GXB[g]=$xb
        local -a arr=("${rot[0]}")
        for (( i = 0; i < m - 1; i++ )); do arr+=("${rot[1 + (i + rr) % (m - 1)]}"); done
        for (( i = 0; i < m / 2; i++ )); do
            a=${arr[i]}; b=${arr[m - 1 - i]}
            (( cyc % 2 )) && { local tmp=$a; a=$b; b=$tmp; }
            if [[ $a == - ]]; then SITOUT+=" $b"
            elif [[ $b == - ]]; then SITOUT+=" $a"
            else
                pair_rails $a $b
                local pxa=$xa pxb=$xb
                [[ -n $xa && " $PRL " == *" $xa "* && " $PRL " == *" $xb "* ]] || { pxa=""; pxb=""; }
                PC+=("$a"); PS+=("$b"); PI+=("$i"); PR+=("$rr"); PG+=("$g"); PRAILS+=("$PRL"); PXA+=("$pxa"); PXB+=("$pxb")
                local np=$PRN; [[ -n $pxa ]] && np=$(( np + 2 )); PPATHS+=("$np")
            fi
        done
    done
}

# xpaths p: pair p's two phase 2 runs, one each way across its group's rail pair (PXA, PXB), in X1/X2
# (src_k src_r dst_k dst_r). Odd: client A <-> server B; even: client B <-> server A. A rotating host moves
# one slot per round, so slot parity swaps its NIC each iteration; slot 0 (the fixed host) swaps by round.
xpaths() {
    local c=${PC[$1]} s=${PS[$1]} i=${PI[$1]} a=${PXA[$1]:-0} b=${PXB[$1]:-1}
    if (( i ? i % 2 : (PR[$1] + 1) % 2 )); then X1=($c $a $s $b); X2=($s $b $c $a); else X1=($c $b $s $a); X2=($s $a $c $b); fi
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
    local res=$1 mode=$2 w p q all=$PHASE_OUT
    local -a xp=()   # the pairs with a phase 2 (a one-rail group's pairs have none)
    for (( p = 0; p < ${#PC[@]}; p++ )); do [[ -n ${PXA[p]} ]] && xp+=("$p"); done
    cross_waves ${#xp[@]}
    (( XW > 1 && ITER == 1 )) && log "  $(( 2 * ${#xp[@]} )) cross-rail flows in $XW waves of at most $FF_CROSS_MAX (FF_CROSS_MAX), $( (( FF_CROSS_MAX == 1 )) && echo "one flow at a time" || echo "each wave A->B and B->A balanced")"
    for (( w = 0; w < XW; w++ )); do
        PHASE_OUT=$all.w$w; : > "$PHASE_OUT"
        [[ $mode == udp ]] || echo "### iteration:${ITER} phase:${PHASE}$( (( XW > 1 )) && echo " wave:$(( w + 1 ))/$XW")" >> "$res"
        for (( q = 0; q < ${#xp[@]}; q++ )); do
            p=${xp[q]}; xpaths $p
            if (( ${FF_CROSS_MAX:-0} == 1 && XW > 1 )); then   # cap 1: wave 2q runs X1, 2q+1 runs X2
                (( q == w / 2 )) || continue
                if (( w % 2 )); then run_path p2b_$p "${X2[@]}" $mode; else run_path p2a_$p "${X1[@]}" $mode; fi
            else
                (( q % XW == w )) || continue
                run_path p2a_$p "${X1[@]}" $mode; run_path p2b_$p "${X2[@]}" $mode
            fi
        done
        wait
        [[ $mode == udp ]] || column -t < "$PHASE_OUT" | tee -a "$res"
        cat "$PHASE_OUT" >> "$all"
    done
    PHASE_OUT=$all
}

# p1_paths p check|run [mode]: pair p's same-rail paths, one per rail its group holds: client->server on even
# rails, server->client on odd ones (two rails: A c->s, B s->c), so each host sends on some rails and receives on others
p1_paths() {
    local p=$1 fn=${2}_path mode=$3 r
    for r in ${PRAILS[p]}; do
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
        ( out=$(rbash -T $(( FF_UDP_DURATION + 30 )) "${T_TARGET[$sk]}" \
                  "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_UDP_DURATION" "$len" "$FF_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(rbash -T $(( FF_DURATION + 30 )) "${T_TARGET[$sk]}" \
              "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_DURATION" "$FF_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
}
