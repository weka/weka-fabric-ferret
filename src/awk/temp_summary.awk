NR == 1 { next }
$6 == "none" { nd[$2 SUBSEP $3] = $10; next }
{ k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6; v = $7 + 0; got[$2 SUBSEP $3] = 1
  if (!(k in mx)) { fi[k] = v; mx[k] = v; ord[++n] = k } else if (v > mx[k]) mx[k] = v
  la[k] = v; if ($8 != "-" && $8 + 0 > 0) hi[k] = $8 + 0; if ($9 != "-" && $9 + 0 > 0) cr[k] = $9 + 0; if ($3 == "ipmi") { if ($10 ~ /^(cr|nr)/) bc[k] = 2; else if ($10 ~ /^nc/ && bc[k] < 1) bc[k] = 1 } }
function ty(src, chip, dev) { if (src == "ipmi") return "bmc"; if (chip ~ /^(coretemp|k10temp|zenpower|cpu_thermal)$/) return "cpu"
    if (chip ~ /^nvme/) return "nvme"; if (chip ~ /^(mlx5|ice|bnxt|i40e|ixgbe|igb|tg3|qede|nfp)/ || dev ~ /^(en|eth|ib|bond)/) return "nic"; return "other" }
END { print "Host Source Type Chip Dev Sensor First_C Max_C Last_C High_C Crit_C Flag"
    for (i = 1; i <= n; i++) { k = ord[i]; split(k, p, SUBSEP); f = "-"
        if (bc[k] == 2 || ((k in cr) && mx[k] >= cr[k])) f = "crit"
        else if (bc[k] == 1 || ((k in hi) && mx[k] >= hi[k])) f = "high"
        else if ((k in hi) && mx[k] >= hi[k] - margin) f = "near"
        if (mx[k] - fi[k] > rise) f = (f == "-" ? "" : f "+") "rise"
        printf "%s %s %s %s %s %s %.1f %.1f %.1f %s %s %s\n", p[1], p[2], ty(p[2], p[3], p[4]), p[3], p[4], p[5], fi[k], mx[k], la[k],
               ((k in hi) ? hi[k] : "-"), ((k in cr) ? cr[k] : "-"), f }
    for (x in nd) if (!(x in got)) { split(x, p, SUBSEP); print p[1], p[2], "-", "-", "-", "none", "-", "-", "-", "-", "-", "nodata:" nd[x] } }
