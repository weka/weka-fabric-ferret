FNR == 1 {f++}
     f == 1 {hof[$1] = $2; c[$2]++; all++; next}
     {m++; s[m] = $2; d[m] = $4; fs[$2]++}
     END {
         for (x in fs) if (fs[x] >= all - c[hof[x]]) {dead[x] = 1; nd++; deadon[hof[x]]++}
         for (x in dead) printf "%s mesh_no_replies rail IP %s got no reply from any of its %d peers (inbound ICMP blocked or rail down on that host)\n", hof[x], x, all - c[hof[x]]
         for (i = 1; i <= m; i++) if (!(s[i] in dead)) n[d[i]]++
         for (x in n) printf "%s mesh_unreachable rail IP %s did not answer %d of %d pinging rail IPs\n", hof[x], x, n[x], all - c[hof[x]] - (nd - deadon[hof[x]])
     }
