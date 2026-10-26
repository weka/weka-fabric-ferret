FNR == 1 {f++}
     f == 1 {hof[$1] = $2; nc++; next}
     {m++; s[m] = $2; d[m] = $4; dh[$4] = $3; fs[$2]++}
     END {
         for (x in fs) if (fs[x] >= nb) {dead[x] = 1; nd++}
         for (x in dead) printf "%s mesh_client_no_replies client IP %s got no reply from any of the %d backend rail IPs (inbound ICMP blocked, or no route to the rails)\n", hof[x], x, nb
         for (i = 1; i <= m; i++) if (!(s[i] in dead)) n[d[i]]++
         for (x in n) printf "%s mesh_client_unreachable rail IP %s did not answer %d of %d client IPs\n", dh[x], x, n[x], nc - nd
     }
