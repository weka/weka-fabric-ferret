BEGIN { FS = "|" }
{ for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i) }
NR == 1 { first = $0 }
$3 == "degrees C" && $2 ~ /^-?[0-9.]+$/ { nm = $1; gsub(/[^A-Za-z0-9_.:-]/, "_", nm); n++
    print t, h, "ipmi", "bmc", "lanplus", nm, sprintf("%.1f", $2), ($8 ~ /^-?[0-9.]+$/ ? $8 : "-"), ($9 ~ /^-?[0-9.]+$/ ? $9 : "-"), ($4 == "" ? "-" : $4) }
END { if (!n) { w = (rc == 124 ? "ipmitool_timed_out_after_" to "s" : "rc=" rc "_" first); gsub(/[^A-Za-z0-9_.:=-]/, "_", w)
          print t, h, "ipmi", "bmc", "lanplus", "none", "-", "-", "-", substr(w, 1, 120) } }
