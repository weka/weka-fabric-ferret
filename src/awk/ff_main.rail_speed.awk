NR == FNR {rail[$1 " " $2] = $3; next}
    (($1 " " $2) in rail) && $4 ~ /^[0-9]+Mb\/s$/ {s = $4; sub(/Mb\/s/, "", s); r = rail[$1 " " $2]; n[r " " s / 1000]++; t[r]++}
    END {for (k in n) {split(k, p, " "); r = p[1]; v = p[2] + 0
             if (n[k] > c[r] || (n[k] == c[r] && v > m[r])) {c[r] = n[k]; m[r] = v}}
         for (i = 1; i <= length(L); i++) {l = substr(L, i, 1); printf "%s ", (l in m) ? m[l] "/" c[l] "/" t[l] : "0/0/0"}}
