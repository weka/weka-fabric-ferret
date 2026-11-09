#!/opt/homebrew/bin/bash
# scope 5 (the operator 11-09): a tab's cards fill the window and tables scroll inside their cards. No layout engine
# here, so the page's strings are pinned on 14_ub and golden-C: no inline max-height on a card body, the scroll class
# on every tab card body that holds a table or a list (the banner above the tabs and the map body stay as they are),
# the LLDP card alone in a col-12 row with its text cells nowrap, and one tab-fitting resize handler (fitTabs). The
# interface (class "scroll", fitTabs) was agreed with the coder
# tier: fast
# checks: 5
# secs: 6
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
finish
