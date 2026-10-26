NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
    ($1, 2) in p {printf "%s %s", t, $1; for (i = 2; i <= 5; i++) printf " %d", $i - p[$1, i]; print ""}
