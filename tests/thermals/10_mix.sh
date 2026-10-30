#!/opt/homebrew/bin/bash
# chip mixes, and one snapshot over every case but the hang (11) (from test_thermals.sh, split into sections 10-26)

# checks: 20
# secs: 15
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
CASES="198.19.109.1:amd 198.19.109.2:nolabel"
out=$(run mixes FF_IPMI=0 FF_HOSTS=198.19.109.1,198.19.109.2 $B $TC); rc=$?
chk "chip mixes end to end: types cpu nvme nic (bnxt) other (acpitz), -5.0 kept, rc 0 COMPLETE" \
    "[ $rc = 0 ] && [ \"\$(jl mixes | jq -r 'select(.type == \"sensor\") | \"\\(.host):\\(.kind):\\(.sensor):\\(.max_c)\"' | tr '\n' ' ')\" = 'n1:cpu:Tctl:65.0 n1:cpu:Tccd1:60.5 n1:nvme:Composite:40.9 n1:nvme:Composite:41.9 n1:nic:temp1:70.0 n2:other:temp1:45.0 n2:other:temp2:-5.0 ' ]" "rc=$rc $(jl mixes | jq -c 'select(.type == "sensor") | [.host, .kind, .chip, .dev, .sensor, .max_c]')"
# --- one snapshot over every case ---
# the hung host (198.19.100.9) has its own section (11_hang, the pre-push long pole): its cut-off costs ~32 s
CASES="198.19.100.1:all 198.19.100.2:nochips 198.19.100.3:nohwmon 198.19.100.4:noipmi 198.19.100.5:ipmislow 198.19.100.6:sudo 198.19.100.7:sudook 198.19.100.8:down"
out=$(run mix FF_IPMI_TIMEOUT=2 FF_HOSTS=$(seq -s, -f '198.19.100.%g' 1 8) $B $TC -o jsonl,html,md); rc=$?
chk "mix: rc 3, RESULT PARTIAL hosts=5/7 (n1 n4 n5 n6 n7 gave readings; .8 unreachable, left out)" "[ $rc = 3 ] && grep -qx 'RESULT data=PARTIAL hosts=5/7 sensors=[0-9]* flagged=[0-9]* nodata=[0-9]* unreachable=1' <<<\"\$out\"" "rc=$rc $(tail -n 3 <<<"$out")"
chk "mix: the unreachable 198.19.100.8 (listed by itself) appears nowhere without -v: stderr, jsonl, md (the html lists it under Not read)" "! grep -q '198\\.19\\.100\\.8\\b' <<<\"\$out\" && ! cat $W/mix/out/*.jsonl $W/mix/out/*.md | grep -q '198\\.19\\.100\\.8\\b'" "$(grep -n '198\.19\.100\.8' <<<"$out"; grep -l '198\.19\.100\.8' $W/mix/out/*)"
nd=$(jl mix | jq -r 'select(.type == "nodata") | "\(.host) \(.source) \(.why)"' | sort)
exp_nd="n2 hwmon no_hwmon_temperature_sensors
n2 ipmi ipmitool_not_installed
n3 hwmon no_hwmon_temperature_sensors
n3 ipmi rc=1_Could_not_open_device_at__dev_ipmi0_or__dev_ipmi_0_or__dev_ipmidev_0:_No_such_fi
n4 ipmi ipmitool_not_installed
n5 ipmi ipmitool_timed_out_after_2s
n6 ipmi no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo"
chk "mix: every no-data host and source, with its reason (no hwmon, no ipmitool, timeout, sudo)" "[ \"\$nd\" = \"\$exp_nd\" ]" "$(diff <(echo "$exp_nd") <(echo "$nd"))"
chk "mix: sudo refused still gives hwmon (n6 has 6 hwmon sensors); sudo -n allowed gives the BMC (n7 ipmi 2)" \
    "[ \"\$(jl mix | jq -r 'select(.type == \"sensor\" and ((.host == \"n6\" and .source == \"hwmon\") or (.host == \"n7\" and .source == \"ipmi\"))) | .host' | sort | uniq -c | awk '{print \$1 \$2}' | tr '\n' ' ')\" = '6n6 2n7 ' ]" "$(jl mix | jq -c 'select(.type == "sensor" and (.host == "n6" or .host == "n7")) | [.host, .source, .sensor]')"
chk "mix: the line before RESULT counts unreachable 1 (.8), unavailable 2 (n2 n3)" "[ \"\$(tail -n 2 <<<\"\$out\" | head -n 1)\" = 'Unreachable: 1 (no ssh connection; -v lists them), unavailable: 2 (connected, no readings)' ]" "$(tail -n 3 <<<"$out")"
chk "mix: stderr lists the no-data lines collapsed by source and reason: 5 for the 7 jsonl nodata records above (n2 n3 share no_hwmon, n2 n4 share ipmitool_not_installed)" "[ \$(grep -c '^  NO TEMPERATURE DATA: ' <<<\"\$out\") = 5 ]" "$(grep 'NO TEMP' <<<"$out")"
chk "mix: a shared reason is one counted line naming its hosts; a reason one host has keeps the host-first line" "grep -qx '  NO TEMPERATURE DATA: hwmon (no_hwmon_temperature_sensors): 2 hosts: n2 n3' <<<\"\$out\" && grep -qx '  NO TEMPERATURE DATA: ipmi (ipmitool_not_installed): 2 hosts: n2 n4' <<<\"\$out\" && grep -qx '  NO TEMPERATURE DATA: n5 ipmi (ipmitool_timed_out_after_2s)' <<<\"\$out\"" "$(grep 'NO TEMP' <<<"$out")"
chk "mix: jsonl: every line is JSON; types run, host x7, sample, reading, sensor, nodata, result in that order" \
    "jl mix | jq -e . > $W/mix.jq 2>&1 && [ \"\$(jl mix | jq -r .type | uniq | tr '\n' ' ')\" = 'run host sample reading sensor nodata result ' ] && [ \$(jl mix | jq -r 'select(.type == \"host\")' | jq -s length) = 7 ]" "$(jl mix | jq -r .type | uniq -c | tr '\n' ' ')"
chk "mix: host records map targets to hostnames (198.19.100.1 -> n1; the hung host keeping its target is in 11_hang)" \
    "[ \"\$(jl mix | jq -r 'select(.type == \"host\" and .target == \"198.19.100.1\") | .host' | tr '\n' ' ')\" = 'n1 ' ]"
chk "mix: result record matches the RESULT line" "[ \"\$(jl mix | jq -r 'select(.type == \"result\") | \"data=\\(.data) hosts=\\(.hosts_with_data)/\\(.targets) sensors=\\(.sensors) flagged=\\(.flagged) nodata=\\(.nodata) unreachable=\\(.unreachable)\"')\" = \"\$(grep '^RESULT' <<<\"\$out\" | cut -d' ' -f2-)\" ]" "$(jl mix | tail -n 1) | $(grep '^RESULT' <<<"$out")"
h=$(cat $W/mix/out/*.html 2>&1)
chk "mix: html: self-contained (one inline script, no src/href to anywhere but its own #panels), PARTIAL shown" \
    "[ \$(grep -c '<script>' <<<\"\$h\") = 1 ] && ! grep -qiE '<script [^>]*src|<link |(src|href)=\"?(https?:|//)' <<<\"\$h\" && [ -z \"\$(grep -oE 'href=\"[^\"#][^\"]*\"' <<<\"\$h\")\" ] && grep -q 'res PARTIAL' <<<\"\$h\" && grep -q 'prefers-color-scheme: dark' <<<\"\$h\""
nrp=$(sed -n '/id="p-notread"/,/<\/section>/p' <<<"$h")
chk "html Not read (10-26: no-data and unreachable behind a link at the foot of the nav): button with count 8, panel lists 7 no-data and the 1 unreachable with ssh's reason" \
    "grep -q '<div id=\"nav-footer\"><button type=\"button\" data-panel=\"notread\" aria-selected=\"false\" class=\"warn\"><span>Not read</span><span class=\"count\">8</span></button></div>' <<<\"\$h\" && grep -q '<h3>No temperature data (7)</h3>' <<<\"\$nrp\" && grep -q '<h3>Unreachable (1)</h3>' <<<\"\$nrp\" && [ \$(grep -o '<tr><td class=\"host\">' <<<\"\$nrp\" | wc -l) = 8 ] && grep -q '<tr><td class=\"host\">198.19.100.8</td><td>ssh_failed_ssh:_connect_to_host_198.19.100.8_port_22:_Connection_timed_out</td></tr>' <<<\"\$nrp\" && ! sed -n '/id=\"p-overview\"/,/<\\/section>/p' <<<\"\$h\" | grep -q 'class=\"card nodata\"'" "$(grep -o '<div id=\"nav-footer\">.*</div>' <<<"$h") | $(grep -o '<h3>[^<]*</h3>' <<<"$nrp")"
chk "mix: html overview: n1 Exhaust (BMC nc) in Flagged sensors, row marked high" "grep -qE '<tr class=\"high\"><td>n1</td><td>ipmi</td>.*Exhaust_Temp' <<<\"\$h\""
chk "html alignment (10-26): number headers right-aligned like their cells, numbers one decimal" \
    "grep -q '<th data-col=\"5\">Sensor</th><th data-col=\"6\" class=\"n\">Temp</th><th data-col=\"7\" class=\"n\">High</th><th data-col=\"8\" class=\"n\">Crit</th><th data-col=\"9\">Flag</th>' <<<\"\$h\" && grep -q '<th class=\"n\" data-col=\"1\">Inlet</th>' <<<\"\$h\" && grep -q 'th.n, td.n { text-align: right; }' <<<\"\$h\" && grep -q 'Exhaust_Temp</td><td class=\"n\" data-v=\"52.0\">52.0</td><td class=\"n\" data-v=\"50.0\">50.0</td><td class=\"n\" data-v=\"55.0\">55.0</td>' <<<\"\$h\"" "$(grep -o '<tr><th>Host</th><th>Source.*</tr>' <<<"$h" | head -n 1)"
chk "html nav (10-26: by type only): Overview, the types in fixed order with counts, Not read last" \
    "[ \"\$(grep -o '<button type=\"button\" data-panel=\"[^\"]*\"' <<<\"\$h\" | cut -d'\"' -f4 | tr '\n' ' ')\" = 'overview inlet cpu nvme nic other notread ' ] && [ \"\$(grep -o '<div class=\"navgroup\">[^<]*' <<<\"\$h\" | cut -d'>' -f2 | tr '\n' '|')\" = 'By type|' ]"
chk "html type pages: an OS table then a BMC / IPMI table, only where that source has readings (mix: inlet BMC only, cpu OS only)" \
    "[ \"\$(sed -n '/<section class=\"panel\" id=\"p-inlet\">/,/<\\/section>/p' <<<\"\$h\" | grep -o '<h3>[^<]*' | tr '\n' '|')\" = '<h3>BMC / IPMI |' ] && [ \"\$(sed -n '/<section class=\"panel\" id=\"p-cpu\">/,/<\\/section>/p' <<<\"\$h\" | grep -o '<h3>[^<]*' | tr '\n' '|')\" = '<h3>OS (hwmon, nvidia-smi) |' ]" "$(grep -o '<section class=\"panel\" id=\"[^\"]*\"><h2>[^<]*</h2>\|<h3>[^<]*' <<<"$h" | tr '\n' ' ') $(grep -o 'data-panel=\"[^\"]*\"[^>]*><span>[^<]*</span><span class=\"count\">[0-9]*' <<<"$h")"
m=$(cat $W/mix/out/*.md 2>&1)
chk "mix: md: PARTIAL, 7 no-data bullets, n1 Exhaust (type other) flagged high, one reading: 10 columns (Temp, no First/Min/Max/Last)" \
    "grep -q '^\\*\\*PARTIAL\\*\\* · 5 of 7 hosts' <<<\"\$m\" && [ \$(grep -c '^- \\*\\*' <<<\"\$m\") = 7 ] && grep -q '^| n1 | ipmi | other | bmc | - | Exhaust_Temp | 52.0 | 50.0 | 55.0 | \\*\\*high\\*\\* |\$' <<<\"\$m\" && [ \$(grep '^| Host | Source' <<<\"\$m\" | head -n 1 | awk -F'|' '{print NF - 2}') = 10 ]" "$(head -n 30 <<<"$m")"
chk "mix: the files share one name, thermcap_<UTC>.{jsonl,html,md} (no label: 10-26), plus .ssh_errors.log (the unreachable .8)" "[ \"\$(ls $W/mix/out | sed -E 's/^thermcap_20[0-9]{6}T[0-9]{6}Z\\.//' | sort | tr '\n' ' ')\" = 'html jsonl md ssh_errors.log ' ]" "$(ls $W/mix/out)"
if [[ -x $CHROME ]]; then
    # Not read at the foot of the nav: on screen at load, and a click opens its panel (and only it)
    f=$(ls $W/mix/out/*.html); awk '{ if ($0 == "</body>") print "<script>window.addEventListener(\"load\", function () { var b = document.querySelector(\"#nav-footer button\"), r = b.getBoundingClientRect(); b.click(); var v = Array.prototype.filter.call(document.querySelectorAll(\"section.panel\"), function (s) { return !s.hidden; }).map(function (s) { return s.id; }); document.body.setAttribute(\"data-probe\", window.innerHeight + \" \" + Math.round(r.bottom) + \" \" + v.join(\",\")); });</script>"; print }' "$f" > $W/mix/probe.html
    read -r vh bb vis <<<"$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/mix/chrome --window-size=1100,700 --dump-dom "file://$W/mix/probe.html" 2> $W/mix/chrome.err | grep -o 'data-probe="[^"]*"' | cut -d'"' -f2)"
    chk "html in Chrome: the Not read button sits on screen at the foot of the nav, and a click shows its panel only" "[[ -n \$vis ]] && (( bb <= vh && bb > vh - 80 )) && [ \"\$vis\" = p-notread ]" "vh=$vh button_bottom=$bb visible=$vis"
else bad "html in Chrome" "Chrome not found at $CHROME: the Not read button is untested"; fi
finish
