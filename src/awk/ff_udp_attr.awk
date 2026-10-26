FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }   # by name: an empty file must not shift the rest
f == 1 { E[$1 " " $2 " " $3 " " $4 " " $5] = $8; TR[$1 " " $2 " " $3 " " $4 " " $5] = $12 + 0; next }
f == 2 { host[$1] = $2; next }
f == 3 { nh[$1] = $2; next }
f == 4 { if (/^### /) { split($2, a, ":"); split($3, b, ":"); ph = "iter" a[2] " " b[2]; wv = ($4 ~ /^wave:/) ? substr($4, 6) : "-"; next }
         if (t != "" && ph != t) next
         n = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); n = 1 }
         if (!n) next
         split($1, s, ","); k = ph SUBSEP host[s[2]]; L[k] += x[1]; sent += x[2]; r = ph " " wv " " s[1] " " s[2]
         TX[k] += TR[r]; X[k] += E[r] * (x[2] - TR[r]); next }
f == 5 { k = $1 " " $2 SUBSEP $3; SK[k] += $4; BK[k] += $7; next }
f == 6 { k = $1 " " $2 SUBSEP nh[$3]; DR[k] += $4; DO[k] += $5 }
END { for (k in L) { nk = DR[k] - BK[k]; if (nk < 0) nk = 0; nk += DO[k]
                     lost += L[k]; sock += SK[k]; nic += nk; back += BK[k]; ex += X[k]; tx += TX[k]
                     u = L[k] - TX[k] - SK[k] - nk - BK[k]; if (u > 0) un += u; else ov -= u
                     if (u - X[k] > 0) bey += u - X[k] }
      printf "%d %d %d %d %d %d %d %d %d %d\n", lost, sent, sock, nic, back, un, ov, ex + 0.5, bey, tx }
