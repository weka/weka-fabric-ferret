function f1(x) { return x == "-" ? x : sprintf("%.1f", x) }
function sname(g, s) { if (g == "bmc") sub(/_[Tt]emp$/, "", s); gsub(/_/, " ", s); return s }
function fl(v, f) { return f == "-" || f == "" ? v : "**" v " " f "**" }
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "|"; al = "|"; for (i = 1; i <= NF; i++) { hdr = hdr " " $i " |"; al = al (i >= 7 && i < NF ? "--:|" : "---|") } hdr = hdr "\n" al; next }
    ns++; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FILENAME == ARGV[3] { if (FNR > 1 && $12 ~ /^nodata/) nd[++nn] = "- **" $1 "** " $2 ": " substr($12, 8); next }
FILENAME == ARGV[4] { p = $1 "-" $2; if (!(p in pc)) { pord[++np] = p; pg[p] = $1; pt[p] = $2 }
    if ($1 == "bmc") { c = $5; if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cn[p, nc[p]] = sname($1, $5); cr[p, c] = f1($9) }
        else if (cr[p, c] != f1($9)) crmix[p, c] = 1
        cell[p, c, $6] = f1($7); ccr[p, c, $6] = f1($9); cf[p, c, $6] = $10 }
    else { c = $4 " " $3; if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cn[p, nc[p]] = ($4 == "-" ? $3 : $4 " " $3) }
        k = p SUBSEP c SUBSEP $6; n[k]++; if (n[k] == 1 || $7 + 0 > mx[k]) mx[k] = $7 + 0
        lst[k] = lst[k] (lst[k] == "" ? "" : " · ") sname($1, $5) " " fl(f1($7), $10); if ($10 != "-") wf[k] = $10 }
    has[p, $6] = 1; pc[p]++; next }
{ ho[++nho] = $1 }
function row(l,   q, i, m, s) { m = split(l, q, " "); s = "|"; for (i = 1; i <= m; i++) s = s " " (i == m && q[i] != "-" ? "**" q[i] "**" : q[i]) " |"; return s }
END {
    split("inlet cpu gpu mem nvme nic other", tyo, " "); split("Inlet CPU GPU Mem NVMe NIC Other", tyn, " ")
    for (i = 1; i <= 7; i++) tname[tyo[i]] = tyn[i]
    gname["bmc"] = "BMC / IPMI"; gname["os"] = "OS (hwmon, nvidia-smi)"; gshort["bmc"] = "BMC"; gshort["os"] = "OS"
    printf "# Thermals: %s\n\n%s to %s UTC · %s · hwmon + nvidia-smi%s · thermals_capture %s\n\n", label, start, end, (nsamp > 1 ? nsamp " samples (tables show the max)" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), ver
    printf "**%s** · %d of %d hosts gave readings · %d sensors · %d flagged · %d no-data%s\n", res, hwd, nt, ns, nf, nn, (unreach ? " · " unreach " unreachable (no ssh connection)" : "")
    s = ""
    for (t = 1; t <= 7; t++) { ty = tyo[t]; tc = ((("os-" ty) in pc) ? pc["os-" ty] : 0) + ((("bmc-" ty) in pc) ? pc["bmc-" ty] : 0)
        if (tc) s = s " · [" tname[ty] "](#" ty ") (" tc ")" }
    print "\n**Contents:** [Overview](#overview)" s
    print "\n## Overview"
    if (nn) { print "\n### No temperature data (never read as cool)\n"; for (i = 1; i <= nn; i++) print nd[i] }
    if (nh) { print "\n### Hottest reading per host and type (°C)\n\n| Host | Inlet | CPU | GPU | Mem | NVMe | NIC | Other | Flags |\n|---|--:|--:|--:|--:|--:|--:|--:|---|"
        for (i = 1; i <= nh; i++) { split(hm[i], q, " "); s = "| " q[1] " |"; for (j = 2; j <= 8; j++) s = s " " q[j] " |"; print s " " (q[9] == "-" ? "-" : "**" q[9] "**") " |" } }
    if (nf) { print "\n### Flagged sensors\n\n" hdr; for (i = 1; i <= nf; i++) print row(fr[i]) }
    print "\nFlags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "°C of high" (nsamp > 1 ? "; rise = up more than " rise "°C over the samples" : "") "."
    for (t = 1; t <= 7; t++) { ty = tyo[t]; if (!((("os-" ty) in pc) || (("bmc-" ty) in pc))) continue
        print "\n## " tname[ty]
        for (gi = 1; gi <= 2; gi++) { g = (gi == 1 ? "os" : "bmc"); p = g "-" ty; if (!(p in pc)) continue
        printf "\n### %s · %d reading%s\n\n", gname[g], pc[p], (pc[p] == 1 ? "" : "s")
        s = "| Host |"; a = "|---|"
        for (j = 1; j <= nc[p]; j++) { c = col[p, j]
            s = s " " cn[p, j] (g == "bmc" ? (((p, c) in crmix) ? " (temp / crit)" : (cr[p, c] == "-" ? "" : " (crit " cr[p, c] ")")) : "") " |"; a = a (g == "bmc" ? "--:|" : "---|") }
        print s "\n" a
        for (h = 1; h <= nho; h++) { x = ho[h]; if (!((p, x) in has)) continue
            s = "| " x " |"
            for (j = 1; j <= nc[p]; j++) { c = col[p, j]
                if (g == "bmc") s = s " " (((p, c, x) in cell) ? fl(cell[p, c, x] (((p, c) in crmix) ? " / " ccr[p, c, x] : ""), cf[p, c, x]) : "-") " |"
                else { k = p SUBSEP c SUBSEP x; s = s " " (!(k in n) ? "-" : n[k] <= 4 ? lst[k] : fl("max " f1(mx[k]) " of " n[k] " sensors", wf[k])) " |" } }
            print s } } }
    print "\nEvery single reading is in the jsonl (-o jsonl)." }
