// table_probe.js: appended to a dashboard page as an inline script, run in headless Chrome (--dump-dom) after the
// page's own ready handlers. Checks the table controls (issue 13) on every table in a tab (Topology aside) and writes
// body[data-probe] = space-separated key=value pairs:
//   big / bigbad     tables of more than 10 rows / those without 10 rows shown, a row-count menu of
//                    10,25,50,100,250,500,1000,All set to 10, and a filter under every header cell but '#'
//   small / smallbad DataTables of 10 rows or fewer / those with a menu, a filter or paging shown
//   search           DataTables search boxes (0: a filter per column replaces it)
//   menuhead         menus in a card header (the card holds one table) / menus in total
//   inner            boxes holding a table that scroll inside (0: the box grows to the rows)
//   eq / eqbad       rows of side-by-side cards at load / those whose cards differ in height
//   pick=<rows at 25>/<rows at All>/<total>/<own at 25>/<rows back at 10>/<own at 10>  the first big DataTable in a
//                    side-by-side row, driven through its menu (own = its column took its own height)
//   wide=<buttons>/<cards sharing a row>  widet=<width % of the row before>/<after a click>/<class back after a second click>
//   filt=<shown>/<matching>  the first value-list filter on that table set to its first value: rows shown, and rows
//                    whose cell reads that value (equal = the filter works)
window.addEventListener('load', function () { setTimeout(probe, 1500); });
function probe() {
    var r = { big: 0, bigbad: 0, small: 0, smallbad: 0, search: document.querySelectorAll('.dataTables_filter').length,
              menuhead: 0, menus: document.querySelectorAll('.tc-rows').length, inner: 0, eq: 0, eqbad: 0, pick: '-', filt: '-' };
    var want = '10,25,50,100,250,500,1000,All', panes = document.querySelectorAll('.tab-pane:not(#tab-topology)'), pickT = null;
    var show = function (p) { document.querySelectorAll('.tab-pane').forEach(function (x) { x.classList.remove('active', 'show'); }); p.classList.add('active', 'show'); };
    var txt = function (e) { return (e.textContent || '').replace(/\s+/g, ' ').trim(); };
    panes.forEach(function (p) {
        show(p);
        p.querySelectorAll('.row').forEach(function (row) {
            var cards = [].filter.call(row.children, function (c) { return /\bcol/.test(c.className) && c.querySelector(':scope > .card table'); })
                          .map(function (c) { return Math.round(c.querySelector(':scope > .card').getBoundingClientRect().height); });
            if (cards.length < 2) return; r.eq++; if (Math.max.apply(null, cards) - Math.min.apply(null, cards) > 1) r.eqbad++;
        });
        p.querySelectorAll('table.table').forEach(function (t) {
            if (!t.tHead || !t.tBodies.length) return;
            var box = t.closest('.scroll'); if (box && box.scrollHeight - box.clientHeight > 1) r.inner++;
            var dt = $.fn.DataTable.isDataTable(t) ? $(t).DataTable() : null;
            var total = dt ? dt.rows().count() : (t.id === 'resultsTable' ? +((document.getElementById('resultsPager').textContent.match(/(\d+) rows/) || [0, 0])[1]) : t.tBodies[0].rows.length);
            var menu = t.id && document.getElementById('tcm-' + t.id), sel = menu && menu.querySelector('select');
            var ths = [].slice.call(t.tHead.rows[0].cells), filters = t.querySelectorAll('thead .col-filter').length;
            var needF = ths.filter(function (h) { return txt(h) !== '#'; }).length;   // the '#' cell has no filter
            if (menu && menu.closest('.card-header')) r.menuhead++;
            if (total > 10 && (dt || t.id === 'resultsTable')) {
                r.big++;
                var opts = sel ? [].map.call(sel.options, function (o) { return o.textContent; }).join(',') : '';
                if (t.tBodies[0].rows.length !== 10 || opts !== want || sel.value !== '10' || filters !== needF) r.bigbad++;
                var col = t.closest('.card') && t.closest('.card').parentElement;
                if (dt && sel && !pickT && col && col.parentElement.classList.contains("row")) pickT = [p, t, dt, sel, col, total];
            } else if (dt) {
                r.small++;
                var pg = t.closest('.dataTables_wrapper').querySelector('.dataTables_paginate');
                if (menu || filters || (pg && pg.offsetParent)) r.smallbad++;
            }
        });
    });
    if (pickT) {
        var p = pickT[0], t = pickT[1], dt = pickT[2], sel = pickT[3], col = pickT[4], set = function (v) { sel.value = v; sel.dispatchEvent(new Event('change')); return t.tBodies[0].rows.length; };
        show(p);
        var a = set('25'), own25 = col.classList.contains('tc-own'), b = set('-1'), c = set('10'), own10 = col.classList.contains('tc-own');
        r.pick = [a, b, pickT[5], own25 ? 1 : 0, c, own10 ? 1 : 0].join('/');
        var f = t.querySelector('thead .col-filter select');
        if (f) {
            var ci = [].indexOf.call(t.tHead.rows[0].cells, f.closest('th')), v = f.options[1].value;
            set('-1'); f.value = v; f.dispatchEvent(new Event('change'));
            var rows = [].slice.call(t.tBodies[0].rows), m = rows.filter(function (row) { return txt(row.cells[ci]) === v; }).length;
            r.filt = rows.length + '/' + m;
            f.value = ''; f.dispatchEvent(new Event('change')); set('10');
        }
    }
    // the full-width button: one per card that shares its row; the first one widens its column to the row and back
    var hds = document.querySelectorAll('.tab-pane .row > [class*="col"]:not(.col-12) > .card > .card-header');
    r.wide = document.querySelectorAll('.tc-wide').length + '/' + hds.length; r.widet = '-';
    var wb = document.querySelector('.tc-wide');
    if (wb) {
        var wc = wb.closest('.card').parentElement, cls = wc.className; show(wc.closest('.tab-pane'));
        var rw = wc.parentElement.getBoundingClientRect().width, w0 = wc.getBoundingClientRect().width;
        wb.click(); var w1 = wc.getBoundingClientRect().width; wb.click();
        r.widet = Math.round(100 * w0 / rw) + '/' + Math.round(100 * w1 / rw) + '/' + (wc.className === cls ? 1 : 0);
    }
    document.body.setAttribute('data-probe', Object.keys(r).map(function (k) { return k + '=' + r[k]; }).join(' '));
}
