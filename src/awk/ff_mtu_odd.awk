{if (!($1 in n)) d++; n[$1]++; h[$1] = h[$1] " " $2} END {if (d < 2) exit; for (m in n) if (n[m] > b) {b = n[m]; mm = m}
     t = 0; for (m in n) if (n[m] == b) t++
     if (t > 1) {printf "no majority:"; for (m in n) printf " %s on%s;", m, h[m]}
     else {printf "most at %s;", mm; for (m in n) if (m != mm) printf " %s on%s;", m, h[m]}}
