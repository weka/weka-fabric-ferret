BEGIN { split("inlet cpu gpu mem nvme nic other", t, " "); for (i = 1; i <= 7; i++) r[t[i]] = i }
     NR > 1 && $6 != "none" { g = ($2 == "ipmi" ? "bmc" : "os"); print (g == "bmc" ? 1 : 2), r[$3], $4, $5, tolower($6), g, $3, $4, $5, $6, $1, $8, $10, $11, $12 }
