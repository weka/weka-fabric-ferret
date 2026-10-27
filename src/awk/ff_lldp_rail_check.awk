FNR == 1 {f++}
     f == 1 {rail[$1 " " $2] = $3; rails[$3] = 1; if ($4 != "" && $4 != "none") byip[$1 " " $4] = $3; next}
     # a row's rail: by host and NIC, else by host and IP (a bond member's row carries the bond's IP)
     $4 != "unknown" {r = ""; if (($1 " " $2) in rail) r = rail[$1 " " $2]; else if (($1 " " $3) in byip) r = byip[$1 " " $3]
                      if (r != "") {n++; h[n] = $1; nic[n] = $2; sw[n] = $4; rl[n] = r; c[$4 " " r]++}}
     END {for (i = 1; i <= n; i++) {o = ""; for (r in rails) if (r != rl[i] && (o == "" || c[sw[i] " " r] > c[sw[i] " " o])) o = r
              if (o != "" && c[sw[i] " " o] > c[sw[i] " " rl[i]])
                  printf "%s lldp_wrong_rail rail %s NIC %s is cabled to %s, which %d other NICs reach on rail %s\n", h[i], rl[i], nic[i], sw[i], c[sw[i] " " o], o}}
