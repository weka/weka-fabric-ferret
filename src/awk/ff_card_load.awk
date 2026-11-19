function d(a, b) { return (a ~ /^[0-9]+$/ && b ~ /^[0-9]+$/ && a + 0 >= b + 0) ? a - b : -1 }
     $1 != "@@CARD" {next}
     FILENAME == ARGV[1] {for (i = 9; i <= 18; i++) p[$2, $3, i] = $i; next}
     !(($2, $3, 9) in p) {next}
     {c = $4; sub(/\.[0-9]+$/, "", c); k = $2 SUBSEP c
      if (!(k in seen)) {seen[k] = 1; ord[++n] = k; host[k] = $2; card[k] = c}
      ports[k] = ports[k] (ports[k] == "" ? "" : ",") $3
      x = d($9, p[$2, $3, 9]); if (x >= 0) rx[k] += x
      x = d($10, p[$2, $3, 10]); if (x >= 0) tx[k] += x
      for (i = 11; i <= 14; i++) {x = d($i, p[$2, $3, i]); if (x > 0) bp[k, i] += x}
      for (i = 15; i <= 18; i++) {x = d($i, p[$2, $3, i]); if (x > 0) pe[k] += x}
      if ($5 ~ /^[0-9.]+$/ && $6 ~ /^[0-9]+$/) {gt[k] = $5; w[k] = $6}
      lk[k] = $5 "x" $6 "/" $7 "x" $8
      if (($5 ~ /^[0-9.]+$/ && $7 ~ /^[0-9.]+$/ && $5 + 0 < $7 + 0) || ($6 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ && $6 + 0 < $8 + 0)) dg[k] = 1}
     END {
         for (j = 1; j <= n; j++) {k = ord[j]
             tg = s > 0 ? tx[k] * 8 / s / 1e9 : 0; rg = s > 0 ? rx[k] * 8 / s / 1e9 : 0
             sl = (k in gt) ? gt[k] * w[k] * (gt[k] + 0 < 8 ? 0.8 : 128 / 130) : 0
             f = ""; top = tg > rg ? tg : rg
             if (sl > 0 && top >= near / 100 * sl) f = f ",near_slot"
             b = bp[k, 11] + bp[k, 12] + bp[k, 13] + bp[k, 14]; if (b > 0) f = f ",backpressure"
             if (dg[k]) f = f ",pcie_degraded"
             if (pe[k] > 0) f = f ",pcie_errors"
             printf "%s %s %s %s %s %.1f %.1f %.0f %s %d %d %d %d %d %s\n", it, ph, host[k], card[k], ports[k], tg, rg, sl, lk[k], bp[k, 11], bp[k, 12], bp[k, 13], bp[k, 14], pe[k], (f == "" ? "-" : substr(f, 2))
         }
     }
