function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function fc(f) { return f ~ /^crit/ ? "crit" : f ~ /^high/ ? "high" : f ~ /^near/ ? "near" : f ~ /rise/ ? "rise" : "" }
function f1(x) { return x == "-" ? x : sprintf("%.1f", x) }
function num(x) { return x == "-" ? "" : x }
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "<thead><tr>"; for (i = 1; i <= NF; i++) hdr = hdr "<th data-col=\"" (i - 1) "\"" (i >= 7 && i < NF ? " class=\"n\"" : "") ">" $i "</th>"; hdr = hdr "</tr></thead>"; next }
    ns++; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FILENAME == ARGV[3] { if (FNR > 1 && $12 ~ /^nodata/) nd[++nn] = "<tr><td class=\"host\">" e($1) "</td><td>" e($2) "</td><td>" e(substr($12, 8)) "</td></tr>"; next }
FILENAME == ARGV[4] { p = $1 "-" $2; if (!(p in pc)) { pord[++np] = p; pg[p] = $1; pt[p] = $2 }
    c = $3 ":" $5 "@" $4
    if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cchip[p, nc[p]] = $3; cd[p, nc[p]] = $4; cs[p, nc[p]] = sname($1, $5); cr[p, c] = f1($9) }
    else if (cr[p, c] != f1($9)) crmix[p, c] = 1
    cell[p, c, $6] = f1($7); ccr[p, c, $6] = f1($9); cv[p, c, $6] = $7; cf[p, c, $6] = fc($10); has[p, $6] = 1; pc[p]++; next }
function sname(g, s) { if (g == "bmc") sub(/_[Tt]emp$/, "", s); gsub(/_/, " ", s); return s }
FILENAME == ARGV[5] { ho[++nho] = $1; next }
FILENAME == ARGV[6] { ur[++nur] = "<tr><td class=\"host\">" e($1) "</td><td>" e($2) "</td></tr>"; next }
function row(l,   p, i, n, s, c) { n = split(l, p, " "); c = fc(p[n]); s = "<tr" (c != "" ? " class=\"" c "\"" : "") ">"
    for (i = 1; i <= n; i++) s = s "<td" (i >= 7 && i < n ? " class=\"n\" data-v=\"" num(p[i]) "\"" : "") ">" e(p[i]) "</td>"; return s "</tr>" }
END {
    split("inlet cpu gpu mem nvme nic other", tyo, " "); split("Inlet CPU GPU Mem NVMe NIC Other", tyn, " ")
    for (i = 1; i <= 7; i++) tname[tyo[i]] = tyn[i]
    gname["bmc"] = "BMC / IPMI"; gname["os"] = "OS (hwmon, nvidia-smi)"
    printf "<header><h1>Thermals: %s</h1><div class=\"mut\">%s to %s UTC &middot; %s &middot; hwmon + nvidia-smi%s &middot; thermals_capture %s</div></header>\n", e(label), e(start), e(end), (nsamp > 1 ? nsamp " samples (cells show the max)" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), e(ver)
    print "<div class=\"body\"><nav id=\"nav\" aria-label=\"Sections\">"
    print "<button type=\"button\" data-panel=\"overview\" aria-selected=\"true\"><span>Overview</span><span class=\"count\">" nh "</span></button>"
    print "<div class=\"navgroup\">By type</div>"
    for (t = 1; t <= 7; t++) { ty = tyo[t]; tc = ((("os-" ty) in pc) ? pc["os-" ty] : 0) + ((("bmc-" ty) in pc) ? pc["bmc-" ty] : 0); if (!tc) continue
        print "<button type=\"button\" data-panel=\"" ty "\" aria-selected=\"false\"><span>" tname[ty] "</span><span class=\"count\">" tc "</span></button>" }
    print "<div id=\"nav-footer\"><button type=\"button\" data-panel=\"notread\" aria-selected=\"false\"" (nn + nur ? " class=\"warn\"" : "") "><span>Not read</span><span class=\"count\">" nn + nur "</span></button></div>"
    print "</nav><main>"
    print "<section class=\"panel\" id=\"p-overview\"><h2>Overview</h2>"
    printf "<div class=\"card\"><span class=\"res %s\">%s</span> &middot; %d of %d hosts gave readings &middot; %d sensors &middot; %d flagged &middot; %d no-data%s%s</div>\n", res, res, hwd, nt, ns, nf, nn, (unreach ? " &middot; " unreach " unreachable (no ssh connection)" : ""), (nn + nur ? " &middot; <a href=\"#notread\" data-panel=\"notread\">see Not read</a>" : "")
    if (nh) { print "<h3>Hottest reading per host and type (&deg;C)</h3><div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Host</th><th class=\"n\" data-col=\"1\">Inlet</th><th class=\"n\" data-col=\"2\">CPU</th><th class=\"n\" data-col=\"3\">GPU</th><th class=\"n\" data-col=\"4\">Mem</th><th class=\"n\" data-col=\"5\">NVMe</th><th class=\"n\" data-col=\"6\">NIC</th><th class=\"n\" data-col=\"7\">Other</th><th data-col=\"8\">Flags</th></tr></thead><tbody>"
        for (i = 1; i <= nh; i++) { split(hm[i], q, " ")
            w = q[9] ~ /crit/ ? "crit" : q[9] ~ /high/ ? "high" : q[9] ~ /near/ ? "near" : q[9] ~ /rise/ ? "rise" : ""
            s = "<tr" (w != "" ? " class=\"" w "\"" : "") "><td class=\"host\">" e(q[1]) "</td>"; for (j = 2; j <= 8; j++) s = s "<td class=\"n\" data-v=\"" num(q[j]) "\">" q[j] "</td>"
            print s "<td>" e(q[9]) "</td></tr>" }
        print "</tbody></table></div>" }
    if (nf) { print "<h3>Flagged sensors</h3><div class=\"wrap\"><table class=\"sortable\">" hdr "<tbody>"; for (i = 1; i <= nf; i++) print row(fr[i]); print "</tbody></table></div>" }
    print "<p class=\"mut\">Flags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "&deg;C of high" (nsamp > 1 ? "; rise = up more than " rise "&deg;C over the samples" : "") ".</p></section>"
    for (t = 1; t <= 7; t++) { ty = tyo[t]; if (!((("os-" ty) in pc) || (("bmc-" ty) in pc))) continue
        printf "<section class=\"panel\" id=\"p-%s\"><h2>%s</h2><p class=\"mut\">The OS table (hwmon, nvidia-smi) and the BMC / IPMI table. One row per host; each cell is the %s in &deg;C, with the crit threshold under the sensor name (in the cell when hosts differ); flagged readings are shaded. Click a sensor to sort.</p>\n", ty, tname[ty], (nsamp > 1 ? "highest reading" : "reading")
        for (g = 1; g <= 2; g++) { p = (g == 1 ? "os" : "bmc") "-" ty; if (!(p in pc)) continue
        printf "<h3>%s <span class=\"mut\">&middot; %d reading%s</span></h3>\n", gname[pg[p]], pc[p], (pc[p] == 1 ? "" : "s")
        two = 0; for (j = 1; j <= nc[p]; j++) { gs[j] = (j == 1 || cd[p, j] != cd[p, j - 1] || cchip[p, j] != cchip[p, j - 1]); if (cd[p, j] != "-") two = 1 }
        s = "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\"" (two ? " rowspan=\"2\"" : "") ">Host</th>"
        if (two) { for (j = 1; j <= nc[p]; j = k) { for (k = j + 1; k <= nc[p] && !gs[k]; k++) ; s = s "<th class=\"grp\" colspan=\"" (k - j) "\">" (cd[p, j] != "-" ? e(cd[p, j]) "<span class=\"chip\">" e(cchip[p, j]) "</span>" : e(cchip[p, j])) "</th>" }
            s = s "</tr><tr>" }
        for (j = 1; j <= nc[p]; j++) { c = col[p, j]
            s = s "<th class=\"n" (gs[j] ? " gs" : "") "\" data-col=\"" j "\">" e(cs[p, j]) "<span class=\"dev\">" (((p, c) in crmix) ? "temp / crit" : (cr[p, c] == "-" ? "no crit" : "crit " cr[p, c])) "</span></th>" }
        print s "</tr></thead><tbody>"
        for (h = 1; h <= nho; h++) { x = ho[h]; if (!((p, x) in has)) continue
            s = "<tr><td class=\"host\">" e(x) "</td>"
            for (j = 1; j <= nc[p]; j++) { c = col[p, j]; k = "n" (gs[j] ? " gs" : "")
                s = s (((p, c, x) in cell) ? "<td class=\"" k (cf[p, c, x] != "" ? " " cf[p, c, x] : "") "\" data-v=\"" num(cv[p, c, x]) "\">" cell[p, c, x] (((p, c) in crmix) ? " / " ccr[p, c, x] : "") "</td>" : "<td class=\"" k "\" data-v=\"\">-</td>") }
            print s "</tr>" }
        print "</tbody></table></div>" }
        print "</section>" }
    print "<section class=\"panel\" id=\"p-notread\"><h2>Not read</h2>"
    print "<h3>No temperature data (" nn ")</h3><p class=\"mut\">Reached, but a source gave no reading; never shown as cool.</p>"
    if (nn) { print "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Host</th><th data-col=\"1\">Source</th><th data-col=\"2\">Reason</th></tr></thead><tbody>"; for (i = 1; i <= nn; i++) print nd[i]; print "</tbody></table></div>" }
    else print "<p>None.</p>"
    print "<h3>Unreachable (" nur ")</h3><p class=\"mut\">Took no ssh connection in any sample (timed out, refused, no route, name not found); left out of every count.</p>"
    if (nur) { print "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Target</th><th data-col=\"1\">Reason</th></tr></thead><tbody>"; for (i = 1; i <= nur; i++) print ur[i]; print "</tbody></table></div>" }
    else print "<p>None.</p>"
    print "</section></main></div>" }
