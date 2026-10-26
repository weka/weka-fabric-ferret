# Run lock: take on every tested host before load; another live run (its lock refreshed within
# about two iterations) stops this one, since each run kills stray iperf3 servers on its hosts.
take_locks() {
    local k busy other
    RUN_ID="$(hostname -s)-$$-$START_TS"
    cross_waves $(( ${#ELIG[@]} / 2 ))   # phase 2 waves stretch an iteration
    local max=$(( 2 * ((1 + XW) * FF_DURATION + (FF_UDP == 1 ? (1 + XW) * FF_UDP_DURATION : 0)) + 300 ))
    local info="since=$(date -u +%Y-%m-%dT%H:%M:%SZ),from=$(hostname -s),user=$(id -un)"   # no spaces: args are re-split remotely
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" take "$RUN_ID" "$info" "$max" <<<"$LOCK_SCRIPT" 2>&1)
          echo "${T_HOST[$k]} ${out%%$'\n'*}" > "$WORK/lock.$k" ) &
    done
    wait
    LOCKED=1   # release whatever we took, even if we stop below
    save_state
    busy=$(cat "$WORK"/lock.* | grep ' BUSY ')
    other=$(cat "$WORK"/lock.* | grep -v -E ' (OK|BUSY .*)$')
    [[ -n $other ]] && { log "WARNING: could not take the run lock on:"; echo "$other" | sed 's/^/#   /' >&2; }
    [[ -n $busy ]] || return 0
    if [[ $FF_IGNORE_LOCK == 1 ]]; then
        log "WARNING: FF_IGNORE_LOCK=1: running although another run holds:"; echo "$busy" | sed 's/^/#   /' >&2
    else
        die "another fabric_ferret run is active on $(echo "$busy" | wc -l | tr -d ' ') hosts (it would lose its iperf3 servers to this one): $(echo "$busy" | head -n 3 | tr '\n' ';') wait for it, or set FF_IGNORE_LOCK=1 if it is dead"
    fi
}

lock_all() {  # touch | release on every tested host and client (only our own lock is changed)
    local k
    for k in "${ELIG[@]}" "${CLI[@]}"; do rbash "${T_TARGET[$k]}" "$1" "$RUN_ID" <<<"$LOCK_SCRIPT" >> "$WORK/lock.log" 2>&1 & done
    wait
}
