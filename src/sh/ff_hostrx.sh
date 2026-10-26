# Kernel log lines that point at the receive path or the NIC (a match is a lead, not a verdict)
KLOG_RE='aer|pcie bus error|link is down|tx timeout|transmit timeout|watchdog|hung_task|blocked for more than|out of memory|oom-kill|mlx5.*(err|fail|timeout|health)'

# host_rx.txt: per host, rail NIC config + receive counters over the run + iperf3 CPU + kernel log leads, with flags.
# Files: nicmap, ipmap, rx config, hostinfo (host governor irqbalance klog_hits), TCP results, host_counters, prio_counters.
HOSTRX_AWK='
#@awk ff_hostrx'

# hostinfo_line host: "host governor irqbalance klog_hits sysinfo_state iperf3_threads" from its sysinfo
hostinfo_line() {
    local h=$1 g i n s t
    g=-; [[ -f $SI/$h/cpu-governor ]] && g=$(awk '$1 ~ /^[0-9]+$/ {printf "%s%s", s, $2; s = "+"} /^n\/a/ {printf "-"}' "$SI/$h/cpu-governor")
    i=$(cat "$SI/$h/irqbalance" 2>&1); [[ $i == running ]] && i=on || { [[ $i == "not running" ]] && i=off || i=-; }
    n=-; [[ -f $SI/$h/kernel-log ]] && n=$(grep -c -i -E "$KLOG_RE" "$SI/$h/kernel-log")
    s=ok; [[ -d $SI/$h ]] || s=missing; [[ -n ${SI_CUT[$h]} ]] && s=cut
    # iperf3 threads per receiving process: one per stream from 3.16 (its own --version, from sysinfo)
    t=1; [[ -f $SI/$h/iperf3 ]] && (( $(awk 'match($0, /iperf 3\.[0-9]+/) {print substr($0, RSTART + 8, RLENGTH - 8) + 0; exit}' "$SI/$h/iperf3") + 0 >= 16 )) && t=$FF_STREAMS
    echo "$h ${g:--} $i $n $s $t"
}

host_rx() {  # writes $COLLECT_DIR/host_rx.txt (and client_rx.txt) and prints the flagged hosts
    local k
    rx_config > "$WORK/rxcfg"
    for k in "${ELIG[@]}"; do hostinfo_line "${T_HOST[$k]}"; done > "$WORK/hostinfo"
    # iperf3 CPU from every run a host was in, the client runs included
    { cat "$1"; [[ -f ${CRESULTS:-} ]] && cat "$CRESULTS"; } | grep "Gbits/sec" > "$WORK/rx_results"
    awk '{r[$1]++; a[$1] += $2} END {for (h in r) print h, r[h], a[h]}' "$WORK/hc_reads" > "$WORK/hcreads"
    [[ -f $WORK/prio_post ]] || : > "$WORK/prio_post"
    awk -v ns="$HC_READS" -v RL="${LETTERS:0:NR}" "$HOSTRX_AWK" "$WORK/nicmap" "$WORK/ipmap" "$WORK/rxcfg" "$WORK/hostinfo" "$WORK/rx_results" \
        "$COLLECT_DIR/host_counters.txt" "$COLLECT_DIR/prio_counters.txt" "$WORK/hcreads" "$WORK/prio_post" \
        | { read -r hdr; echo "$hdr"; sort -V; } > "$COLLECT_DIR/host_rx.txt"
    (( ${#CLI[@]} )) && client_rx
    return 0
}

# client_rx: host_rx.txt's columns for the clients -> client_rx.txt, NIC slots 1..N in clients.txt order
client_rx() {
    local k j h nm=0 sl=""
    for k in "${CLI[@]}"; do (( CN[$k] > nm )) && nm=${CN[$k]}; done
    for (( j = 1; j <= nm; j++ )); do sl+=$j; done
    : > "$WORK/cnicmap"; : > "$WORK/cipslot"; : > "$WORK/crxcfg"; : > "$WORK/chostinfo"
    for k in "${CLI[@]}"; do
        h=${T_HOST[$k]}
        for (( j = 0; j < CN[$k]; j++ )); do
            echo "${h}_${CNIC[$k,$j]} $h $(( j + 1 ))" >> "$WORK/cnicmap"
            [[ ${CIP[$k,$j]} != none ]] && echo "${CIP[$k,$j]} $h $(( j + 1 ))" >> "$WORK/cipslot"
            rx_one "$h" $(( j + 1 )) "$SI/$h/nic-${CNIC[$k,$j]}" >> "$WORK/crxcfg"
        done
        hostinfo_line "$h" >> "$WORK/chostinfo"
    done
    awk -v ns="$HC_READS" -v RL="$sl" "$HOSTRX_AWK" "$WORK/cnicmap" "$WORK/cipslot" "$WORK/crxcfg" "$WORK/chostinfo" "$WORK/rx_results" \
        "$COLLECT_DIR/host_counters.txt" "$COLLECT_DIR/prio_counters.txt" "$WORK/hcreads" "$WORK/prio_post" \
        | { read -r hdr; echo "Client ${hdr#Host }"; sort -V; } > "$COLLECT_DIR/client_rx.txt"
}

# UDP loss placement, the same rule as the dashboard: per phase and receiving host,
# unaccounted = lost - (that host's InErrors + backlog drops + rail-NIC drops), floored at 0. The kernel
# also adds backlog drops to rx_dropped, so NIC = max(0, rx_dropped - backlog) + rx_out_of_buffer.
# Sender TX = datagrams the sender NIC never put on the wire (udp_expected.txt, by run, charged to the run's
# receiver), taken out before unaccounted. Expected = what overload alone loses of what reached the wire;
# beyond = unaccounted above it, per host.
# Files: udp_expected.txt, ipmap (ip host rail), nicmap (host_nic host rail), UDP results, host counters, NIC drops.
# -v t="iterN Ux" limits it to one phase. Prints: lost sent socket nic backlog unaccounted over expected beyond tx
# (over: buckets beyond the loss).
UDP_ATTR_AWK='
#@awk ff_udp_attr'

udp_attr() {  # [iterN Ux] -> "lost sent socket nic backlog unaccounted over expected beyond tx"
    awk -v t="$1" "$UDP_ATTR_AWK" "$COLLECT_DIR/udp_expected.txt" "$WORK/uipmap" "$WORK/unicmap" "$UDP_RESULTS" \
        "$COLLECT_DIR/udp_host_counters.txt" "$COLLECT_DIR/udp_nic_drops.txt"
}
