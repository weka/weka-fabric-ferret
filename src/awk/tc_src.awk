NR > 1 && $6 != "none" { h = $1; src = $2; if (!(h in seen)) { seen[h]; ord[++nk] = h }; n[h]++
    if (!((h, src, $3) in c) || $8 > m[h, src, $3]) m[h, src, $3] = $8
    s[h, src, $3] += $9; c[h, src, $3]++
    if ($12 != "-" && index("," fl[h, src, $3] ",", "," $3 ":" $12 ",") == 0) fl[h, src, $3] = fl[h, src, $3] (fl[h, src, $3] == "" ? "" : ",") $3 ":" $12 }
    END { split("inlet cpu gpu mem nvme nic other", ty, " "); print "Host Source Sensors Inlet Avg CPU Avg GPU Avg Mem Avg NVMe Avg NIC Avg Other Avg Flags"
          for (i = 1; i <= nk; i++) { h = ord[i]; l = ""; f = ""; delete used; delete shown
              for (j = 1; j <= 7; j++) { t = ty[j]; src = ""
                  if (t == "gpu" && ((h, "gpu", t) in c)) src = "gpu"
                  else if ((h, "ipmi", t) in c) src = "ipmi"; else if ((h, "hwmon", t) in c) src = "hwmon"
                  if (src == "") { l = l " - -"; continue }
                  used[src]; shown[src, t]; l = l " " m[h, src, t] " " sprintf("%.1f", s[h, src, t] / c[h, src, t])
                  if (fl[h, src, t] != "") f = f (f == "" ? "" : ",") fl[h, src, t] }
              for (j = 1; j <= 7; j++) for (k = 1; k <= 2; k++) { t = ty[j]; src = (k == 1 ? "ipmi" : "hwmon")
                  if (fl[h, src, t] != "" && !((src, t) in shown)) { x = fl[h, src, t]; gsub(",", "/" src ",", x); f = f (f == "" ? "" : ",") x "/" src } }
              sc = ("ipmi" in used ? "ipmi" : "") (("gpu" in used) ? (("ipmi" in used) ? "+" : "") "nvidia-smi" : "")
              sc = sc (("hwmon" in used) ? (sc == "" ? "" : "+") "hwmon" : "")
              print h, sc, n[h] l, (f == "" ? "-" : f) } }
