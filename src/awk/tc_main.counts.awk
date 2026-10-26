NR > 1 && $6 != "none" {s++; if ($12 != "-") f++; if (!($1 in h)) {h[$1] = 1; hw++}} NR > 1 && $12 ~ /^nodata/ {d++}
    END {print s + 0, f + 0, d + 0, hw + 0}
