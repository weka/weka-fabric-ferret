FILENAME == ARGV[1] {hof[$1] = $2; next}
     FILENAME == ARGV[2] {den[$2]++; next}
     {n[$4]++; l[$4] += $5; t[$4] += $6}
     END {for (x in n) printf "%s %s rail IP %s lost pings from %d of %d %s (%d of %d pings lost)\n", hof[x], kind, x, n[x], den[x], who, l[x], t[x]}
