NR == FNR {rail[$1] = $2; next}
    ($3 in rail) && $4 ~ /^[0-9]+Mb\/s$/ {s = $4; sub(/Mb\/s/, "", s); n[rail[$3] " " s / 1000]++}
    END {for (k in n) {split(k, p, " "); r = p[1]; v = p[2] + 0
             if (n[k] > c[r] || (n[k] == c[r] && v > m[r])) {c[r] = n[k]; m[r] = v}}
         for (i = 1; i <= length(L); i++) printf "%s ", (substr(L, i, 1) in m) ? m[substr(L, i, 1)] : 0}
