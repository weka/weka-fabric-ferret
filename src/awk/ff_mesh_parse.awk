FILENAME == ARGV[1] {h[$1] = $2; rl[$1] = $3; next}
     {hs = ($2 in h) ? h[$2] : "?"; hd = ($3 in h) ? h[$3] : "?"}
     $1 == "MESHLOSS" && $4 >= $5 {print hs, $2, hd, $3 sfx > fb; next}
     $1 == "MESHLOSS" {print hs, $2, hd, $3, $4, $5 sfx > fl; next}
     $1 == "MESHROUTE" {cls = (sfx != "") ? "client" : ((rl[$2] == rl[$3]) ? "same" : "cross")
         print hs, $2, hd, $3, ($4 == "" ? "-" : $4), cls > fu; print $2, $3 > fx}
