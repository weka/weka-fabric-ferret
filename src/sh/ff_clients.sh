# ---------- clients ----------
# client_plan: the client runs. Waves (FF_CLIENT_RATIO N): each client data NIC to one backend on every rail,
# spread over the backends, packed first-fit so no client NIC runs twice in a wave and no backend NIC serves
# more than N at once. All at once (full): each client NIC to one backend NIC, rails and backends round robin.
# Sets CT_* (waves) and FT_* (all at once) by task: K client, J its NIC, R rail, B backend (-1: none usable),
# W wave, S port slot, H share (flows on that backend NIC in that wave); CL_NW waves, CL_K servers per backend IP.
# client_plan [iteration]: each iteration moves every client NIC on to the next backend (all at once: the next
# rail, then the next backend), as backend pairing rotates; CL_ALL = iterations for every client NIC x backend NIC.
client_plan() {
    local k j r g=0 t w b nb off=$(( ${1:-1} - 1 ))
    local -a BL=()   # BL[r] = usable backends on rail r, in host order
    for r in "${RAILS[@]}"; do BL[r]=""; for k in "${ORDER[@]}"; do rail_ok $k $r && BL[r]+=" $k"; done; done
    local nbm=0; for r in "${RAILS[@]}"; do local -a bl=(${BL[r]}); (( ${#bl[@]} > nbm )) && nbm=${#bl[@]}; done
    CL_ALL=0; (( CL_WAVES )) && CL_ALL=$nbm; (( CL_FULL && NR * nbm > CL_ALL )) && CL_ALL=$(( NR * nbm )); CL_NBM=$nbm
    (( off )) ||     for r in "${RAILS[@]}"; do [[ -n ${BL[r]} ]] || log "WARNING: no usable backend NIC on rail $(rail_letter $r): client runs to it are skipped"; done
    local -a ck=($(for k in "${CLI[@]}"; do echo "$k ${T_HOST[$k]}"; done | sort -V -k2 | awk '{print $1}'))
    CT_K=(); CT_J=(); CT_R=(); CT_B=(); CT_W=(); CT_S=(); CT_H=(); FT_K=(); FT_J=(); FT_R=(); FT_B=(); FT_S=(); FT_H=()
    CL_NW=0; CL_K=1
    local -A WC=() WL=() FL=()
    for k in "${ck[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do
        for r in "${RAILS[@]}"; do
            local -a bl=(${BL[r]}); nb=${#bl[@]}
            t=${#CT_K[@]}; CT_K[t]=$k; CT_J[t]=$j; CT_R[t]=$r; CT_B[t]=$( (( nb )) && echo ${bl[(g + r + off) % nb]} || echo -1 ); CT_W[t]=-1
        done
        # all at once: rail by NIC count, backend by NIC count over the rails
        r=$(( (g + off) % NR )); local -a bl=(${BL[r]}); nb=${#bl[@]}
        t=${#FT_K[@]}; FT_K[t]=$k; FT_J[t]=$j; FT_R[t]=$r; FT_B[t]=$( (( nb )) && echo ${bl[((g + off) / NR) % nb]} || echo -1 )
        g=$(( g + 1 ))
    done; done
    if (( CL_WAVES )); then
        for (( t = 0; t < ${#CT_K[@]}; t++ )); do
            b=${CT_B[t]}; (( b >= 0 )) || continue
            for (( w = 0; ; w++ )); do
                [[ -z ${WC[$w,${CT_K[t]},${CT_J[t]}]} && ${WL[$w,$b,${CT_R[t]}]:-0} -lt $CL_R ]] && break
            done
            CT_W[t]=$w; CT_S[t]=${WL[$w,$b,${CT_R[t]}]:-0}; WL[$w,$b,${CT_R[t]}]=$(( CT_S[t] + 1 )); WC[$w,${CT_K[t]},${CT_J[t]}]=1
            (( w + 1 > CL_NW )) && CL_NW=$(( w + 1 ))
        done
        for (( t = 0; t < ${#CT_K[@]}; t++ )); do
            (( CT_W[t] >= 0 )) || continue
            CT_H[t]=${WL[${CT_W[t]},${CT_B[t]},${CT_R[t]}]}; (( CT_H[t] > CL_K )) && CL_K=${CT_H[t]}
        done
    fi
    if (( CL_FULL )); then
        for (( t = 0; t < ${#FT_K[@]}; t++ )); do
            b=${FT_B[t]}; (( b >= 0 )) || continue
            FT_S[t]=${FL[$b,${FT_R[t]}]:-0}; FL[$b,${FT_R[t]}]=$(( FT_S[t] + 1 ))
        done
        for (( t = 0; t < ${#FT_K[@]}; t++ )); do
            (( FT_B[t] >= 0 )) || continue
            FT_H[t]=${FL[${FT_B[t]},${FT_R[t]}]}; (( FT_H[t] > CL_K )) && CL_K=${FT_H[t]}
        done
    fi
}

# cl_check key ck cj b r dir: a client path check, written to $PATHS/key. dir c2b: from the client NIC to the
# backend rail IP; b2c: the reverse, from the backend. MTU: the smaller of the two ends (routed).
cl_check() {
    local key=$1 ck=$2 cj=$3 b=$4 r=$5 dir=$6
    if (( b < 0 )); then echo "DOWN no usable backend NIC on rail $(rail_letter $r)" > "$PATHS/$key"; return; fi
    if ! cl_ok $ck $cj; then echo "DOWN ${T_HOST[$ck]}: ${CSTATE[$ck,$cj]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $b $r; then echo "DOWN ${T_HOST[$b]}: ${RSTATE[$b,$r]}" > "$PATHS/$key"; return; fi
    local m1=${CMTU[$ck,$cj]:-1500} m2=${RMTU[$b,$r]:-1500}
    local size=$(( (m1 < m2 ? m1 : m2) - 28 ))
    if [[ $dir == c2b ]]; then
        ( out=$(rbash "${T_TARGET[$ck]}" "${CIP[$ck,$cj]}" "${RIP[$b,$r]}" "${CNIC[$ck,$cj]}" $size <<<"$PATH_SCRIPT" 2>&1)
          echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
    else
        ( out=$(rbash "${T_TARGET[$b]}" "${RIP[$b,$r]}" "${CIP[$ck,$cj]}" "${RNIC[$b,$r]}" $size <<<"$PATH_SCRIPT" 2>&1)
          echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
    fi
}

# cl_run key ck cj b r dir slot share phase: one client iperf3 run (or, with FF_SKIP_IPERF=1, the path check's
# record), appended to $PHASE_OUT as "src,dst,<result> share:N". c2b runs from the client to port FF_PORT+slot
# on the backend; b2c from the backend to the client's one server.
cl_run() {
    local key=$1 ck=$2 cj=$3 b=$4 r=$5 dir=$6 slot=$7 share=$8 ph=$9 mode=${10:-tcp} st src dst from port
    if [[ $dir == c2b ]]; then src=${CIP[$ck,$cj]}; dst=${RIP[$b,$r]:-none}; from=${T_TARGET[$ck]}; port=$(( FF_PORT + slot ))
    else src=${RIP[$b,$r]:-none}; dst=${CIP[$ck,$cj]}; from=${T_TARGET[$b]}; port=$FF_PORT; fi
    (( b >= 0 )) || { src=${CIP[$ck,$cj]}; dst=none; }
    st=$(cat "$PATHS/$key")
    local sh dh; sh=${T_HOST[$ck]}; dh=$( (( b >= 0 )) && echo "${T_HOST[$b]}" || echo - ); [[ $dir == b2c ]] && { sh=$dh; dh=${T_HOST[$ck]}; }
    if [[ $st != OK ]]; then
        echo "$ITER $ph $sh $src $dh $dst $st" >> "$PATH_EXCL"
        log "  skip $sh $src -> $dh $dst: $st"
        return
    fi
    if (( FF_SKIP_IPERF )); then echo "$src $dst" >> "$WORK/cpaths_ok"; return; fi
    if [[ $mode == udp ]]; then   # as run_path: the largest datagram neither end's MTU fragments
        local m1=${CMTU[$ck,$cj]:-1500} m2=${RMTU[$b,$r]:-1500}
        local len=$(( (m1 < m2 ? m1 : m2) - 28 ))
        ( out=$(rbash -T $(( FF_UDP_DURATION + 30 )) "$from" \
                  "$src" "$dst" "$port" "$FF_STREAMS" "$FF_UDP_DURATION" "$len" "$FF_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "$src,$dst,${out%%$'\n'*} share:$share" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(rbash -T $(( FF_DURATION + 30 )) "$from" \
              "$src" "$dst" "$port" "$FF_STREAMS" "$FF_DURATION" "$FF_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "$src,$dst,${out%%$'\n'*} share:$share" >> "$PHASE_OUT" ) &
}

# client_phase P: P = C1/C2 (waves; client->backend, backend->client) or F1/F2 (all at once). Path checks
# first, then the runs, wave by wave, with the drop counters of every client and backend around the phase.
client_phase() {
    local P=$1 dir t w nw pfx; dir=c2b; [[ $P == ?2 ]] && dir=b2c   # $2 = udp: the phase's UDP twin, U$P
    local -a TK TJ TR TB TW TS TH
    if [[ $P == C? ]]; then TK=("${CT_K[@]}"); TJ=("${CT_J[@]}"); TR=("${CT_R[@]}"); TB=("${CT_B[@]}"); TW=("${CT_W[@]}"); TS=("${CT_S[@]}"); TH=("${CT_H[@]}"); nw=$CL_NW
    else TK=("${FT_K[@]}"); TJ=("${FT_J[@]}"); TR=("${FT_R[@]}"); TB=("${FT_B[@]}"); TS=("${FT_S[@]}"); TH=("${FT_H[@]}"); nw=1
         for (( t = 0; t < ${#TK[@]}; t++ )); do TW[t]=$(( TB[t] >= 0 ? 0 : -1 )); done; fi
    (( ${#TK[@]} )) || return 0
    pfx=$(tr 'A-Z' 'a-z' <<<"$P")
    PATHS=$WORK/paths.client.$ITER.$P
    if [[ $2 == udp ]]; then client_udp_waves; return; fi
    mkdir -p "$PATHS"
    for (( t = 0; t < ${#TK[@]}; t++ )); do cl_check ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir; done
    wait
    CL_PLANNED=$(( CL_PLANNED + ${#TK[@]} ))
    local pre=$WORK/cdrops_pre.$ITER.$P post=$WORK/cdrops_post.$ITER.$P
    if (( ! FF_SKIP_IPERF )); then   # the same reads as a backend phase: drops, host receive and priority counters
        collect_drops "$pre" "${ELIG[@]}" "${CLI[@]}"
        collect_counters "$HOSTCTR_SCRIPT" "$pre.hc"; collect_counters "$PRIO_SCRIPT" "$pre.prio"
    fi
    phase_start
    local bad; bad=$(grep -Lx OK "$PATHS"/* | wc -l | tr -d ' ')
    log "Client phase $P ($( [[ $dir == c2b ]] && echo "clients -> backends" || echo "backends -> clients")$( [[ $P == F? ]] && echo ", all at once")): ${#TK[@]} runs in $nw wave$( (( nw > 1 )) && echo s); path checks $(( ${#TK[@]} - bad )) OK, $bad excluded$( (( FF_SKIP_IPERF )) || echo "; start $PT0")"
    # runs no wave could take (no usable backend on their rail) are recorded once, as skips
    for (( t = 0; t < ${#TK[@]}; t++ )); do (( TW[t] < 0 )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir 0 0 $P; done
    for (( w = 0; w < nw; w++ )); do
        PHASE_OUT=$WORK/cphase.$ITER.$P.$w; : > "$PHASE_OUT"
        (( FF_SKIP_IPERF )) || echo "### client iteration:$ITER phase:$P$( (( nw > 1 )) && echo " wave:$(( w + 1 ))/$nw")" >> "$CRESULTS"
        for (( t = 0; t < ${#TK[@]}; t++ )); do
            (( TW[t] == w )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir ${TS[t]} ${TH[t]} $P
        done
        wait
        (( FF_SKIP_IPERF )) && continue
        column -t < "$PHASE_OUT" | tee -a "$CRESULTS"
        lock_all touch
    done
    (( FF_SKIP_IPERF )) && return 0
    phase_end $P
    local errs; errs=$(cat "$WORK"/cphase.$ITER.$P.* | grep -c ",ERROR")
    (( errs > 0 )) && { log "WARNING: $errs client runs in phase $P returned no result (lines with ERROR above):"; log_hist "$WORK"/cphase.$ITER.$P.*; }
    collect_drops "$post" "${ELIG[@]}" "${CLI[@]}"
    collect_counters "$HOSTCTR_SCRIPT" "$post.hc"; collect_counters "$PRIO_SCRIPT" "$post.prio"; collect_temps "iter${ITER}_$P"
    hostctr_delta "iter${ITER}_client$P" "$pre.hc" "$post.hc"; hc_log "client phase $P" "$post.hc"
    awk -v it="iter${ITER}_client$P" '#@awk ff_client_phase.prio' "$pre.prio" "$post.prio" > "$WORK/cprio_delta"
    cat "$WORK/cprio_delta" >> "$COLLECT_DIR/prio_counters.txt"
    awk 'tolower($3) !~ /byte|packet/ || $3 ~ /^rdma:/' "$WORK/cprio_delta" | sort -k4 -rn > "$WORK/cprio_events"
    if [[ -s $WORK/cprio_events ]]; then
        log "  Pause/ECN/discard/RDMA counters that rose in client phase $P (top 5 of $(wc -l < "$WORK/cprio_events" | tr -d ' ')):"
        head -n 5 "$WORK/cprio_events" | cut -d' ' -f2- | column -t | sed 's/^/#     /' >&2
    else log "  No pause/ECN/discard/RDMA counter rose in client phase $P ($(wc -l < "$post.prio" | tr -d ' ') counters read)"; fi
    local d; d=$(compute_drops "$pre" "$post" "iter${ITER}_client$P")
    if [[ -n $d ]]; then log "Drops during client phase $P:"; echo "$d" | awk '{NF--; print}' | column -t | sed 's/^/#   /' >&2; echo "$d" >> "$DROP_TOTALS"
    else log "No drop counter increases in client phase $P ($(wc -l < "$post" | tr -d ' ') NICs read)"; fi
    local flaps; flaps=$(awk -v it="iter${ITER}_client$P" '#@awk ff_client_phase.flaps' "$pre" "$post")
    if [[ -n $flaps ]]; then
        log "WARNING: links went down during client phase $P (host_nic ip carrier-down count):"
        echo "$flaps" | cut -d' ' -f2- | column -t | sed 's/^/#   /' >&2; echo "$flaps" >> "$COLLECT_DIR/link_flaps.txt"
    fi
}

# client_udp_waves (from client_phase, on its tasks): the UDP twin U$P of client phase P, the same runs and
# waves, reusing P's path checks; UDP host and NIC counters around it, as U1/U2
client_udp_waves() {
    local U=U$P a=$WORK/cudp.$ITER.$P.pre b=$WORK/cudp.$ITER.$P.post
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"
    phase_start
    log "Client phase $U ($( [[ $dir == c2b ]] && echo "clients -> backends" || echo "backends -> clients")$( [[ $P == F? ]] && echo ", all at once"), UDP -b 0): ${#TK[@]} runs in $nw wave$( (( nw > 1 )) && echo s); start $PT0"
    for (( w = 0; w < nw; w++ )); do
        PHASE_OUT=$WORK/cphase.$ITER.$U.$w; : > "$PHASE_OUT"
        echo "### iteration:$ITER phase:$U$( (( nw > 1 )) && echo " wave:$(( w + 1 ))/$nw")" >> "$UDP_RESULTS"
        for (( t = 0; t < ${#TK[@]}; t++ )); do
            (( TW[t] == w )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir ${TS[t]} ${TH[t]} $U udp
        done
        wait
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        lock_all touch
    done
    phase_end $U
    local errs; errs=$(cat "$WORK"/cphase.$ITER.$U.* | grep -c ",ERROR")
    (( errs > 0 )) && { log "WARNING: $errs client runs in phase $U returned no result (lines with ERROR above):"; log_hist "$WORK"/cphase.$ITER.$U.*; }
    collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"; collect_counters "$TXCTR_SCRIPT" "$b.tx"
    collect_temps "iter${ITER}_$U"
    udp_close $U "$a" "$b"
}

# clients_iter: this iteration's client phases (backends moved on by one from the last iteration)
clients_iter() {
    (( ${#CLI[@]} )) || return 0
    client_plan $ITER
    (( CL_K <= CL_K0 )) || log "WARNING: iteration $ITER plans $CL_K client flows on one backend NIC, more than the $CL_K0 servers started; the extra runs fail"
    log "---- Clients, iteration $ITER: $( (( CL_WAVES )) && echo "$CL_NW wave$( (( CL_NW > 1 )) && echo s) each way, at most $CL_R client NIC$( (( CL_R > 1 )) && echo s) per backend NIC")$( (( CL_WAVES && CL_FULL )) && echo ", then ")$( (( CL_FULL )) && echo "all at once each way") ----"
    (( CL_WAVES )) && { client_phase C1; client_phase C2; }
    (( CL_FULL )) && { client_phase F1; client_phase F2; }
    if [[ $FF_UDP == 1 ]]; then   # the UDP twins, after the TCP phases as U1/U2 follow phases 1/2
        (( CL_WAVES )) && { client_phase C1 udp; client_phase C2 udp; }
        (( CL_FULL )) && { client_phase F1 udp; client_phase F2 udp; }
    fi
    return 0
}
