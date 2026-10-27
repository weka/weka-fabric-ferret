function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return -1
    for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
    return n % 2 ? v[(n + 1) / 2] + 0 : (v[n / 2] + v[n / 2 + 1]) / 2 }
function tb(g) { return g >= 1000 ? sprintf("%.2f T", g / 1000) : sprintf("%.1f G", g) }
BEGIN { nr = split(lines, lq, " "); for (i = 1; i <= nr; i++) { split(lq[i], kv, "="); L[kv[1]] = kv[2] + 0; if (i == 1 || kv[2] + 0 < lx) lx = kv[2] + 0 } }
FNR == 1 { f++ }
f == 1 { rail[$1] = $3; if ($3 == "client") cl[$1] = 1; else nip++; next }
f == 2 { if ($4 != "unknown" && $4 != "") { if (!($3 in leaf)) leaf[$3] = $4; else if (index("+" leaf[$3] "+", "+" $4 "+") == 0) leaf[$3] = leaf[$3] "+" $4 }; next }   # an IP's leaf from any row naming one (a bond: its members); two leaves = an MLAG pair "x+y"
f == 3 { if ($4 ~ /^[0-9]+Mb\/s$/) { s = $4; sub(/Mb\/s/, "", s); sp[$3] = s / 1000 }; next }
/^### / { it = ""; ph = ""; w = ""
          for (i = 2; i <= NF; i++) { if ($i ~ /^iteration:/) it = substr($i, 11); else if ($i ~ /^phase:/) ph = substr($i, 7); else if ($i ~ /^wave:/) w = substr($i, 6) }
          if (w != "") it = it " wave " w; next }
{ g = -1; for (i = 1; i <= NF; i++) if ($i == "Gbits/sec") { g = $(i-1) + 0; break }
  if (g < 0 || !($1 in rail) || !($2 in rail)) next
  if (!($1 in leaf) || !($2 in leaf)) { left++; next }
  x = leaf[$1]; y = leaf[$2]
  if (x == y) { if (rail[$1] == rail[$2]) same[x] = same[x] " " g; next }
  if (!((ph, it, x) in seen)) { seen[ph, it, x] = 1; key[++nk] = ph SUBSEP it SUBSEP x }
  if (!((ph, it, y) in seen)) { seen[ph, it, y] = 1; key[++nk] = ph SUBSEP it SUBSEP y }
  ob[ph, it, x] += g; ib[ph, it, y] += g; xl[ph, x] = xl[ph, x] " " g; xl[ph, y] = xl[ph, y] " " g; its[ph, it] = 1 }
# side: a leaf seen by client NICs only is a client leaf (capacity CC), else a backend leaf (C)
END {
    for (ip in rail) if (ip in leaf) { if (ip in cl) cleaf[leaf[ip]] = 1; else { nl++; bleaf[leaf[ip]] = 1 }
                                       dl[leaf[ip]] += (ip in sp) ? sp[ip] : ((ip in cl) ? cgb : L[rail[ip]]) }
                     else if (!(ip in cl)) nm++
    if (mode == "client") {
        # clients: one pass over the client runs, each leaf against its own side
        for (lf in cleaf) if (lf in bleaf) nsh++
        if (CC > 0) printf "  Declared client leaf uplinks: %d spines x %d links x %dG = %s per leaf, each direction\n", N, CM, CS, tb(CC)
        if (nsh) printf "  %d leaves serve both clients and backends; they are judged as backend leaves (rail_anomalies.txt shared_leaf)\n", nsh
        C0 = C; C = 1   # judge per leaf below
    } else {
        if (C > 0) printf "  Declared uplinks: %d spines x %d links x %dG = %s per leaf, each direction\n", N, M, S, tb(C)
        # the NICs left out are said before any exit (a 10-27 field run dropped 285 runs and said nothing)
        if (nm) printf "  Uplinks: %d of %d rail NICs have no LLDP neighbour; their %d runs are left out of the leaf totals.\n", nm, nip, left
        if (!nl) { if (C > 0) print "  Uplink check skipped: it needs LLDP, and no rail NIC reported a switch neighbour."; exit }
    }
    # busiest iteration per (phase, leaf), in first-seen order
    for (k = 1; k <= nk; k++) { split(key[k], p, SUBSEP); bz = ob[key[k]] > ib[key[k]] ? ob[key[k]] : ib[key[k]]
        pl = p[1] SUBSEP p[3]; if (!(pl in best)) lst[++no] = pl; if (!(pl in best) || bz > best[pl]) { best[pl] = bz; bk[pl] = key[k] } }
    if (mode == "client") {
        if (!no) { print "  No client runs crossed between leaves" (left ? sprintf(" (%d runs have a NIC with no LLDP neighbour)", left) : "") "."; exit }
        print "  Client runs, uplink totals per leaf (busiest wave):"
        for (q = 1; q <= no; q++) { pl = lst[q]; split(pl, p, SUBSEP); k = bk[pl]; split(k, kk, SUBSEP); lf = p[2]
            side = (lf in bleaf) ? ((lf in cleaf) ? "shared" : "backend") : "client"; cp = (lf in bleaf) ? C0 : CC
            bi = sprintf(" [iteration %s]", kk[2])
            if (cp <= 0) { printf "  Uplinks %s (%s leaf) phase %s: out %s / in %s%s; downlinks %s\n", lf, side, p[1], tb(ob[k]), tb(ib[k]), bi, tb(dl[lf]); continue }
            pct = 100 * best[pl] / cp
            printf "  Uplinks %s (%s leaf) phase %s: out %s / in %s of %s declared (%.0f%%)%s; downlinks %s, oversubscribed %.1f:1\n", lf, side, p[1], tb(ob[k]), tb(ib[k]), tb(cp), pct, bi, tb(dl[lf]), dl[lf] / cp
            if (pct >= ok) printf "    at declared uplink capacity: client runs through %s get their share of the uplinks, not line rate\n", lf
        }
        exit
    }
    if (!no && C == 0) exit
    if (C == 0) print "  Uplink totals per leaf (set FF_SPINES, FF_SPINE_LINKS, FF_SPINE_GBPS to judge against uplink capacity):"
    if (!no) { print "  No runs crossed between leaves."; exit }
    okc = lx * ok / 100
    for (q = 1; q <= no; q++) { pl = lst[q]; split(pl, p, SUBSEP); k = bk[pl]; split(k, kk, SUBSEP)
        ni = 0; for (z in its) { split(z, zz, SUBSEP); if (zz[1] == p[1]) ni++ }
        bi = ni > 1 ? sprintf(" [iteration %s, busiest of %d]", kk[2], ni) : ""
        if (C == 0) { printf "  Uplinks %s phase %s: out %s / in %s%s; downlinks %s\n", p[2], p[1], tb(ob[k]), tb(ib[k]), bi, tb(dl[p[2]]); continue }
        pct = 100 * best[pl] / C
        printf "  Uplinks %s phase %s: out %s / in %s of %s declared (%.0f%%)%s; downlinks %s, oversubscribed %.1f:1\n", p[2], p[1], tb(ob[k]), tb(ib[k]), tb(C), pct, bi, tb(dl[p[2]]), dl[p[2]] / C
        xm = med(xl[pl]); sm = med(same[p[2]])
        if (lx > 0 && pct >= ok && xm < lx)
            printf "    at declared uplink capacity: oversubscribed %.1f:1 by design; cross-leaf runs (median %.1f Gbps) get their share of the uplinks, not line rate\n", dl[p[2]] / C, xm
        else if (lx > 0 && xm >= 0 && xm < okc && sm >= okc && pct < slow)
            printf "    uplinks carried only %.0f%% of declared capacity while cross-leaf runs were slow (median %.1f Gbps, OK >= %g) and same-leaf runs were OK (median %.1f); a link or spine may be down, or ECMP is uneven\n", pct, xm, okc, sm
    } }
