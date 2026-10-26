NR > 1 && $6 != "none" {if (!(($1, $3) in m) || $8 > m[$1, $3]) m[$1, $3] = $8; hs[$1] = 1; if ($12 != "-") fl[$1] = fl[$1] (fl[$1] == "" ? "" : ",") $3 ":" $12}
     END {print "Host CPU_max NVMe_max NIC_max Other_max BMC_max Flags"
          for (x in hs) printf "%s %s %s %s %s %s %s\n", x, (((x, "cpu") in m) ? m[x, "cpu"] : "-"), (((x, "nvme") in m) ? m[x, "nvme"] : "-"),
              (((x, "nic") in m) ? m[x, "nic"] : "-"), (((x, "other") in m) ? m[x, "other"] : "-"), (((x, "bmc") in m) ? m[x, "bmc"] : "-"), (x in fl ? fl[x] : "-")}
