FILENAME == ARGV[1] { if (FNR > 1 && $6 != "none") { k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6; v = $7 + 0; if (!(k in mn) || v < mn[k]) mn[k] = v } next }
FNR == 1 { print $0, "Min_C"; next }
$6 == "none" { print $0, "-"; next }
{ s = tolower($6)
  if ($2 == "gpu") $3 = "gpu"
  else if ($2 == "ipmi") $3 = s ~ /inlet|ambient/ ? "inlet" : s ~ /vrm|vr_|psu|board|fpga|hmc|hsc|plx|pex|pch|sas/ ? "other" : s ~ /nic|aoc|ocp|cx[0-9]|lom|port/ ? "nic" : s ~ /gpu|hbm|nvlink|nvsw/ ? "gpu" : s ~ /nvme|ssd|m\.?2|drive|disk/ ? "nvme" : s ~ /dimm|mem/ ? "mem" : s ~ /cpu|proc|soc/ ? "cpu" : "other"
  else if ($4 ~ /^(amdgpu|nouveau)/) $3 = "gpu"
  else if ($4 ~ /^drivetemp/) $3 = "nvme"
  else if ($4 ~ /^(jc42|spd5118)/) $3 = "mem"
  print $0, sprintf("%.1f", mn[$1 SUBSEP $2 SUBSEP $4 SUBSEP $5 SUBSEP $6]) }
