# Places the loss of the confirmed runs: a host loss beyond expected is shared over its runs by wire loss;
# what a run still loses at the paced rate stays, the rest moves to the rate limit bucket.
# Rows go to the file named by rows (udp_confirm.txt), the log lines to stdout.
FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }
f == 1 { if ($1 == "H") bey[$2] = $3; next }
f == 2 { host[$1] = $2; next }
f == 3 { if ($1 " " $2 != t) next
         k = $4 SUBSEP $5 SUBSEP (++n3[$4, $5]); w = $9 - $12; if (w < 0) w = 0
         W[k] = w; WH[host[$5]] += w; WIRE[k] = $10 - $12; GB[k] = $11; WV[k] = $3; next }
f == 4 { n++; K[n] = $4 SUBSEP $5 SUBSEP $3; S[n] = $4; D[n] = $5; BPS[n] = $2; next }
f == 5 { k = $2 SUBSEP $3 SUBSEP $1; got = 0
         for (i = 4; i <= NF; i++) if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); got = 1 }
         if (got && /receiver/ && x[2] > 0) { CL[k] = x[1]; CS[k] = x[2] }
         else { e = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", e); ERR[k] = e } }
END { for (i = 1; i <= n; i++) {
          k = K[i]; h = host[D[i]]; paced = BPS[i] * streams / 1e9
          share = (WH[h] > 0) ? bey[h] * W[k] / WH[h] : 0
          who = sprintf("    %s %s -> %s %s: %.3f Gb/s paced, ", host[S[i]], S[i], h, D[i], paced)
          if (k in CS) {
              pc = 100 * CL[k] / CS[k]; keep = CL[k] / CS[k] * WIRE[k]; if (keep > share) keep = share
              printf "%s %s %s %s %.3f %d %d %.3f %d %s %d %s\n", t, WV[k], S[i], D[i], paced, CL[k], CS[k], pc, secs, GB[k], share - keep + 0.5, (CL[k] ? "persists" : "gone") >> rows
              if (CL[k]) printf "%s%d/%d lost (%.3f%%): loss persists at a paced rate (%.3f %%): lossy path\n", who, CL[k], CS[k], pc, pc
              else printf "%s%d/%d lost (%.3f%%): loss gone at a paced rate: overload against a rate limit of about %s Gb/s between the hosts\n", who, CL[k], CS[k], pc, GB[k]
          } else {
              printf "%s %s %s %s %.3f - - - %d %s 0 no_result\n", t, WV[k], S[i], D[i], paced, secs, GB[k] >> rows
              printf "%sno result (%s): nothing moved\n", who, (k in ERR) ? ERR[k] : "no output"
          } } }
