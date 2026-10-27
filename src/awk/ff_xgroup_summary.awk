function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return 0
    for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
    return n % 2 ? v[(n + 1) / 2] + 0 : (v[n / 2] + v[n / 2 + 1]) / 2 }
function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
FNR == 1 { f++ }
f == 1 { rail[$1] = $3; next }
/^### / { ph = ""; rp = ""; for (i = 2; i <= NF; i++) { if ($i ~ /^phase:/) ph = substr($i, 7); else if ($i ~ /^rails:/) rp = substr($i, 7) }; next }
ph != "3" { next }
{ g = -1; xe = 0
  for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^exp:/) xe = substr($i, 5) + 0 }
  if (g < 0 || !($1 in rail) || !($2 in rail)) next
  k = rp; if (!(k in n)) key[++nk] = k
  n[k]++; v[k] = v[k] " " g; s[k] += g
  if (xe > 0) { p = 100 * g / xe; if (p >= ok) okc[k]++; else if (p >= slow) sl[k]++; else cr[k]++; if (!(k in ex) || xe < ex[k]) ex[k] = xe } }
END {
    if (!nk) { print "  Cross-group: no run gave a result (phase 3)."; exit }
    for (i = 1; i <= nk; i++) { k = key[i]
        printf "  Cross-group %s: %d flows, %s on average (median %.1f Gbps per flow, expected %g at the slower rail shared by its flows): %d OK, %d SLOW, %d CRITICAL\n", k, n[k], bw(s[k] / n[k]), med(v[k]), ex[k] + 0, okc[k] + 0, sl[k] + 0, cr[k] + 0 } }
