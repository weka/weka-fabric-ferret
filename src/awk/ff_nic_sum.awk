BEGIN { n = split(lines, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); L[kv[1]] = kv[2] + 0 }; N[0] = "OK"; N[1] = "SLOW"; N[2] = "CRITICAL"; nc = split("S X" (xg > 0 ? " G" : "") (cl > 0 ? " CO CI FO FI" : ""), C, " ") }   # no clients: no client columns; no group pairs: no XGrp column
FNR == 1 { f++ }
f == 1 { ro[$1] = $2; ho[$1] = $3; ni[$1] = $4; ra[$1] = $5; ln[$1] = $6 + 0; mtu[$1] = $7 + 0; stt[$1] = $8; ips[++ni_n] = $1; next }
/^### / { ph = ""; for (i = 2; i <= NF; i++) if ($i ~ /^phase:/) ph = substr($i, 7); next }
{ s = $1; d = $2; g = -1; sh = 1; rx = 0; bv = 0; xe = 0
  for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^share:/) sh = substr($i, 7) + 0; if ($i ~ /^retransmits:/) rx = substr($i, 13) + 0; if ($i ~ /^exp:/) xe = substr($i, 5) + 0
                              if ($i ~ /^[KMGT]?Bytes$/ && !bv) bv = $(i-1) * (substr($i, 1, 1) == "K" ? 1024 : substr($i, 1, 1) == "M" ? 1048576 : substr($i, 1, 1) == "G" ? 1073741824 : substr($i, 1, 1) == "T" ? 1099511627776 : 1) }
  if (g < 0 || !(s in ro) || !(d in ro)) next
  rt[s] += rx; by[s] += bv
  if (f == 2) { if (ph == "3") { add(s, "G", g, xe); add(d, "G", g, xe) }   # cross-group: judged at the exp: the run carries
                else if (ra[s] == ra[d]) { ex = L[ra[s]]; add(s, "S", g, ex); add(d, "S", g, ex) }
                else { ex = L[ra[s]]; if (L[ra[d]] < ex) ex = L[ra[d]]; add(s, "X", g, ex); add(d, "X", g, ex) }; next }
  c = (ro[s] == "client") ? s : d; b = (c == s) ? d : s
  ex = L[ra[b]] > 0 ? L[ra[b]] / (sh > 0 ? sh : 1) : 0; if (ln[c] > 0 && (ex == 0 || ln[c] < ex)) ex = ln[c]
  p = (ph ~ /^F/) ? "F" : "C"; add(s, p "O", g, ex); add(d, p "I", g, ex) }
function add(ip, col, g, ex) { sum[ip, col] += g; cnt[ip, col]++; if (ex > 0) { pct[ip, col] += 100 * g / ex; pc[ip, col]++; if (!((ip) in mx) || ex < mx[ip]) mx[ip] = ex } }
END {
    print "0 0 Role Host NIC IP Same Cross" (xg > 0 ? " XGrp" : "") (cl > 0 ? " CB_Out CB_In All_Out All_In" : "") " Retr Retr_% Expect Status"
    for (k = 1; k <= ni_n; k++) { ip = ips[k]; w = -1; wn = -1; wx = -1; wg = -1; lo = 1e9; o = ""; any = 0
        for (j = 1; j <= nc; j++) { col = C[j]
            if (!cnt[ip, col]) { o = o " -"; continue }
            any = 1; o = o sprintf(" %.1f", sum[ip, col] / cnt[ip, col])
            if (pc[ip, col]) { pv = pct[ip, col] / pc[ip, col]; if (pv < lo) lo = pv; lv = pv >= ok ? 0 : (pv >= slow ? 1 : 2)
                               if (lv > w) w = lv; if (col == "X") wx = lv; else if (col == "G") wg = lv; else if (lv > wn) wn = lv } }
        sg = by[ip] / (mtu[ip] > 52 ? mtu[ip] - 52 : 1448); rp = sg > 0 ? 100 * rt[ip] / sg : 0
        sfx = ""   # (cross) / (xgrp): only the routed columns are that bad; the host passes on its own rails
        if (w > wn && (wx >= 0 || wg >= 0)) sfx = (wx == w && wg == w) ? "(cross,xgrp)" : (wx == w ? "(cross)" : "(xgrp)")
        st = !any ? (stt[ip] != "" && stt[ip] != "ok" ? stt[ip] : "no_result") : (w < 0 ? "-" : N[w] sfx) (any && rp > rl ? "(retr)" : "")
        printf "%d %.1f %s %s %s %s%s %d %s %s %s\n", (!any ? 7 : (w < 0 ? -1 : 2 * w + (rp > rl))), (lo < 1e9 ? lo : 0), ro[ip], ho[ip], ni[ip], (ip ~ /^none_/ ? "-" : ip), o, rt[ip],
               (sg > 0 ? sprintf("%.3f", rp) : "-"), (ip in mx ? sprintf("%g", mx[ip]) : "-"), st } }
