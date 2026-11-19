function d(a, b) { return (a ~ /^[0-9]+$/ && b ~ /^[0-9]+$/) ? (a + 0 >= b + 0 ? a - b : "reset") : (a == "off" ? "off" : "na") }
     function bps(x) { return (x ~ /^[0-9]+Mb\/s$/) ? substr(x, 1, length(x) - 4) * 1e6 : 0 }
     $1 != "@@BMEM" {next}
     FILENAME == ARGV[1] {for (i = 6; i <= 15; i++) p[$2, $3, $4, i] = $i; next}
     !(($2, $3, $4, 6) in p) {next}
     {n++; k[n] = $2 SUBSEP $3; row[n] = $2 " " $3 " " $4 " " $5; sp[n] = bps($5)
      for (i = 6; i <= 15; i++) v[n, i] = d($i, p[$2, $3, $4, i])
      if (v[n, 10] ~ /^[0-9]+$/) brx[k[n]] += v[n, 10]
      if (v[n, 11] ~ /^[0-9]+$/) btx[k[n]] += v[n, 11]
      if (sp[n] > top[k[n]]) top[k[n]] = sp[n]}
     END {
         for (j = 1; j <= n; j++) {
             f = ""; ber = "na"
             for (i = 6; i <= 15; i++) if (v[j, i] == "reset") f = f ",reset"
             if (v[j, 7] ~ /^[0-9]+$/ && v[j, 7] > 0) f = f ",uncorrectable"
             if (v[j, 8] ~ /^[0-9]+$/ && sp[j] && s) {ber = sprintf("%.2e", v[j, 8] / (s * sp[j]))
                 if (ber + 0 >= limit) f = f ",fec_over_limit"; else if (ber + 0 >= watch) f = f ",fec_watch"}
             if (v[j, 9] ~ /^[0-9]+$/ && v[j, 9] > 0) f = f ",symbol_errors"
             if (v[j, 13] ~ /^[0-9]+$/ && v[j, 13] > 0) f = f ",rx_errors"
             if (v[j, 14] ~ /^[0-9]+$/ && v[j, 14] > 0) f = f ",discards"
             if (v[j, 15] ~ /^[0-9]+$/ && v[j, 15] > 0) f = f ",carrier_down"
             if (sp[j] && sp[j] < top[k[j]]) f = f ",slow_link"
             rs = (brx[k[j]] > 0 && v[j, 10] ~ /^[0-9]+$/) ? sprintf("%.0f", 100 * v[j, 10] / brx[k[j]]) : "na"
             ts = (btx[k[j]] > 0 && v[j, 11] ~ /^[0-9]+$/) ? sprintf("%.0f", 100 * v[j, 11] / btx[k[j]]) : "na"
             tot = brx[k[j]] + btx[k[j]]; mine = (v[j, 10] ~ /^[0-9]+$/ ? v[j, 10] : 0) + (v[j, 11] ~ /^[0-9]+$/ ? v[j, 11] : 0)
             if (tot >= 1e9 && mine < 0.05 * tot) f = f ",idle_member"
             gb_rx = (v[j, 10] ~ /^[0-9]+$/) ? sprintf("%.1f", v[j, 10] / 1e9) : v[j, 10]
             gb_tx = (v[j, 11] ~ /^[0-9]+$/) ? sprintf("%.1f", v[j, 11] / 1e9) : v[j, 11]
             printf "%s %s %d %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", t, row[j], s, v[j, 6], v[j, 7], v[j, 8], v[j, 9], gb_rx, gb_tx, rs, ts, v[j, 12], v[j, 13], v[j, 14], v[j, 15], ber, (f == "" ? "-" : substr(f, 2))
         }
     }
