NR == FNR { host[$1] = $2; next }
    { h = host[$5]; gs[h] += $11; c[h]++; l[h] += $9; s[h] += $10; e[h] += $8 * ($10 - $12) }
    END { print "Host Avg_Gbps Lost/Sent Loss_% Expected_%"
          for (h in c) printf "%s %.1f %d/%d %.3f %.3f\n", h, gs[h] / c[h], l[h], s[h], s[h] ? 100 * l[h] / s[h] : 0, s[h] ? 100 * e[h] / s[h] : 0 }
