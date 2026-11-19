#!/opt/homebrew/bin/bash
# column controls (2026-11-19, the operator): a table in a tab with more than 5 columns (one header row, no spans) gets
# a Columns menu (a checkbox per column but '#'); each column is as wide as its longest value or its header on one
# line; the CSV holds the visible columns in their order. tests/cols_probe.js in headless Chrome on 14_where and
# golden-C (synthetic fixtures).
# tier: fast
# checks: 4
# secs: 45
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
mkdir -p $W/gcsrc && cp -R $S/fixtures/golden-C $W/gcsrc/dp_validation_goldenC && tar -czf $W/gc.tgz -C $W/gcsrc dp_validation_goldenC
python3 $P $S/fixtures/bundles/14_where.tgz $W/uw.html > $W/uw.pout 2>&1
python3 $P $W/gc.tgz $W/gc.html > $W/gc.pout 2>&1
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# probe <page> <probe.js> [window width]: the probe's data-probe line
probe() { { sed '/<\/body>/,$d' $1; echo '<script>'; cat $S/$2; echo '</script></body></html>'; } > $1.p.html
    "$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/chrome --window-size=${3:-1280},800 --virtual-time-budget=10000 --dump-dom "file://$1.p.html" 2> $W/chrome.err | grep -o 'data-probe="[^"]*"' | cut -d'"' -f2; }
kv() { tr ' ' '\n' <<<"$1" | awk -F= -v k=$2 '$1 == k {print $2}'; }
if [[ -x $CHROME ]]; then
    cu=$(probe $W/uw.html cols_probe.js); cg=$(probe $W/gc.html cols_probe.js)
    # control: without the tcColsAll() call and the tcCols(t) calls in tcDecorate (3 lines) no table has a menu and
    # Bootstrap's width: 100% stretches the columns past their values
    grep -vE '^ *tcColsAll\(\); |^    tcCols\(t\);$' $W/gc.html | sed 's/ tcCols(t); return; }/ return; }/' > $W/gcx.html; cx=$(probe $W/gcx.html cols_probe.js)
    chk "Columns menu in Chrome: every table of more than 5 columns (14_where 10 or more, golden-C 10 or more) has one with a checkbox per column but '#'; no table of 5 columns or fewer has one; no script error; control: without the 3 calls every such table lacks it" \
        "(( \$(kv '$cu' elig) >= 10 && \$(kv '$cg' elig) >= 10 )) && [ \$(kv '$cu' menubad) = 0 ] && [ \$(kv '$cg' menubad) = 0 ] && [ \$(kv '$cu' menusmall) = 0 ] && [ \$(kv '$cg' menusmall) = 0 ] && [ \$(kv '$cu' err) = 0 ] && [ \$(kv '$cg' err) = 0 ] && [ \$(diff $W/gc.html $W/gcx.html | grep -c '^< .*tcCols') = 3 ] && [ \$(kv '$cx' menubad) = \$(kv '$cx' elig) ]" \
        "uw '$cu' | gc '$cg' | control '$cx'"
    chk "column widths in Chrome: every visible column of those tables (100 or more on each page) is as wide as its widest cell or its header on one line, within 2 px; control: without the 3 calls 10 or more columns are wider" \
        "(( \$(kv '$cu' fitcols) >= 100 && \$(kv '$cg' fitcols) >= 100 )) && [ \$(kv '$cu' fitbad) = 0 ] && [ \$(kv '$cg' fitbad) = 0 ] && (( \$(kv '$cx' fitbad) >= 10 ))" \
        "uw '$cu' | gc '$cg' | control '$cx'"
    chk "hide a column in Chrome: the first DataTable with a menu, its first box cleared: the column's cells go (N/0/N) and come back; the CSV loses that column (8 -> 7 on both pages, its name gone); the results table's CSV drops Src IP when it is hidden (11/10/0)" \
        "[[ \"\$(kv '$cu' hide)\" =~ ^([1-9][0-9]*)/0/([0-9]+)/8/7/0\$ ]] && [ \${BASH_REMATCH[1]} = \${BASH_REMATCH[2]} ] && [[ \"\$(kv '$cg' hide)\" =~ ^([1-9][0-9]*)/0/([0-9]+)/8/7/0\$ ]] && [ \${BASH_REMATCH[1]} = \${BASH_REMATCH[2]} ] && [ \"\$(kv '$cu' rcsv)\" = 11/10/0 ] && [ \"\$(kv '$cg' rcsv)\" = 11/10/0 ] && [ \"\$(kv '$cx' hide)\" = - ]" \
        "uw '$cu' | gc '$cg' | control '$cx'"
    # narrowing: control without the line that adds the handles (1 line out) nothing is dragged
    grep -v 'tcGrip(t, th); });$' $W/uw.html > $W/uwg.html; cn=$(probe $W/uwg.html cols_probe.js)
    chk "narrow a column in Chrome: the first DataTable's widest column dragged 40 px left by its header's handle is 40 px narrower, its neighbour unchanged, the table 40 px narrower, a cell cut with its full text on hover; dragged 100 px right it is back at its first width and no wider (40/0/40/1/1/0, both pages); control: without the handles (1 line out) nothing to drag" \
        "[ \"\$(kv '$cu' narrow)\" = 40/0/40/1/1/0 ] && [ \"\$(kv '$cg' narrow)\" = 40/0/40/1/1/0 ] && [ \$(diff $W/uw.html $W/uwg.html | grep -c '^< .*tcGrip(t, th)') = 1 ] && [ \"\$(kv '$cn' narrow)\" = - ]" \
        "uw '$cu' | gc '$cg' | control '$cn'"
else for c in "Columns menu" "column widths" "hide a column" "narrow a column"; do bad "$c in Chrome" "Chrome not found at $CHROME: untested"; done; fi
finish
