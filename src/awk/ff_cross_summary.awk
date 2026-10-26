
    function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
    function k(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e4 ? sprintf("%.1fk", n / 1e3) : n) }
    function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return ""
        for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
        return sprintf("%.1f", n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2) }
    BEGIN { nr = split(lines, q, " "); for (i = 1; i <= nr; i++) { split(q[i], kv, "="); R[i] = kv[1]; L[kv[1]] = kv[2] + 0 } }
    $1 ~ />/ { nx++; d[$1]++; tot[$2] += $3; xr += $4; xv = xv " " $3; if (index($2, "w")) wv = 1; next }
    { sr += $4; sv[$1] = sv[$1] " " $3 }
    END { for (i in tot) { ni++; s += tot[i]; if (ni == 1 || tot[i] < lo) lo = tot[i]; if (ni == 1 || tot[i] > hi) hi = tot[i] }
          if (ni == 1) printf "  Cross-rail total: %s over %d flows run at once", bw(s), nx
          else if (wv) printf "  Cross-rail total per wave (FF_CROSS_MAX=%d flows at once): largest %s, %s on average (%s to %s over %d waves), %d flows", cm, bw(hi), bw(s / ni), bw(lo), bw(hi), ni, nx
          else printf "  Cross-rail total per iteration: %s on average (%s to %s over %d iterations), %d flows", bw(s / ni), bw(lo), bw(hi), ni, nx
          # directions: every one with two rails (as before), the ones that ran with more
          ds = ""; for (i = 1; i <= nr; i++) for (j = 1; j <= nr; j++) if (i != j && (nr == 2 || (R[i] ">" R[j]) in d))
              ds = ds sprintf("%s%s->%s %d", ds == "" ? "" : ", ", R[i], R[j], d[R[i] ">" R[j]])
          xm = med(xv)
          printf " (%s); median %s Gbps per flow; retransmits %s cross-rail vs %s same-rail\n", ds, xm, k(xr), k(sr + 0)
          lx = 0; for (i = 1; i <= nr; i++) if (i == 1 || L[R[i]] < lx) lx = L[R[i]]
          cx = lx * ok / 100; any = 0; allok = 1; sm = ""
          for (i = 1; i <= nr; i++) { m = med(sv[R[i]]); sm = sm sprintf("%s%s (%s)", i > 1 ? " / " : "", m == "" ? "-" : m, R[i])
              if (m != "") { any = 1; if (m + 0 < L[R[i]] * ok / 100) allok = 0 } }
          if (lx > 0 && xm + 0 < cx && any && allok)
              printf "  Same-rail runs are OK, cross-rail runs are not: cross-rail median %s Gbps per flow (OK >= %g), same-rail median %s Gbps. The hosts pass on their own rail, so the likely limit is the shared path between the rails (switch inter-link or spine), not the hosts.\n", xm, cx, sm }
