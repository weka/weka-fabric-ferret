# The runs to confirm, in launch order: "wave_no bps_per_stream nth src dst port len target".
# trig is the whole trigger, per receiving host: loss beyond expected, pct % or more of what was sent to it.
function trig(h) { return bey[h] > 0 && bey[h] >= pct / 100 * sent[h] }
FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }
f == 1 { if ($1 == "H") { bey[$2] = $3; sent[$2] = $4 }; next }
f == 2 { host[$1] = $2; next }
f == 3 { if ($1 " " $2 == t) G[$4, $5, ++n3[$4, $5]] = $11; next }
f == 4 { c = ++n4[$2, $3]
         if (!trig(host[$3]) || !(($2, $3, c) in G)) next
         bps = int(0.8 * G[$2, $3, c] * 1e9 / streams); if (bps < 1) next
         if (!($1 in gid)) gid[$1] = ++ng
         print gid[$1], bps, c, $2, $3, $4, $5, $6 }
