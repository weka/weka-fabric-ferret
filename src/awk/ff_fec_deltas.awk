NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
    ($1, 2) in p {printf "%s %s %d", t, $1, s
        for (i = 2; i <= 5; i++) printf " %s", ($i ~ /^[0-9]+$/ && p[$1, i] ~ /^[0-9]+$/) ? ($i + 0 >= p[$1, i] + 0 ? $i - p[$1, i] : "reset") : ($i == "off" ? "off" : "na")
        print ""}
