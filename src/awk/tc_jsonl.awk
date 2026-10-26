function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
function nm(x) { return (x == "-" || x == "") ? "null" : sprintf("%.1f", x) }
FILENAME == ARGV[1] { st[$1] = $2; sord[++ns] = $1; next }
FILENAME == ARGV[2] { k = $4 " " $2; if (!(k in tg)) { tord[++nx] = k; tt[k] = $4; tn[k] = $2; tl[k] = $5; ta[k] = $6 }
    if (!(k in tg) || tg[k] == $2) tg[k] = $3; next }
FILENAME == ARGV[3] { if (FNR == 1) {
        printf "{\"type\":\"run\",\"tool\":\"thermals_capture\",\"version\":%s,\"label\":%s,\"start\":%s,\"end\":%s,\"samples\":%d,\"interval_s\":%s,\"duration_s\":%s,\"ipmi\":%s,\"ipmi_timeout_s\":%s,\"temp_margin_c\":%s,\"temp_rise_c\":%s,\"ssh_user\":%s,\"targets\":%d,\"unreachable\":%d}\n", q(ver), q(label), q(start), q(end), ns, (iv == "" ? "null" : iv), (du == "" ? "null" : du), ipmi, ito, margin, rise, q(user), nt, unreach
        for (i = 1; i <= nx; i++) { k = tord[i]
            printf "{\"type\":\"host\",\"target\":%s,\"host\":%s,\"target_type\":%s,\"login\":%s,\"auth\":%s}\n", q(tn[k]), q(tg[k]), q(tt[k]), q(tl[k]), q(ta[k]) }
        for (i = 1; i <= ns; i++) printf "{\"type\":\"sample\",\"sample\":%s,\"time\":%s}\n", q(sord[i]), q(st[sord[i]])
        next }
    if ($6 == "none") next
    printf "{\"type\":\"reading\",\"sample\":%s,\"time\":%s,\"host\":%s,\"source\":%s,\"chip\":%s,\"dev\":%s,\"sensor\":%s,\"temp_c\":%s,\"high_c\":%s,\"crit_c\":%s,\"status\":%s}\n", q($1), q(st[$1]), q($2), q($3), q($4), q($5), q($6), nm($7), nm($8), nm($9), q($10)
    next }
FNR == 1 { next }
$12 ~ /^nodata/ { nd++; printf "{\"type\":\"nodata\",\"host\":%s,\"source\":%s,\"why\":%s}\n", q($1), q($2), q(substr($12, 8)); next }
{ ns2++; if ($12 != "-") fl++
  printf "{\"type\":\"sensor\",\"host\":%s,\"source\":%s,\"kind\":%s,\"chip\":%s,\"dev\":%s,\"sensor\":%s,\"first_c\":%s,\"min_c\":%s,\"max_c\":%s,\"last_c\":%s,\"high_c\":%s,\"crit_c\":%s,\"flag\":%s}\n", q($1), q($2), q($3), q($4), q($5), q($6), nm($7), nm($13), nm($8), nm($9), nm($10), nm($11), ($12 == "-" ? "null" : q($12)) }
END { printf "{\"type\":\"result\",\"data\":%s,\"hosts_with_data\":%d,\"targets\":%d,\"sensors\":%d,\"flagged\":%d,\"nodata\":%d,\"unreachable\":%d}\n", q(res), hwd, nt, ns2, fl, nd, unreach }
