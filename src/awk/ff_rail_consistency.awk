{c[$1 " " $2]++} END {for (x in c) {split(x, p, " "); if (c[x] > b[p[1]]) {b[p[1]] = c[x]; m[p[1]] = p[2]}}
                    for (r = 0; r < nr; r++) printf "%s ", (r in m) ? m[r] : "-"}
