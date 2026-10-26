NR > 1 && $6 != "none" { k = $1 " " ($2 == "gpu" ? "hwmon" : $2); if (!(k in n)) ord[++nk] = k; n[k]++
    if (!((k, $3) in m) || $8 > m[k, $3]) m[k, $3] = $8
    if ($12 != "-" && index("," fl[k] ",", "," $3 ":" $12 ",") == 0) fl[k] = fl[k] (fl[k] == "" ? "" : ",") $3 ":" $12 }
    END { split("inlet cpu gpu mem nvme nic other", ty, " "); print "Host Source Sensors Inlet CPU GPU Mem NVMe NIC Other Flags"
          for (i = 1; i <= nk; i++) { k = ord[i]; l = k " " n[k]; for (j = 1; j <= 7; j++) l = l " " (((k, ty[j]) in m) ? m[k, ty[j]] : "-"); print l, (k in fl ? fl[k] : "-") } }
