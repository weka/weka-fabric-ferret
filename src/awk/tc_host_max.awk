NR > 1 && $6 != "none" {if (!(($1, $3) in m) || $8 > m[$1, $3]) m[$1, $3] = $8; hs[$1] = 1; if ($12 != "-" && index("," fl[$1] ",", "," $3 ":" $12 ",") == 0) fl[$1] = fl[$1] (fl[$1] == "" ? "" : ",") $3 ":" $12}
    END {split("inlet cpu gpu mem nvme nic other", ty, " ")
         for (x in hs) { l = x; for (i = 1; i <= 7; i++) l = l " " (((x, ty[i]) in m) ? m[x, ty[i]] : "-"); print l, (x in fl ? fl[x] : "-") } }
