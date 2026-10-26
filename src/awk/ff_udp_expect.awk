FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }
f == 1 { ln[$1] = $2 + 0; next }
f == 2 { k = $1 " " $2 SUBSEP $4; if ($5 ~ /^[0-9]+$/) TK[k] = $5; if ($6 ~ /^[0-9]+$/) TW[k] = $6; next }
/^### / { split($2, a, ":"); split($3, b, ":"); p = "iter" a[2] " " b[2]; g = p " " (($4 ~ /^wave:/) ? substr($4, 6) : "-"); next }
/receiver/ { split($1, s, ","); n++; G[n] = g; P[n] = p; S[n] = s[1]; D[n] = s[2]
             for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") R[n] = $(i-1); if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); Lo[n] = x[1]; Se[n] = x[2] } }
             SP[p SUBSEP s[1]] += Se[n] }
END { for (i = 1; i <= n; i++) { q = P[i] SUBSEP S[i]; sh = 0
          if (q in TK) { sh = SP[q] - TK[q]; if (sh < 0) sh = 0; if (q in TW && TK[q] > TW[q]) sh += TK[q] - TW[q] }
          t = SP[q] ? sh * Se[i] / SP[q] : 0; if (t > Lo[i]) t = Lo[i]; T[i] = t
          k = G[i] SUBSEP D[i]
          if (Se[i] > Lo[i] && R[i] > 0) off[k] += R[i] * (Se[i] - t) / (Se[i] - Lo[i]); else unk[k] = 1 }
      for (i = 1; i <= n; i++) { k = G[i] SUBSEP D[i]; rx = ln[D[i]]; ok = rx > 0 && !(k in unk)
          ex = (ok && off[k] > rx) ? 1 - rx / off[k] : 0
          printf "%s %s %s %s %s %.4f %d %d %s %d\n", G[i], S[i], D[i], (ok ? off[k] : "-"), ((rx > 0) ? rx : "-"), ex, Lo[i], Se[i], R[i], T[i] + 0.5 } }
