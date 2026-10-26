FNR == 1 {f++}
     f == 1 {rail[$1 " " $2] = $3; rails[$3] = 1; next}
     $4 != "unknown" && (($1 " " $2) in rail) {n++; h[n] = $1; nic[n] = $2; sw[n] = $4; rl[n] = rail[$1 " " $2]; c[$4 " " rl[n]]++}
     END {for (i = 1; i <= n; i++) {o = ""; for (r in rails) if (r != rl[i] && (o == "" || c[sw[i] " " r] > c[sw[i] " " o])) o = r
              if (o != "" && c[sw[i] " " o] > c[sw[i] " " rl[i]])
                  printf "%s lldp_wrong_rail rail %s NIC %s is cabled to %s, which %d other NICs reach on rail %s\n", h[i], rl[i], nic[i], sw[i], c[sw[i] " " o], o}}
