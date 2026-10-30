#!/opt/homebrew/bin/bash
# stdout/stderr split, GPUs and an HGX-style BMC (from test_thermals.sh, split into sections 10-26)

# checks: 22
# secs: 30
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- stdout: one row per host and source; stderr: the rest (10-26) ---
CASES="198.19.123.1:gpu 198.19.123.2:all 198.19.123.3:down"
d=$W/so; mkdir -p $d/fake $d/out; for tc in $CASES; do echo "${tc#*:}" > "$d/fake/case.${tc%%:*}"; done
( cd $d && env PATH=$H/fake:$PATH FAKE_TC=$d/fake FF_OUT_DIR=$d/out FF_HOSTS=198.19.123.1-3 $B $TC > $d/stdout 2> $d/stderr ); rc=$?
nsens=$(jq -r 'select(.type == "sensor")' $d/out/*.jsonl | jq -s length)
nhw1=$(jq -r 'select(.type == "sensor" and .host == "n1" and (.source == "hwmon" or .source == "gpu"))' $d/out/*.jsonl | jq -s length)
# expected by hand from the fixtures, one row per host merged by type (10-28): the gpu cells are nvidia-smi's
# when it answered, else the BMC's; every other type the BMC's, else hwmon's. n1: nvidia-smi gpu 38/40/84 (54.0, gpu1
# near) over the BMC's 38/40; BMC inlet 23, mem 29, nvme 29/50 (39.5), nic 46, other VRM 41/PLX 35 (38.0); hwmon fills
# cpu = Package 60, Core 0 58, Tctl 55.1 (57.7). Sensors counts every sensor, all sources (10-28 22:09): n1 BMC 9 +
# nvidia-smi 3 + hwmon 6 = 18. n2: BMC inlet 24, other 52 (high); hwmon cpu (3), nvme 44.9, nic mlx5 62 / ice 58 (60.0): 2 + 6
exp_so='Host Source Sensors Inlet Avg CPU Avg GPU Avg Mem Avg NVMe Avg NIC Avg Other Avg Flags
n1 ipmi+nvidia-smi+hwmon 18 23.0 23.0 60.0 57.7 84.0 54.0 29.0 29.0 50.0 39.5 46.0 46.0 41.0 38.0 gpu:near
n2 ipmi+hwmon 8 24.0 24.0 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 52.0 52.0 other:high'
chk "stdout: one row per host merged by type (10-28): n1 = nvidia-smi gpu (84.0 54.0, gpu:near) + BMC inlet/mem/nvme/nic/other + hwmon cpu, Sensors 18 = all its sensors, n2 = BMC inlet/other + hwmon cpu/nvme/nic (8); the two counts sum to the jsonl's 26 sensor records; aligned, nothing else" \
    "[ \"\$(awk '{\$1 = \$1; print}' $d/stdout)\" = \"\$exp_so\" ] && [ \$(awk 'NR > 1 {s += \$3} END {print s}' $d/stdout) = $nsens ] && [ $nsens = 26 ] && grep -qE '^Host  +Source  +Sensors  +Inlet  +Avg' $d/stdout" "$(diff <(echo "$exp_so") <(awk '{$1 = $1; print}' $d/stdout))"
chk "stdout: n1's gpu cells and gpu:near are nvidia-smi's although the BMC has gpu sensors (control: the hgx run below, BMC gpu and no nvidia-smi, shows 40.0 39.0 and no near); the BMC's 2 gpu sensors stay in the jsonl; gpu1 core near in stderr's flagged block" \
    "[ \$(grep -c 'gpu:near' $d/stdout) = 1 ] && [ $nhw1 = 9 ] && [ \$(jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .source == \"ipmi\" and .kind == \"gpu\") | .sensor' $d/out/*.jsonl | wc -l | tr -d ' ') = 2 ] && grep -qE '^ +n1 +gpu +gpu .* gpu1 +core +84\\.0 .* near\$' $d/stderr && grep -q '^  Flagged sensors:' $d/stderr" "$(grep -E 'Flagged|gpu1' $d/stderr)"
# the oracle: from the jsonl's sensor records, per host and type the max of max_c and %.1f mean of last_c (one reading:
# equal) of the source the rule picks: gpu from nvidia-smi (source gpu) when present, else ipmi, else hwmon; other
# types ipmi, else hwmon; Source = the sources used in the order ipmi, nvidia-smi, hwmon; Sensors = all the host's sensor
# records; Flags = the shown cells' flags in type order, then the other sources' flags as type:flag/source; the stdout
# rows must equal it
oracle() { jq -r 'select(.type == "sensor") | "\(.host) \(.source) \(.kind) \(.max_c) \(.flag) \(.last_c)"' "$@" | awk '
    { s = $2; if (!($1 in seen)) { seen[$1]; o[++nk] = $1 }; n[$1]++
      if (!(($1, s, $3) in c) || $4 > m[$1, s, $3]) m[$1, s, $3] = $4; t[$1, s, $3] += $6; c[$1, s, $3]++
      if ($5 != "null" && index("," fl[$1, s, $3] ",", "," $3 ":" $5 ",") == 0) fl[$1, s, $3] = fl[$1, s, $3] (fl[$1, s, $3] == "" ? "" : ",") $3 ":" $5 }
    END { split("inlet cpu gpu mem nvme nic other", ty, " ")
          for (i = 1; i <= nk; i++) { h = o[i]; l = ""; f = ""; u = ""; delete sh
              for (j = 1; j <= 7; j++) { s = ""
                  if (ty[j] == "gpu" && ((h, "gpu", ty[j]) in c)) s = "gpu"; else if ((h, "ipmi", ty[j]) in c) s = "ipmi"; else if ((h, "hwmon", ty[j]) in c) s = "hwmon"
                  if (s == "") { l = l " - -"; continue }
                  u = u " " s; sh[s, ty[j]]; l = l " " sprintf("%.1f %.1f", m[h, s, ty[j]], t[h, s, ty[j]] / c[h, s, ty[j]])
                  if (fl[h, s, ty[j]] != "") f = f (f == "" ? "" : ",") fl[h, s, ty[j]] }
              for (j = 1; j <= 7; j++) for (k = 1; k <= 2; k++) { s = (k == 1 ? "ipmi" : "hwmon")
                  if (fl[h, s, ty[j]] != "" && !((s, ty[j]) in sh)) { x = fl[h, s, ty[j]]; gsub(",", "/" s ",", x); f = f (f == "" ? "" : ",") x "/" s } }
              sc = (index(u, " ipmi") ? "ipmi" : ""); if (index(u, " gpu")) sc = sc (sc == "" ? "" : "+") "nvidia-smi"; if (index(u, " hwmon")) sc = sc (sc == "" ? "" : "+") "hwmon"
              print h, sc, n[h] l, (f == "" ? "-" : f) } }' | sort; }
orc=$(oracle $d/out/*.jsonl)
chk "stdout: every row equals the jsonl oracle built by the rule (Source, Sensors, 14 cells, Flags; 2 rows; control: a planted +1 on one oracle cell differs)" \
    "[ \"\$(awk 'NR > 1 {\$1 = \$1; print}' $d/stdout | sort)\" = \"\$orc\" ] && [ \$(wc -l <<<\"\$orc\") = 2 ] && [ \"\$(sed '1s/23.0 23.0/23.0 24.0/' <<<\"\$orc\")\" != \"\$orc\" ]" "$(diff <(echo "$orc") <(awk 'NR > 1 {$1 = $1; print}' $d/stdout | sort))"
chk "stdout: a type with one sensor shows the same value twice (n2 inlet 24.0 24.0, other 52.0 52.0; n1 nic 46.0 46.0); control: n1 nvme, 2 BMC sensors, 50.0 vs 39.5" \
    "awk '{\$1 = \$1; print}' $d/stdout | grep -qx 'n2 ipmi+hwmon 8 24.0 24.0 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 52.0 52.0 other:high' && awk '\$1 == \"n1\" && \$14 == \$15 && \$14 == \"46.0\" {f = 1} END {exit !f}' $d/stdout && awk '\$1 == \"n1\" && \$12 == \"50.0\" && \$13 == \"39.5\" {f = 1} END {exit !f}' $d/stdout" "$(grep -E '^n[12] ' $d/stdout)"
# --- a BMC without a gpu sensor on a host with nvidia-smi (case gpubmc0: gpu's nvidia-smi, all's plain BMC): the gpu
# cells are nvidia-smi's, the gpu1 near on stdout, Source ipmi+nvidia-smi+hwmon; then gpunobmc (no ipmitool at all):
# Source nvidia-smi+hwmon with an ipmi nodata record ---
CASES="198.19.127.1:gpubmc0"
out=$(run gpubmc0 FF_HOSTS=198.19.127.1 $B $TC -o jsonl); rc=$?
chk "stdout: BMC without gpu + nvidia-smi: gpu cells from nvidia-smi (84.0, 54.0 of 38/40/84), gpu:near shown, Source ipmi+nvidia-smi+hwmon, 11 sensors (BMC 2 + nvidia-smi 3 + hwmon cpu 3, nvme 1, nic 2)" \
    "awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n1 ipmi+nvidia-smi+hwmon 11 24.0 24.0 60.0 57.7 84.0 54.0 - - 44.9 44.9 62.0 60.0 52.0 52.0 gpu:near,other:high' && [ \$(jl gpubmc0 | jq -r 'select(.type == \"sensor\" and .source == \"ipmi\" and .kind == \"gpu\") | .sensor' | wc -l | tr -d ' ') = 0 ] && [ \$(jl gpubmc0 | jq -r 'select(.type == \"sensor\" and .source == \"gpu\") | .sensor' | wc -l | tr -d ' ') = 3 ]" "rc=$rc $(grep -E '^n1 ' <<<"$out")"
CASES="198.19.128.1:gpunobmc"
out=$(run gpunobmc FF_HOSTS=198.19.128.1 $B $TC -o jsonl); rc=$?
chk "stdout: nvidia-smi and no BMC (ipmitool missing: ipmi nodata): gpu cells nvidia-smi's with gpu:near, the rest hwmon's, Source nvidia-smi+hwmon, 9 sensors" \
    "awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n1 nvidia-smi+hwmon 9 - - 60.0 57.7 84.0 54.0 - - 44.9 44.9 62.0 60.0 - - gpu:near' && [ \$(grep -c '^n1 ' <<<\"\$out\") = 1 ] && jl gpunobmc | jq -e 'select(.type == \"nodata\" and .host == \"n1\" and .source == \"ipmi\")' > $W/gpunobmc.jq && [ \$(jl gpunobmc | jq -r 'select(.type == \"sensor\" and .source == \"ipmi\") | .sensor' | wc -l | tr -d ' ') = 0 ]" "rc=$rc $(grep -E '^n1 |NO TEMP' <<<"$out")"
# --- the hwmon row when the BMC gave nothing: n1's ipmitool is missing (ipmi nodata), n2's BMC answers (control);
# then FF_IPMI=0 on the same n2: no BMC asked, its hwmon row ---
CASES="198.19.125.1:noipmi 198.19.125.2:all"
out=$(run noipmi FF_HOSTS=198.19.125.1,198.19.125.2 $B $TC -o jsonl); rc=$?
chk "stdout: a host whose BMC gave nothing (n1, ipmitool missing: ipmi nodata) shows its hwmon row, Source hwmon; the control n2 (same hwmon, BMC answered) is ipmi+hwmon with the BMC's inlet and other" \
    "awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n1 hwmon 6 - - 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 - - -' && awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n2 ipmi+hwmon 8 24.0 24.0 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 52.0 52.0 other:high' && [ \$(grep -cE '^n[12] +(hwmon|ipmi|ipmi\\+hwmon) ' <<<\"\$out\") = 2 ] && jl noipmi | jq -e 'select(.type == \"nodata\" and .host == \"n1\" and .source == \"ipmi\")' > $W/noipmi.jq" "rc=$rc $(grep -E '^n[12] |NO TEMP' <<<"$out")"
# --- a flagged sensor behind no shown cell (10-28 22:09): case hidflag, hwmon Core 0 85 (high) while the BMC's
# CPU1 Temp 45 takes the cpu cell; the flag stays on stdout as cpu:high/hwmon, after the shown cells' flags; Sensors
# counts all 9 (BMC 3 + hwmon 6). Control n2 (case all): no hidden flag, no "/" in Flags ---
CASES="198.19.129.1:hidflag 198.19.129.2:all"
out=$(run hidflag FF_HOSTS=198.19.129.1,198.19.129.2 $B $TC -o jsonl); rc=$?
hrow=$(awk '$1 == "n1" && NF == 18 {$1 = $1; print}' <<<"$out"); crow=$(awk '$1 == "n2" && NF == 18 {$1 = $1; print}' <<<"$out")   # the stdout rows (18 fields), not stderr's flagged-table lines
chk "hidflag: n1's cpu cell is the BMC's (45.0 45.0), Source ipmi+hwmon, Sensors 9 (BMC 3 + hwmon 6), Flags other:high,cpu:high/hwmon; the hwmon Core 0 high is in the jsonl" \
    "[ \"\$hrow\" = 'n1 ipmi+hwmon 9 24.0 24.0 45.0 45.0 - - - - 44.9 44.9 62.0 60.0 52.0 52.0 other:high,cpu:high/hwmon' ] && [ \"\$(jl hidflag | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .source == \"hwmon\" and .flag == \"high\") | \"\\(.sensor) \\(.max_c)\"')\" = 'Core_0 85.0' ]" "rc=$rc $hrow"
chk "hidflag: oracle from the jsonl by jq: n1's Sensors = its sensor-record count over all sources (9), its Flags holds cpu:high/hwmon; the control row n2 (8) carries no '/'; a planted flagged line on the oracle's input counts 1 more '/' (control)" \
    "[ \$(jl hidflag | jq -r 'select(.type == \"sensor\" and .host == \"n1\") | .host' | wc -l | tr -d ' ') = 9 ] && [ \"\$(awk '\$1 == \"n1\" {print \$3}' <<<\"\$hrow\")\" = 9 ] && [ \"\$(oracle <(jl hidflag))\" = \"\$(printf '%s\n%s\n' \"\$hrow\" \"\$crow\" | sort)\" ] && [ \$(grep -c '/' <<<\"\$crow\") = 0 ] && [ \$(grep -c 'cpu:high/hwmon' <<<\"\$hrow\") = 1 ] && [ \$(oracle <(jl hidflag; echo '{\"type\":\"sensor\",\"host\":\"n2\",\"source\":\"hwmon\",\"kind\":\"other\",\"max_c\":99,\"flag\":\"high\",\"last_c\":99}') | grep -c 'other:high/hwmon') = 1 ]" "$(diff <(oracle <(jl hidflag)) <(printf '%s\n%s\n' "$hrow" "$crow" | sort))"
chk "hidflag: the row pick is positive-controlled: the merged output's 18-field lines are the stdout header and the two rows (Host n1 n2), and stderr's n1 Core_0 flagged line has 10 fields, so \$1 and NF pick the rows" \
    "[ \"\$(awk 'NF == 18 {print \$1}' <<<\"\$out\" | tr '\n' ' ')\" = 'Host n1 n2 ' ] && [ \"\$(awk '\$1 == \"n1\" && \$6 == \"Core_0\" {print NF}' <<<\"\$out\")\" = 10 ]" "$(awk '{print NF, $0}' <<<"$out" | grep -E '^(18|10) ')"
chk "hidflag control: n2 (case all, same hwmon with Core 0 58, no BMC cpu) shows hwmon's cpu cell, 8 sensors, Flags other:high only; stderr's flagged table lists n1's Core 0" \
    "[ \"\$crow\" = 'n2 ipmi+hwmon 8 24.0 24.0 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 52.0 52.0 other:high' ] && grep -qE '^ +n1 +hwmon +cpu +coretemp .* Core_0 +85\\.0 .* high\$' <<<\"\$out\"" "rc=$rc $crow $(grep -E 'Core_0' <<<"$out")"
CASES="198.19.126.1:all"
out=$(run ipmi0 FF_IPMI=0 FF_HOSTS=198.19.126.1 $B $TC -o jsonl); rc=$?
chk "stdout: FF_IPMI=0 on a host whose BMC would answer (case all, the n2 above): its hwmon row, one row, no ipmi record in the jsonl" \
    "awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n1 hwmon 6 - - 60.0 57.7 - - - - 44.9 44.9 62.0 60.0 - - -' && [ \$(grep -cE '^n1 +(hwmon|ipmi) ' <<<\"\$out\") = 1 ] && [ \$(jl ipmi0 | jq -r 'select(.source == \"ipmi\") | .source' | wc -l | tr -d ' ') = 0 ] && [ \$(jl ipmi0 | jq -r 'select(.type == \"sensor\" and .source == \"hwmon\") | .source' | wc -l | tr -d ' ') = 6 ]" "rc=$rc $(grep -E '^n1 ' <<<"$out")"
chk "stderr: the summary, then the count line and RESULT last; none of them on stdout" \
    "grep -q '^Temperatures, one reading' $d/stderr && [ \"\$(tail -n 2 $d/stderr | head -n 1)\" = 'Unreachable: 1 (no ssh connection; -v lists them), unavailable: 0 (connected, no readings)' ] && tail -n 1 $d/stderr | grep -q '^RESULT data=COMPLETE hosts=2/2 .* unreachable=1\$'" "rc=$rc $(tail -n 3 $d/stderr)"

# --- GPUs (nvidia-smi) and an HGX-style BMC, typed by what each sensor measures ---
CASES="198.19.122.1:gpu 198.19.122.2:gpufail 198.19.122.3:gpunosmi 198.19.122.4:gpupci"
out=$(run gpu FF_HOSTS=198.19.122.1,198.19.122.2,198.19.122.3,198.19.122.4 $B $TC -o jsonl,md); rc=$?
chk "gpu: NVIDIA GPUs on the PCI bus, no driver, no nvidia-smi (the operator's GPU nodes): loud no-data counting 2 GPUs (not the bridge or the NIC)" \
    "grep -q 'NO TEMPERATURE DATA: n4 gpu (2_nvidia_gpus_on_pci_but_no_nvidia-smi_or_driver_here)' <<<\"\$out\" && ! grep -q 'NO TEMPERATURE DATA: n1 gpu' <<<\"\$out\"" "$(grep 'NO TEMP' <<<"$out")"
chk "gpu: a loaded NVIDIA driver with no nvidia-smi anywhere is loud no-data (the operator's 42 GPU hosts had no GPU row at all)" \
    "grep -q 'NO TEMPERATURE DATA: n3 gpu (nvidia_driver_loaded_but_no_nvidia-smi_found)' <<<\"\$out\"" "$(grep 'NO TEMP' <<<"$out")"
chk "gpu: nvidia-smi gpu0 core 38 (high 85 crit 92), memory 40 (high 95); gpu1 T.Limit format: core 84, high 87, crit 92 -> near" \
    "[ \"\$(jl gpu | jq -r 'select(.type == \"sensor\" and .source == \"gpu\") | \"\\(.dev):\\(.sensor):\\(.max_c):\\(.high_c):\\(.crit_c):\\(.flag)\"' | tr '\n' ' ')\" = 'gpu0:core:38.0:85.0:92.0:null gpu0:memory:40.0:95.0:null:null gpu1:core:84.0:87.0:92.0:near ' ]" "$(jl gpu | jq -c 'select(.source == "gpu")')"
chk "gpu: BMC sensors typed by name: inlet, other (CPU VRM, PLX), mem (DIMM), nic (AOC), nvme (NVMe, M2SSD), gpu (HGX GPU/HBM)" \
    "[ \"\$(jl gpu | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .source == \"ipmi\") | \"\\(.sensor)=\\(.kind)\"' | tr '\n' ' ')\" = 'Inlet_Temp=inlet CPU1_VRMIN_Temp=other P1_DIMMA_D_Temp=mem AOC_NIC1_Temp=nic NVMe_SSDA_Temp=nvme M2SSD_Temp=nvme HGX_GPU_Temp=gpu HGX_HBM_Temp=gpu PLX1_Temp=other ' ]" "$(jl gpu | jq -c 'select(.type == "sensor" and .host == "n1" and .source == "ipmi") | [.sensor, .kind]')"
chk "gpu: md per-host table n1: Inlet 23, CPU 60, GPU 84, Mem 29, NVMe 50, NIC 62, Other 41 (the VRM); flags gpu:near" "grep -q '^| n1 | 23.0 | 60.0 | 84.0 | 29.0 | 50.0 | 62.0 | 41.0 | \\*\\*gpu:near\\*\\* |\$' $W/gpu/out/*.md && ! grep -q 'Hottest reading per host' <<<\"\$out\"" "$(grep '^| n1 ' $W/gpu/out/*.md | head -n 2)"
chk "gpu: nvidia-smi that can't reach the driver: loud no-data with its message; a host without nvidia-smi has no gpu row (control: the stdout run's n2, case all; was mix's n1 before the split)" \
    "grep -q 'NO TEMPERATURE DATA: n2 gpu (rc=9_NVIDIA-SMI_has_failed' <<<\"\$out\" && ! jl so | jq -e 'select(.host == \"n2\" and .source == \"gpu\")' > $W/gpu.jq && jl so | jq -e 'select(.host == \"n1\" and .source == \"gpu\")' > $W/gpu2.jq" "$(grep 'NO TEMP' <<<"$out")"

# --- a GPU host with no nvidia-smi whose BMC reports the GPU temperatures (the operator's 112 of 249, 10-27): a NOTE, not
# no-data; the control is n4 above (the same PCI bus, a BMC without GPU sensors: still NO TEMPERATURE DATA) ---
CASES="198.19.124.1:gpupci_hgx 198.19.124.2:all"
out=$(run hgx FF_HOSTS=198.19.124.1,198.19.124.2 $B $TC -o jsonl); rc=$?
chk "hgx: stderr says NOTE with the reason and the host, and has no NO TEMPERATURE DATA line" \
    "grep -qx '  NOTE: 1 host(s) gave no nvidia-smi reading (2_nvidia_gpus_on_pci_but_no_nvidia-smi_or_driver_here); their GPU temperatures come from the BMC (HGX GPU, HBM, NVLink): n1' <<<\"\$out\" && ! grep -q 'NO TEMPERATURE DATA' <<<\"\$out\"" "$(grep -E 'NOTE|NO TEMP' <<<"$out")"
chk "hgx: jsonl: a note record for n1 gpu (temps_from bmc), no nodata record, and n1's BMC GPU sensors typed gpu" \
    "[ \"\$(jl hgx | jq -c 'select(.type == \"note\")')\" = '{\"type\":\"note\",\"host\":\"n1\",\"source\":\"gpu\",\"why\":\"2_nvidia_gpus_on_pci_but_no_nvidia-smi_or_driver_here\",\"temps_from\":\"bmc\"}' ] && ! jl hgx | jq -e 'select(.type == \"nodata\")' > $W/hgx.jq && [ \"\$(jl hgx | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .kind == \"gpu\") | .sensor' | tr '\n' ' ')\" = 'HGX_GPU_Temp HGX_HBM_Temp ' ]" "$(jl hgx | jq -c 'select(.type == "note" or .type == "nodata" or (.type == "sensor" and .kind == "gpu"))')"
chk "hgx: rc 0, RESULT COMPLETE nodata=0 (the verdict change the operator approved 10-27); stdout GPU column from the BMC row, n1's hwmon cells hidden but counted (Sensors 15 = BMC 9 + hwmon 6, the 6 in the jsonl)" \
    "[ $rc = 0 ] && grep -qx 'RESULT data=COMPLETE hosts=2/2 sensors=[0-9]* flagged=[0-9]* nodata=0 unreachable=0' <<<\"\$out\" && jl hgx | jq -e 'select(.type == \"result\" and .nodata == 0 and .data == \"COMPLETE\")' > $W/hgx2.jq && awk '{\$1 = \$1; print}' <<<\"\$out\" | grep -qx 'n1 ipmi+hwmon 15 23.0 23.0 60.0 57.7 40.0 39.0 29.0 29.0 50.0 39.5 46.0 46.0 41.0 38.0 -' && [ \$(grep -c '^n1 ' <<<\"\$out\") = 1 ] && [ \$(jl hgx | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .source == \"hwmon\") | .sensor' | wc -l | tr -d ' ') = 6 ]" "rc=$rc $(grep -E '^n1 ' <<<"$out"; tail -n 1 <<<"$out")"
finish
