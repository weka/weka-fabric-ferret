#!/opt/homebrew/bin/bash
# scope 5 (the operator 11-09): a tab's cards fill the window and tables scroll inside their cards. No layout engine
# here, so the page's strings are pinned on 14_ub and golden-C: no inline max-height on a card body, the scroll class
# on every tab card body that holds a table or a list (the banner above the tabs and the map body stay as they are),
# the LLDP card alone in a col-12 row with its text cells nowrap, and one tab-fitting resize handler (fitTabs). The
# interface (class "scroll", fitTabs) was agreed with the coder. Since issue 13 (the operator 11-19) a box that holds a
# table grows to the table's rows (10 a page at first) and the page scrolls; a box with only a list still scrolls inside
# tier: fast
# checks: 9
# secs: 30
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
mkdir -p $W/gcsrc && cp -R $S/fixtures/golden-C $W/gcsrc/dp_validation_goldenC && tar -czf $W/gc.tgz -C $W/gcsrc dp_validation_goldenC
python3 $P $S/fixtures/bundles/14_ub.tgz $W/ub.html > $W/ub.pout 2>&1; echo "rc=$?" >> $W/ub.pout
python3 $P $W/gc.tgz $W/gc.html > $W/gc.pout 2>&1; echo "rc=$?" >> $W/gc.pout
# bodies <page> <what>: card bodies inside .tab-content and outside the Topology pane (the banner above the tabs and
# the map's overlay body are out of scope 5): all, tbl (holding a table or list before the next card body), scroll
# (carrying the scroll class), both (holding a table or list and carrying the class)
bodies() { awk -v w=$2 '
    /class="nav nav-tabs/ { inp = 1 } /class="tab-pane/ { topo = /id="tab-topology"/ }
    inp && !topo && /<div class="card-body/ { flush(); open = 1; n++; has = 0; sc = /class="card-body[^"]* scroll[ "]/ }
    open && /<table|<ul|<ol/ { has = 1 }
    END { flush(); print (w == "all" ? n : w == "tbl" ? t : w == "scroll" ? s : b) + 0 }
    function flush() { if (!open) return; t += has; s += sc; b += (has && sc) }' $W/$1.html; }
chk "scope 5: 0 inline max-height on a card body on 14_ub and golden-C (was 6 each; control: a planted one counts 1); the page still renders (rc 3 = the fixtures' coverage) with 23 card bodies in the tabs (Topology aside)" \
    "[ \$(grep -c 'card-body[^>]*max-height:' $W/ub.html) = 0 ] && [ \$(grep -c 'card-body[^>]*max-height:' $W/gc.html) = 0 ] && [ \$({ cat $W/ub.html; echo '<div class=\"card-body\" style=\"max-height:420px; overflow-y:auto;\">'; } | grep -c 'card-body[^>]*max-height:') = 1 ] && [ \$(bodies ub all) = 23 ] && [ \$(bodies gc all) = 23 ]" \
    "max-height on card bodies: ub $(grep -c 'card-body[^>]*max-height:' $W/ub.html) gc $(grep -c 'card-body[^>]*max-height:' $W/gc.html); bodies ub $(bodies ub all) gc $(bodies gc all) $(tail -n 1 $W/ub.pout) $(tail -n 1 $W/gc.pout)"
chk "scope 5: the scroll class on every card body that holds a table or a list: 14_ub 15 of 23 bodies, golden-C 16 of 23 (counted in the tabs, Topology aside: a table, ul or ol before the next card body), each carrying class 'card-body scroll'; the class's rule once in the stylesheet with flex:1, overflow-y:auto, min-height:260px and contain:size (without contain the box grows with its rows and nothing scrolls: ab7c12a measured in Chrome, 11-09)" \
    "[ \$(bodies ub tbl) = 15 ] && [ \$(bodies ub both) = 15 ] && [ \$(bodies gc tbl) = 16 ] && [ \$(bodies gc both) = 16 ] && [ \$(grep -c '\\.scroll *{[^}]*flex: *1[^}]*overflow-y: *auto[^}]*min-height: *260px[^}]*contain: *size' $W/ub.html) = 1 ]" \
    "ub tbl/scroll/both $(bodies ub tbl)/$(bodies ub scroll)/$(bodies ub both) gc $(bodies gc tbl)/$(bodies gc scroll)/$(bodies gc both); rule: $(grep -o '\.scroll *{[^}]*}' $W/ub.html | head -n 1)"
chk "scope 5: the scroll class on no card body without a table or list (the Plotly charts, the map, the consistency panel keep their own size): bodies carrying the class = bodies holding a table or list, on both pages" \
    "[ \$(bodies ub scroll) = \$(bodies ub tbl) ] && [ \$(bodies gc scroll) = \$(bodies gc tbl) ]" \
    "ub scroll $(bodies ub scroll) tbl $(bodies ub tbl); gc scroll $(bodies gc scroll) tbl $(bodies gc tbl)"
# the LLDP card: the col that holds id="lldpTable" is a col-12 (its own row), its Port Description and Sys Descr cells nowrap with the text in title
lldpcol() { awk '/<div class="col-/ { c = $0; sub(/.*<div class="/, "", c); sub(/".*/, "", c) } /id="lldpTable"/ { print c; exit }' $W/$1.html; }
chk "scope 5: the LLDP Neighbor Table sits in a col-12 of its own on 14_ub and golden-C (was col-md-6); every row's Port Description and LLDP Sys cells are nowrap/ellipsis with the full text in title (14_ub: 4 rows, 8 nowrap cells; golden-C 9 rows, 18)" \
    "[ \"\$(lldpcol ub)\" = col-12 ] && [ \"\$(lldpcol gc)\" = col-12 ] && [ \$(awk '/id=\"lldpTable\"/,/<\\/table>/' $W/ub.html | grep -o '<td[^>]*white-space: *nowrap[^>]*title=\"[^\"]*\"[^>]*>' | wc -l) = 8 ] && [ \$(awk '/id=\"lldpTable\"/,/<\\/table>/' $W/gc.html | grep -o '<td[^>]*white-space: *nowrap[^>]*title=\"[^\"]*\"[^>]*>' | wc -l) = 18 ]" \
    "col: ub $(lldpcol ub) gc $(lldpcol gc); nowrap cells ub $(awk '/id="lldpTable"/,/<\/table>/' $W/ub.html | grep -o '<td[^>]*white-space: *nowrap[^>]*>' | wc -l) gc $(awk '/id="lldpTable"/,/<\/table>/' $W/gc.html | grep -o '<td[^>]*white-space: *nowrap[^>]*>' | wc -l)"
chk "scope 5: the tab-fitting handler: fitTabs defined once, bound to the window's resize once and called at load; the tab-content is a flex column (control: a planted second definition counts 2)" \
    "[ \$(grep -c 'function fitTabs *(' $W/ub.html) = 1 ] && [ \$(grep -c \"on('resize', *fitTabs)\\|addEventListener('resize', *fitTabs)\" $W/ub.html) = 1 ] && [ \$(grep -c 'fitTabs()' $W/ub.html) -ge 1 ] && grep -qE '\\.tab-content *\\{[^}]*display: *flex[^}]*flex-direction: *column' $W/ub.html && [ \$({ cat $W/ub.html; echo 'function fitTabs() {}'; } | grep -c 'function fitTabs *(') = 2 ]" \
    "fitTabs defs $(grep -c 'function fitTabs *(' $W/ub.html) resize binds $(grep -c "on('resize', *fitTabs)\|addEventListener('resize', *fitTabs)" $W/ub.html) calls $(grep -c 'fitTabs()' $W/ub.html); tab-content rule: $(grep -o '\.tab-content *{[^}]*}' $W/ub.html | head -n 1)"
# sticky headers (issues 12 and 13, 2026-11-19): a table's box grows to its rows, so the page scrolls; in headless
# Chrome each table of 3 or more rows is scrolled 40 px past the window's top and every cell of its header row must
# stay at the window's top (tests/sticky_probe.js). Controls: without the rule that lets a table's box grow (1 line
# out) the boxes scroll inside again and the header leaves the window's top; without !important on the sticky position
# (DataTables sets its sortable headers position: relative) a sortable header scrolls away.
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
probe() { { sed '/<\/body>/,$d' $1; echo '<script>'; cat $S/$2; echo '</script></body></html>'; } > $1.p.html
    "$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir=$W/chrome --window-size=1280,800 --virtual-time-budget=10000 --dump-dom "file://$1.p.html" 2> $W/chrome.err | grep -o 'data-probe="[^"]*"' | cut -d'"' -f2; }
if [[ -x $CHROME ]]; then
    pg=$(probe $W/gc.html sticky_probe.js)
    grep -v '^\.scroll:has(table) {' $W/gc.html > $W/gcx.html; px=$(probe $W/gcx.html sticky_probe.js)
    chk "sticky headers in Chrome: golden-C, every table of 3 or more rows (7 or more) scrolled past the window's top keeps every header cell at the window's top (gap 0); control: without the box-grows rule (1 line out) a header leaves the top (gap below 0)" \
        "[[ '$pg' =~ ^boxes=([0-9]+)\ maxgap=0\ mingap=0\$ ]] && (( \${BASH_REMATCH[1]} >= 7 )) && [ \$(diff $W/gc.html $W/gcx.html | grep -cE '^[0-9]+d[0-9]+$') = 1 ] && [[ '$px' =~ mingap=-[0-9]+\$ ]]" "fixed '$pg' | control '$px'"
    sed 's/position: sticky !important; top: 0;/position: sticky; top: 0;/' $W/gc.html > $W/gcy.html; py=$(probe $W/gcy.html sticky_probe.js)
    chk "sticky headers in Chrome: DataTables' sortable header cells too; control: without !important (1 line changed) a sortable header scrolls away (gap below 0)" \
        "[[ '$pg' =~ maxgap=0\ mingap=0\$ ]] && [ \$(diff $W/gc.html $W/gcy.html | grep -c '^>') = 1 ] && [[ '$py' =~ mingap=-[0-9]+\$ ]]" "fixed '$pg' | control '$py'"
    # table controls (issue 13, the operator 11-19): tests/table_probe.js on 14_where (15 NICs: its driver, LLDP and
    # optics tables have more than 10 rows, side by side) and golden-C (two plain tables of 76 and 14 rows, the results
    # table of 76 runs). Control: without the two dtOpts lines (dom, initComplete) DataTables' own search box and length
    # menu come back and the menus and filters go
    python3 $P $S/fixtures/bundles/14_where.tgz $W/uw.html > $W/uw.pout 2>&1
    tu=$(probe $W/uw.html table_probe.js); tg=$(probe $W/gc.html table_probe.js)
    grep -vE "^ +dom: 'rt<\"dt-foot\"ip>',|^ +initComplete: function\(\) \{ tcDecorate\(this.api\(\)\); \}," $W/uw.html > $W/uwx.html; tx=$(probe $W/uwx.html table_probe.js)
    kv() { tr ' ' '\n' <<<"$1" | awk -F= -v k=$2 '$1 == k {print $2}'; }
    chk "table controls in Chrome (14_where): 5 or more tables of more than 10 rows each show 10 rows, a menu 10,25,50,100,250,500,1000,All set to 10 in its card header and a filter under every header cell but '#'; the small DataTables show no menu, filter or paging; 0 search boxes; 0 boxes scrolling inside" \
        "(( \$(kv '$tu' big) >= 5 )) && [ \$(kv '$tu' bigbad) = 0 ] && (( \$(kv '$tu' small) >= 1 )) && [ \$(kv '$tu' smallbad) = 0 ] && [ \$(kv '$tu' search) = 0 ] && [ \$(kv '$tu' menuhead) = \$(kv '$tu' menus) ] && [ \$(kv '$tu' inner) = 0 ]" "uw '$tu'"
    chk "table controls in Chrome: side-by-side cards share one height at load (14_where); its first big side-by-side table at 25 shows min(25, 15) = 15 rows and takes its own height, All shows 15, back at 10 it shows 10 and shares the row's height again; its first value-list filter keeps only rows with that value; golden-C's big tables (2 or more) pass too; control: without the dtOpts lines a search box is back and the big tables fail" \
        "(( \$(kv '$tu' eq) >= 1 )) && [ \$(kv '$tu' eqbad) = 0 ] && [ \"\$(kv '$tu' pick)\" = 15/15/15/1/10/0 ] && [[ \"\$(kv '$tu' filt)\" =~ ^([1-9][0-9]*)/([0-9]+)\$ ]] && [ \${BASH_REMATCH[1]} = \${BASH_REMATCH[2]} ] && (( \$(kv '$tg' big) >= 2 )) && [ \$(kv '$tg' bigbad) = 0 ] && [ \$(diff $W/uw.html $W/uwx.html | grep -cE '^< +(dom|initComplete):') = 2 ] && (( \$(kv '$tx' search) > 0 && \$(kv '$tx' bigbad) > 0 ))" "uw '$tu' | gc '$tg' | control '$tx'"
else for c in "sticky headers" "sticky headers (DataTables)" "table controls" "table controls (sizes)"; do bad "$c in Chrome" "Chrome not found at $CHROME: untested"; done; fi
finish
