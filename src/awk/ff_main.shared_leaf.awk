NR == FNR {kind[$1] = $3; next} ($3 in kind) && $4 != "unknown" && $4 != "" {if (kind[$3] == "client") c[$4]++; else b[$4]++}
     END {for (l in c) if (l in b) printf "%s shared_leaf switch serves %d client NICs and %d backend NICs; judged as a backend leaf\n", l, c[l], b[l]}
