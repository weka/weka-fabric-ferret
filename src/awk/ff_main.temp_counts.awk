NR > 1 && $6 != "none" {n++; if (!($1 in h)) {h[$1] = 1; nh++}; if ($12 != "-") {f++; if (!($1 in fh)) {fh[$1] = 1; nf++}}}
     END {printf "  %d sensors on %d hosts; %d flagged on %d hosts\n", n, nh, f, nf}
