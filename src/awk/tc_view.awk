function f(x) { return x == "-" ? x : sprintf("%.1f", x) }
NR == 1 { print "Host Source Type Chip Dev Sensor", (ns > 1 ? "First Min Max Last" : "Temp"), "High Crit Flag"; next }
$12 ~ /^nodata/ { next }
ns > 1 { print $1, $2, $3, $4, $5, $6, f($7), f($13), f($8), f($9), f($10), f($11), $12; next }
{ print $1, $2, $3, $4, $5, $6, f($8), f($10), f($11), $12 }
