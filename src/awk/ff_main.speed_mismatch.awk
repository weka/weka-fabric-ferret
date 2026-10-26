BEGIN {n = split(lines, q, " "); for (i = 1; i <= n; i++) {split(q[i], kv, "="); want[kv[1]] = kv[2] * 1000 "Mb/s"}}
    NR == FNR {rail[$1] = $2; next}
    $4 ~ /^[0-9]+Mb\/s$/ && ($3 in rail) && $4 != want[rail[$3]] {printf "#   %s %s %s (rail %s)\n", $1, $2, $4, rail[$3]}
