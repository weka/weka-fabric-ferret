NR > 1 { full = 0
    for (i = 6; i <= NF; i += 4) { s = $i; L = substr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", (i - 2) / 4, 1)
        if (s ~ /^no_(NIC|IPv4_on)_/) { k = L SUBSEP s; if (!(k in n)) ord[++no] = k; n[k]++; if (n[k] <= 8) hl[k] = hl[k] " " $1 }
        else if (s != "ok") full = 1 }
    if (full) rows[++nr] = $0 }
END { for (i = 1; i <= no; i++) { k = ord[i]; split(k, p, SUBSEP); s = p[2]; gsub(/_/, " ", s)
          printf "%d host%s: rail %s %s:%s%s\n", n[k], (n[k] == 1 ? "" : "s"), p[1], s, hl[k], (n[k] > 8 ? " and " (n[k] - 8) " more" : "") }
      for (i = 1; i <= nr; i++) print rows[i] }
