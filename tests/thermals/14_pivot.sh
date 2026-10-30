#!/opt/homebrew/bin/bash
# html and md per-type tables, types, per-device columns (from test_thermals.sh, split into sections 10-26)

# checks: 16
# secs: 17
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- html per-type tables (10-26): one row per host; columns grouped by device (a device header over its sensors);
# cells the temperature only, the crit under the sensor name (in the cell when hosts differ); BMC names without
# "bmc:" and "_Temp"; flagged cells shaded; coloured headers; a scrollbar that stays on screen ---
CASES="198.19.124.1:gpu 198.19.124.2:all 198.19.124.10:hot"
out=$(run pv FF_HOSTS=198.19.124.1,198.19.124.2,198.19.124.10 $B $TC -o html,md); rc=$?
hp=$(cat $W/pv/out/*.html 2>&1); mp=$(cat $W/pv/out/*.md 2>&1)
# --- Markdown laid out like the html (10-26: "give the markdown output file a reorg") ---
chk "md: by type like the html: contents links each type (OS + BMC count); a section per type with its OS then BMC / IPMI table" \
    "grep -qx '\\*\\*Contents:\\*\\* \\[Overview\\](#overview) · \\[Inlet\\](#inlet) (3) · \\[CPU\\](#cpu) (9) · \\[GPU\\](#gpu) (5) · \\[Mem\\](#mem) (1) · \\[NVMe\\](#nvme) (5) · \\[NIC\\](#nic) (7) · \\[Other\\](#other) (4)' <<<\"\$mp\" && [ \"\$(grep -E '^##+ ' <<<\"\$mp\" | head -n 9 | tr '\n' '|')\" = '## Overview|### Hottest reading per host and type (°C)|### Flagged sensors|## Inlet|### BMC / IPMI · 3 readings|## CPU|### OS (hwmon, nvidia-smi) · 9 readings|## GPU|### OS (hwmon, nvidia-smi) · 3 readings|' ]" "$(grep -E '^(##|\*\*Contents)' <<<"$mp" | head -n 14)"
chk "md: BMC table: a column per sensor with the crit in its header, a flagged reading bold with its flag (n10 inlet 39 high)" \
    "grep -qx '| Host | Inlet (crit 42.0) |' <<<\"\$mp\" && grep -qx '| n10 | \\*\\*39.0 high\\*\\* |' <<<\"\$mp\" && grep -qx '| Host | HGX GPU (crit 89.0) | HGX HBM (crit 105.0) |' <<<\"\$mp\"" "$(sed -n '/^## Inlet/,/^## CPU/p' <<<"$mp")"
chk "md: OS table: a column per device (gpu0 nvidia, gpu1 nvidia), each cell its sensors; gpu1 core bold near" \
    "grep -qx '| Host | gpu0 nvidia | gpu1 nvidia |' <<<\"\$mp\" && grep -qx '| n1 | core 38.0 · memory 40.0 | core \\*\\*84.0 near\\*\\* |' <<<\"\$mp\"" "$(sed -n '/^## GPU/,/^## Mem/p' <<<"$mp")"
chk "md: no every-sensor dump; points to the jsonl" "! grep -q '^## Every sensor' <<<\"\$mp\" && grep -qx 'Every single reading is in the jsonl (-o jsonl).' <<<\"\$mp\""
gpup=$(ptab "$hp" gpu os)
chk "pivot: os-gpu device row gpu0 (2 columns) and gpu1 (1); sensor row core / memory / core with crit 92.0 / no crit / crit 92.0" \
    "grep -q '<th class=\"host\" data-col=\"0\" rowspan=\"2\">Host</th><th class=\"grp\" colspan=\"2\">gpu0<span class=\"chip\">nvidia</span></th><th class=\"grp\" colspan=\"1\">gpu1<span class=\"chip\">nvidia</span></th></tr><tr><th class=\"n gs\" data-col=\"1\">core<span class=\"dev\">crit 92.0</span></th><th class=\"n\" data-col=\"2\">memory<span class=\"dev\">no crit</span></th><th class=\"n gs\" data-col=\"3\">core<span class=\"dev\">crit 92.0</span></th>' <<<\"\$gpup\"" "$(grep '<thead>' <<<"$gpup" | cut -c1-700)"
chk "pivot: os-gpu n1 cells are the temperature only; gpu1 core (near) shaded" \
    "grep -q '<tr><td class=\"host\">n1</td><td class=\"n gs\" data-v=\"38.0\">38.0</td><td class=\"n\" data-v=\"40.0\">40.0</td><td class=\"n gs near\" data-v=\"84.0\">84.0</td></tr>' <<<\"\$gpup\"" "$(grep '<tr><td' <<<"$gpup" | head -n 2)"
chk "pivot: BMC tables: one header row, names without bmc: and _Temp (Inlet, HGX GPU), crit under the name" \
    "ptab \"\$hp\" inlet bmc | grep -q '<thead><tr><th class=\"host\" data-col=\"0\">Host</th><th class=\"n gs\" data-col=\"1\">Inlet<span class=\"dev\">crit 42.0</span></th></tr></thead>' && ptab \"\$hp\" gpu bmc | grep -q '>HGX GPU<span class=\"dev\">crit 89.0</span></th>' && ! grep -q '>bmc:' <<<\"\$hp\"" "$(ptab "$hp" inlet bmc | grep '<thead>' | cut -c1-400)"
chk "pivot: coloured headers (--head), flag shading on cells, table box capped at the window with styled scrollbars" \
    "grep -q 'th { background: var(--head); color: var(--head-ink);' <<<\"\$hp\" && grep -q 'td.crit { background: var(--critbg)' <<<\"\$hp\" && grep -q 'max-height: calc(100vh - 150px)' <<<\"\$hp\" && grep -q '.wrap::-webkit-scrollbar { width: 12px; height: 12px; }' <<<\"\$hp\""
chk "pivot: os-cpu rows in host version order (n1 n2 n10); sensors in any-case version order under their device (Core 0, Package id 0 | Tctl)" \
    "[ \"\$(ptab \"\$hp\" cpu os | grep -o '<tr><td class=\"host\">[^<]*' | sed 's/.*>//' | tr '\n' ' ')\" = 'n1 n2 n10 ' ] && ptab \"\$hp\" cpu os | grep -q 'data-col=\"1\">Core 0<span class=\"dev\">crit 100.0</span></th><th class=\"n\" data-col=\"2\">Package id 0<span class=\"dev\">crit 100.0</span></th><th class=\"n gs\" data-col=\"3\">Tctl<span class=\"dev\">no crit</span></th>'" "$(ptab "$hp" cpu os | head -n 6 | cut -c1-500)"
chk "pivot: a host with nothing of a type has no row (n2 in os-gpu); a missing column is '-'; a flagged BMC cell shaded (n2 Exhaust high)" \
    "ptab \"\$hp\" gpu os | grep -q '<td class=\"host\">n1<' && ! ptab \"\$hp\" gpu os | grep -q '<td class=\"host\">n2<' && ptab \"\$hp\" other bmc | grep -q '<tr><td class=\"host\">n2</td><td class=\"n gs\" data-v=\"\">-</td><td class=\"n high\" data-v=\"52.0\">52.0</td><td class=\"n\" data-v=\"\">-</td></tr>'" "$(ptab "$hp" other bmc | cut -c1-400)"
chk "types (10-26: misfiled): BMC CPU VRM is other, not cpu; the CPU page has an OS table and no BMC table for a BMC with only a VRM" \
    "ptab \"\$hp\" other bmc | grep -q '>CPU1 VRMIN<' && [ -n \"\$(ptab \"\$hp\" cpu os)\" ] && [ -z \"\$(ptab \"\$hp\" cpu bmc)\" ]"
# the BMC names from the operator's HGX hosts (cg-gpu-*), typed by the same rule TYPE_AWK uses
ty=$(printf '%s\n' HGX_CX8_Temp HGX_CX8_PORT HGX_GPU_Temp HGX_HBM_Temp HGX_NVLink_Temp HGX_Board_Temp HGX_FPGA_Temp HGX_HMC_Temp HGX_HSC_Temp HGX_NVMGMT_Temp HGX_Inlet_Temp CPU1_Temp CPU1_VRMIN_Temp AOM_SAS_Temp PLX1_Temp M2SSD_Temp | awk 'BEGIN { print "Label Host Source Chip Dev Sensor Temp_C High_C Crit_C Status" } { print "s1 hx ipmi bmc -", $1, "30", "-", "-", "ok" }' > $W/ty.txt; awk "$(source $TC; echo "$TEMP_SUM_AWK")" margin=5 rise=10 $W/ty.txt > $W/ty.sum; awk "$(source $TC; echo "$TYPE_AWK")" $W/ty.txt $W/ty.sum | awk 'NR > 1 {print $6 "=" $3}' | tr '\n' ' ')
chk "types on the operator's HGX BMC names: CX8 nic; GPU/HBM/NVLink gpu; board, FPGA, HMC, HSC, NVMGMT, VRM, SAS, PLX other; CPU1 cpu; M2SSD nvme; HGX inlet" \
    "[ \"\$ty\" = 'HGX_CX8_Temp=nic HGX_CX8_PORT=nic HGX_GPU_Temp=gpu HGX_HBM_Temp=gpu HGX_NVLink_Temp=gpu HGX_Board_Temp=other HGX_FPGA_Temp=other HGX_HMC_Temp=other HGX_HSC_Temp=other HGX_NVMGMT_Temp=other HGX_Inlet_Temp=inlet CPU1_Temp=cpu CPU1_VRMIN_Temp=other AOM_SAS_Temp=other PLX1_Temp=other M2SSD_Temp=nvme ' ]" "$ty"
# planted bug (10-26): TYPE_AWK without its gpu/hbm/nvlink rule must fail the HGX list (GPU/HBM/NVLink not gpu)
tyb=$(awk "$(source $TC; echo "$TYPE_AWK" | perl -pe 's/ : s ~ \/gpu\|hbm\|nvlink\|nvsw\/ \? "gpu"//')" $W/ty.txt $W/ty.sum | awk 'NR > 1 {print $6 "=" $3}' | tr '\n' ' ')
chk "planted bug (no gpu rule in TYPE_AWK): HGX_GPU/HBM/NVLink are no longer gpu" "[ -n \"\$tyb\" ] && ! grep -q 'HGX_GPU_Temp=gpu' <<<\"\$tyb\" && [ \"\$tyb\" != \"\$ty\" ]" "$tyb"
# 10-26: "#1, #2" columns were numbered per host, so one column held different devices on different hosts.
# n1 has mlx5 enp5s0np0; n2 has enp4s0np0 and enp5s0np0. A column must hold the same device on every host.
CASES="198.19.125.1:all 198.19.125.2:nic2"
out=$(run nicx FF_HOSTS=198.19.125.1,198.19.125.2 $B $TC -o html); hx=$(cat $W/nicx/out/*.html 2>&1)
nicp=$(ptab "$hx" nic os)
chk "pivot columns are per device: device row ens1f0, enp4s0np0, enp5s0np0; n1 '-' under enp4s0np0, n2 71.0 there" \
    "grep -q '<th class=\"grp\" colspan=\"1\">ens1f0<span class=\"chip\">ice</span></th><th class=\"grp\" colspan=\"1\">enp4s0np0<span class=\"chip\">mlx5</span></th><th class=\"grp\" colspan=\"1\">enp5s0np0<span class=\"chip\">mlx5</span></th>' <<<\"\$nicp\" && grep -q '<tr><td class=\"host\">n1</td><td class=\"n gs\" data-v=\"58.0\">58.0</td><td class=\"n gs\" data-v=\"\">-</td>' <<<\"\$nicp\" && grep -q '<tr><td class=\"host\">n2</td><td class=\"n gs\" data-v=\"58.0\">58.0</td><td class=\"n gs\" data-v=\"71.0\">71.0</td>' <<<\"\$nicp\"" "$(grep -E '<th|<tr><td' <<<"$nicp" | cut -c1-700)"
chk "pivot: a sensor whose crit differs by host (enp5s0np0: 105 on n1, 100 on n2) says temp / crit and keeps the crit in each cell" \
    "grep -q 'data-col=\"3\">temp1<span class=\"dev\">temp / crit</span></th>' <<<\"\$nicp\" && grep -q '<td class=\"n gs\" data-v=\"62.0\">62.0 / 105.0</td></tr>' <<<\"\$nicp\" && grep -q '<td class=\"n gs\" data-v=\"62.0\">62.0 / 100.0</td></tr>' <<<\"\$nicp\"" "$(grep -E '<th|<tr><td' <<<"$nicp" | cut -c1-700)"
if [[ -x $CHROME ]]; then
    f=$(ls $W/pv/out/*.html); awk '{ if ($0 == "</body>") print "<script>function hs() { return Array.prototype.map.call(document.querySelectorAll(\"#p-cpu tbody tr td:first-child\"), function (c) { return c.textContent; }).join(\",\"); } var th = document.querySelector(\"#p-cpu th[data-col=\\\"2\\\"]\"); th.click(); var a = hs(); th.click(); var b = hs(); var h = document.querySelector(\"#p-cpu th.host\"); h.click(); h.click(); document.body.setAttribute(\"data-probe\", a + \"|\" + b + \"|\" + hs()); window.addEventListener(\"load\", function () { document.body.setAttribute(\"data-scroll\", String(window.scrollY)); });</script>"; print }' "$f" > $W/pv/probe.html
    dom=$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/pv/chrome --dump-dom "file://$W/pv/probe.html#gpu" 2> $W/pv/chrome.err)
    chk "html in Chrome: #gpu opens that panel only, no jump (scrollY 0); sort: hottest first, then reverse; host column natural (n10 n2 n1 descending)" \
        "grep -q 'data-probe=\"n10,n1,n2|n1,n2,n10|n10,n2,n1\"' <<<\"\$dom\" && [ \"\$(grep -o '<section class=\"panel\" id=\"[^\"]*\">' <<<\"\$dom\" | tr '\n' ' ')\" = '<section class=\"panel\" id=\"p-gpu\"> ' ] && grep -q 'data-scroll=\"0\"' <<<\"\$dom\"" "$(grep -o 'data-probe=\"[^\"]*\"' <<<"$dom") $(grep -o '<section class=\"panel\" id=\"[^\"]*\"[^>]*>' <<<"$dom" | tr '\n' ' ')"
else bad "html in Chrome" "Chrome not found at $CHROME: the sort/nav script is untested"; fi
finish
