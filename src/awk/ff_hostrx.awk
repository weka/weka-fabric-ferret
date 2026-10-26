# by argument position, not FNR: an empty file (no counter rose) has no first line and would shift the count
FNR == 1 { for (f = 1; f < ARGC; f++) if (ARGV[f] == FILENAME) break }
f == 1 { nh[$1] = $2; next }
f == 2 { ih[$1] = $2; next }
f == 3 { hosts[$1] = 1; numa[$1, $2] = $3; ring[$1, $2] = $4; pcie[$1, $2] = $5
         if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) fl[$1] = fl[$1] ",ring" $2 "<max"
         if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) fl[$1] = fl[$1] ",pcie" $2 "<max" }
         next }
f == 4 { gov[$1] = $2; irq[$1] = $3; kl[$1] = $4; th[$1] = $6; hosts[$1] = 1
         if ($5 == "missing") fl[$1] = fl[$1] ",sysinfo_missing"; else if ($5 == "cut") fl[$1] = fl[$1] ",sysinfo_partial"
         if ($2 != "-" && $2 != "performance") fl[$1] = fl[$1] ",gov:" $2; if ($4 > 0) fl[$1] = fl[$1] ",klog"; next }
f == 5 { split($1, ip, ","); for (i = 1; i <= NF; i++) if ($i ~ /^cpu:/) { split(substr($i, 5), u, "/")
             if (u[2] ~ /^[0-9.]+$/ && (!(ih[ip[2]] in rc) || u[2] + 0 > rc[ih[ip[2]]])) rc[ih[ip[2]]] = u[2] + 0
             if (u[1] ~ /^[0-9.]+$/ && (!(ih[ip[1]] in sc) || u[1] + 0 > sc[ih[ip[1]]])) sc[ih[ip[1]]] = u[1] + 0 }
         next }
f == 6 { k = $3; sub(/:.*/, "", k)
         if (k == "softnet_dropped") sd[$2] += $4; else if (k == "softnet_squeezed") sq[$2] += $4
         else if (k ~ /^(TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop)$/) td[$2] += $4
         else if (k ~ /^aer_/) ae[$2] += $4
         next }
f == 7 { if ($3 !~ /^rdma:/ && tolower($3) ~ /discard|out_of_buffer/) nd[nh[$2]] += $4; next }
f == 8 { hr[$1] = $2; ha[$1] = $3; next }
f == 9 { if ($2 !~ /^rdma:/ && tolower($2) ~ /discard|out_of_buffer/) dc[nh[$1]] = 1 }
function v(a, k) { return (k in a) ? a[k] : "-" }
END {
    nr = length(RL); hn = "NUMA_"; hg = ""; hp = ""
    for (i = 1; i <= nr; i++) { lt = substr(RL, i, 1); hn = hn (i > 1 ? "/" : "") lt; hg = hg " Ring_" lt; hp = hp " PCIe_" lt }
    print "Host " hn hg hp " Governor IRQbal RcvCPU% RcvThr% SndCPU% Softnet_drop Squeeze TCP_rcv_drop NIC_discard AER Klog Flags"
    for (h in hosts) {
        # "-" = not read (ssh failed, no AER in sysfs, no discard counter on this driver): unknown, not zero
        cr = (h in hr) ? hr[h] : 0
        if (cr == 0) fl[h] = fl[h] ",counters_unread"; else if (cr < ns) fl[h] = fl[h] ",counters_partial"
        SD = cr ? sd[h] + 0 : "-"; SQ = cr ? sq[h] + 0 : "-"; TD = cr ? td[h] + 0 : "-"
        ND = (h in dc) ? nd[h] + 0 : "-"; AE = (ha[h] > 0) ? ae[h] + 0 : "-"
        if (SD > 0) fl[h] = fl[h] ",softnet_drop"; if (TD > 0) fl[h] = fl[h] ",tcp_rcv_drop"
        if (ND > 0) fl[h] = fl[h] ",nic_discard"; if (AE > 0) fl[h] = fl[h] ",aer"
        # iperf3 3.16+ runs a thread per stream and sums their CPU, so judge per thread: raw / threads (th: FF_STREAMS
        # on 3.16+, else 1; an unknown version counts as 1, which can only flag more)
        RT = (h in rc) ? sprintf("%.1f", rc[h] / ((th[h] + 0 > 0) ? th[h] : 1)) : "-"
        if (RT != "-" && RT + 0 >= 90) fl[h] = fl[h] ",rcv_cpu>=90/thread"
        nu = ""; ri = ""; pc = ""
        for (i = 1; i <= nr; i++) { lt = substr(RL, i, 1); nu = nu (i > 1 ? "/" : "") v(numa, h SUBSEP lt); ri = ri " " v(ring, h SUBSEP lt); pc = pc " " v(pcie, h SUBSEP lt) }
        printf "%s %s%s%s %s %s %s %s %s %s %s %s %s %s %s %s\n", h, nu, ri, pc, v(gov, h), v(irq, h),
            ((h in rc) ? rc[h] : "-"), RT, ((h in sc) ? sc[h] : "-"), SD, SQ, TD, ND, AE, v(kl, h), (fl[h] == "" ? "-" : substr(fl[h], 2))
    }
}
