stop_servers() {
    (( ${#STARTED[@]} > 0 )) || return 0
    local k
    log "Stopping iperf3 on ${#STARTED[@]} hosts..."
    for k in "${!STARTED[@]}"; do rsh "${T_TARGET[$k]}" $SUDO pkill -x iperf3 >> "$WORK/cleanup.log" 2>&1 & done
    wait
    STARTED=()
}

# cleanup's inputs, so the wrapper can finish cleanup when main dies without it: SIGKILL, OOM, or (seen 1 in ~76
# Ctrl-C runs under load) bash running the INT trap's exit but never the EXIT trap. Written whole, then renamed.
save_state() {
    [[ -n $STATE_FILE ]] || return 0
    declare -p WORK SOCKET_DIR COLLECT_DIR LOADED DONE LOCKED RUN_ID STARTED T_TARGET REACH_ONLY ELIG CLI SSH_OPTS SUDO \
        FF_SSH_USER 2>&1 | grep '^declare ' > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

cleanup() {
    local rc=$? k   # first: bash 5.1 would otherwise end a piped main with cleanup's last status
    trap '' INT TERM HUP PIPE   # nothing may cut cleanup short: a second signal, or a dead tee (EPIPE, not death)
    stop_servers
    [[ -n $LOCKED ]] && lock_all release
    for k in "${T_TARGET[@]}" "${!REACH_ONLY[@]}"; do
        ssh -O exit -o "ControlPath=$SOCKET_DIR/%C" -l "$FF_SSH_USER" "$k" >> "$WORK/cleanup.log" 2>&1 &
    done
    wait
    if [[ -z $DONE ]]; then
        if [[ -n $LOADED ]]; then { [[ -f $FF_RUNLOG ]] && cp "$FF_RUNLOG" "$COLLECT_DIR/run.log"; log "Run did not finish; partial data left in $COLLECT_DIR"; }
        else rm -rf "${COLLECT_DIR:?}"; fi
    fi
    rm -rf "${SOCKET_DIR:?}" "${WORK:?}"
    [[ -z $STATE_FILE ]] || rm -f "$STATE_FILE"   # last: the wrapper reruns a cleanup cut short
    exit $rc
}
