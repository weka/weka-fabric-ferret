
    NR == FNR { rail[$1] = $3; next }
    { l = tolower($3) } l ~ /byte/ && match(l, /pri(ority|o)?_?[0-9]/) {
        p = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", p); r = ($2 in rail) ? rail[$2] : "?"
        b[r " " p] += $4; n++ }
    END { RL = RL "?"; for (r = 1; r <= length(RL); r++) { R = substr(RL, r, 1); t = ""
              for (p = 0; p <= 7; p++) if ((R " " p) in b) t = t sprintf(" prio%d %s", p, b[R " " p] < 5e7 ? "<0.1GB" : sprintf("%.1fGB", b[R " " p] / 1e9))
              if (t != "") printf "rail %s:%s  ", R, t }
          if (!n) printf "no per-priority byte counters" }
