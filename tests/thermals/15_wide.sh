#!/opt/homebrew/bin/bash
# a wide table (72 CPU sensors x 30 hosts) in Chrome (from test_thermals.sh, split into sections 10-26)

# checks: 4
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
if [[ -x $CHROME ]]; then
    # a wide table (72 CPU sensors x 30 hosts): its box ends inside the window, so the sideways scrollbar is on screen
    CASES=$(for x in $(seq 1 30); do printf '198.19.126.%s:manycores ' $x; done)
    out=$(run wide FF_HOSTS=198.19.126.1-30 $B $TC -o html,md); f=$(ls $W/wide/out/*.html)
    chk "md: a device with more than 4 sensors (a CPU socket) is summarised: max 74.5 of 72 sensors" "grep -qx '| n1 | max 74.5 of 72 sensors | Tctl 55.1 |' $W/wide/out/*.md" "$(grep -A5 '^## CPU' $W/wide/out/*.md)"
    awk '{ if ($0 == "</body>") print "<script>window.addEventListener(\"load\", function () { var w = document.querySelector(\"#p-cpu .wrap\"), r = w.getBoundingClientRect(); document.body.setAttribute(\"data-probe\", [window.innerHeight, w.scrollWidth, w.clientWidth, Math.round(r.bottom), w.offsetHeight - w.clientHeight].join(\" \")); });</script>"; print }' "$f" > $W/wide/probe.html
    # the device row over a wide group (coretemp.0 over 72 columns) shows its label inside the box, not off screen
    awk '{ if ($0 == "</body>") print "<script>window.addEventListener(\"load\", function () { var th = document.querySelector(\"#p-cpu th.grp\"), w = document.querySelector(\"#p-cpu .wrap\").getBoundingClientRect(), rg = document.createRange(); rg.selectNodeContents(th.firstChild); var t = rg.getBoundingClientRect(); document.body.setAttribute(\"data-probe\", [th.firstChild.textContent, th.colSpan, Math.round(t.left), Math.round(t.right), Math.round(w.left), Math.round(w.right)].join(\" \")); });</script>"; print }' "$f" > $W/wide/grp.html
    read -r gl gc tl tr bl br <<<"$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/wide/chrome --window-size=1280,800 --dump-dom "file://$W/wide/grp.html#cpu" 2> $W/wide/chrome.err | grep -o 'data-probe="[^"]*"' | cut -d'"' -f2)"
    chk "html in Chrome: a wide device group's label (coretemp.0 over 72 columns) sits inside the table box" "[ \"\$gl\" = coretemp.0 ] && [ \"\$gc\" = 72 ] && (( tl >= bl && tr <= br ))" "label=$gl colspan=$gc text=$tl..$tr box=$bl..$br"
    for sz in 1280,800 900,600; do
        pr=$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/wide/chrome --window-size=$sz --dump-dom "file://$W/wide/probe.html#cpu" 2> $W/wide/chrome.err | grep -o 'data-probe="[^"]*"' | cut -d'"' -f2)
        read -r vh sw cw bot hb <<<"$pr"
        chk "html in Chrome $sz: a 72-column table scrolls sideways in a box that ends on screen (scrollbar visible)" \
            "[[ -n \$hb ]] && (( sw > cw && bot <= vh && hb > 0 ))" "vh sw cw bottom hbar = $pr (10-26: the box ended 37 px below the window before)"
    done
else bad "html in Chrome" "Chrome not found at $CHROME: the wide table is untested"; fi
finish
