NR > 1 && $6 != "none" { h = $1; src = $2; if (!(h in seen)) { seen[h]; ord[++nk] = h }; has[h, src]++
    if (!((h, src, $3) in c) || $8 > m[h, src, $3]) m[h, src, $3] = $8
    s[h, src, $3] += $9; c[h, src, $3]++
    if ($12 != "-" && index("," fl[h, src, $3] ",", "," $3 ":" $12 ",") == 0) fl[h, src, $3] = fl[h, src, $3] (fl[h, src, $3] == "" ? "" : ",") $3 ":" $12 }
    END { split("inlet cpu gpu mem nvme nic other", ty, " "); print "Host Source Sensors Inlet Avg CPU Avg GPU Avg Mem Avg NVMe Avg NIC Avg Other Avg Flags"
          for (i = 1; i <= nk; i++) { h = ord[i]; l = ""; ns = 0; f = ""; delete used
              for (j = 1; j <= 7; j++) { t = ty[j]; src = ""
                  if (t == "gpu" && ((h, "gpu", t) in c)) src = "gpu"
                  else if ((h, "ipmi", t) in c) src = "ipmi"; else if ((h, "hwmon", t) in c) src = "hwmon"
                  if (src == "") { l = l " - -"; continue }
                  used[src]; ns += c[h, src, t]; l = l " " m[h, src, t] " " sprintf("%.1f", s[h, src, t] / c[h, src, t])
                  if (fl[h, src, t] != "") f = f (f == "" ? "" : ",") fl[h, src, t] }
              sc = ("ipmi" in used ? "ipmi" : "") (("gpu" in used) ? (("ipmi" in used) ? "+" : "") "nvidia-smi" : "")
              sc = sc (("hwmon" in used) ? (sc == "" ? "" : "+") "hwmon" : "")
              print h, sc, ns l, (f == "" ? "-" : f) } }
