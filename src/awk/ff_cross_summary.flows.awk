NR == FNR { rail[$1] = $3; next }
    /^### / { split($2, a, ":"); it = a[2]; if ($4 ~ /^wave:/) it = it "w" substr($4, 6); ph = substr($3, 7); next }
    ph == "3" { next }   # cross-group runs (phase 3) are routed between rail groups, not the inter-rail path
    { g = -1; rt = 0
      for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^retransmits:/) { split($i, q, ":"); rt = q[2] + 0 } }
      if (g >= 0 && ($1 in rail) && ($2 in rail)) print (rail[$1] == rail[$2] ? rail[$1] : rail[$1] ">" rail[$2]), it, g, rt }
