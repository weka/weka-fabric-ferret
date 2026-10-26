function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
     $1 == "#TOTAL" {printf "  All at once, %s: %s flows, %s in total%s\n", ($2 == "F1" ? "clients -> backends" : "backends -> clients"), $3, bw($4), ($6 > 1 ? sprintf(" on average over %d iterations (lowest %s)", $6, bw($5)) : "")}
