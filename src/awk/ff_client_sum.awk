BEGIN { n = split(lines, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); L[kv[1]] = kv[2] + 0 }; N[0] = "OK"; N[1] = "SLOW"; N[2] = "CRITICAL" }
FNR == 1 { f++ }
f == 1 { ch[$1] = $2; cn[$1] = $3; cl[$1] = $4 + 0; next }
f == 2 { br[$1] = $3; next }
/^### / { ph = ""; it = ""; for (i = 2; i <= NF; i++) { if ($i ~ /^phase:/) ph = substr($i, 7); if ($i ~ /^iteration:/) it = substr($i, 11) }; next }
{ s = $1; d = $2; g = -1; sh = 1; rx = 0
  for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^share:/) sh = substr($i, 7) + 0; if ($i ~ /^retransmits:/) rx = substr($i, 13) + 0 }
  if (g < 0) next
  c = (s in ch) ? s : d; b = (s in ch) ? d : s; if (!(c in ch) || !(b in br)) next
  lb = L[br[b]]; lc = cl[c]; ex = lb > 0 ? lb / (sh > 0 ? sh : 1) : 0; if (lc > 0 && (ex == 0 || lc < ex)) ex = lc
  col = (ph ~ /^F/) ? "F" : "C"; col = col ((s in ch) ? "o" : "i")
  sum[c, col] += g; cnt[c, col]++; if (ex > 0) { pct[c, col] += 100 * g / ex; pc[c, col]++ }
  if (!((c, "x") in mx) || ex < mx[c, "x"]) mx[c, "x"] = ex; seen[c] = 1
  if (s in ch) rt[c] += rx
  if (ph ~ /^F/) { ft[ph, it] += g; fn[ph, it]++ } }
END {
    print "Client NIC IP C->B B->C All_C->B All_B->C Retr Expect Status"
    for (c in seen) { w = -1; o = ""
        for (k = 1; k <= 4; k++) { col = substr("CoCiFoFi", 2 * k - 1, 2)
            if (!cnt[c, col]) { o = o " -"; continue }
            o = o sprintf(" %.1f", sum[c, col] / cnt[c, col])
            if (pc[c, col]) { p = pct[c, col] / pc[c, col]; lv = p >= ok ? 0 : (p >= slow ? 1 : 2); if (lv > w) w = lv } }
        printf "%s %s %s%s %d %s %s\n", ch[c], cn[c], c, o, rt[c], (mx[c, "x"] > 0 ? sprintf("%g", mx[c, "x"]) : "-"), (w < 0 ? "-" : N[w]) }
    # all at once: per iteration, then the average and the lowest over the iterations
    for (x in ft) { split(x, y, SUBSEP); p = y[1]; ni[p]++; ts[p] += ft[x]; nf[p] = fn[x]; if (!(p in lo) || ft[x] < lo[p]) lo[p] = ft[x] }
    for (p in ni) printf "#TOTAL %s %d %.1f %.1f %d\n", p, nf[p], ts[p] / ni[p], lo[p], ni[p] }
