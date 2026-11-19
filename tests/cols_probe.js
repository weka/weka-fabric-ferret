// cols_probe.js: appended to a dashboard page as an inline script, run in headless Chrome (--dump-dom) after the
// page's own ready handlers. Checks the column controls (2026-11-19) on every table in a tab (Topology aside) and
// writes body[data-probe] = space-separated key=value pairs:
//   err              script errors on the page (0)
//   elig / menubad   tables of more than 5 columns (one header row, no spans) / those without a Columns menu that has
//                    one checkbox per column but '#'
//   menusmall        tables of 5 columns or fewer that have a Columns menu (0)
//   fitcols / fitbad visible columns measured / those whose width is not the widest of its cells' contents (the header
//                    on one line, the filter box left out) within 2 px; fitfirst names the first bad one
//   hide=<cells shown in the column>/<after its box is cleared>/<after it is set again>/<CSV columns>/<CSV columns
//        with it hidden>/<its name in that CSV 0|1>  on the first DataTable with a menu
//   rcsv=<CSV columns>/<with Src IP hidden>/<Src IP in it 0|1>  the results table (resultsCsvText)
//   narrow=<px narrower>/<neighbour's change>/<table's px narrower>/<a cell cut 0|1>/<its full text on hover 0|1>/<px past
//        its first width after a 100 px drag wider>  its widest column dragged 40 px narrower by the header's handle
//   need=<tables wider than their box>/<those with the slider shown>/<the rest>/<those with it hidden>
//   scr=<'#' header px moved>/<'#' cell px moved>/<last header px moved>/<'#' cell on top 0|1>/<slider after a 30 px
//        sideways wheel>  the first wide table with '#', its slider set to 60 px
var tcpErr = 0; window.addEventListener('error', function () { tcpErr++; });
window.addEventListener('load', function () { setTimeout(tcpProbe, 1500); });
function tcpProbe() {
    var r = { err: 0, elig: 0, menubad: 0, menusmall: 0, fitcols: 0, fitbad: 0, fitfirst: '-', hide: '-', rcsv: '-', narrow: '-' };
    var show = function (p) { document.querySelectorAll('.tab-pane').forEach(function (x) { x.classList.remove('active', 'show'); }); p.classList.add('active', 'show'); };
    var lab = function (c) { var x = c.cloneNode(true); x.querySelectorAll('small, .col-filter, .tc-grip').forEach(function (e) { e.remove(); }); return (x.textContent || '').replace(/\s+/g, ' ').trim(); };
    var vis = function (c) { return getComputedStyle(c).display !== 'none'; };
    var need = function (c) {   // the width the cell's contents take on one line, with its padding and borders
        var g = document.createRange(); g.selectNodeContents(c); var s = getComputedStyle(c), w = g.getBoundingClientRect().width;
        return w + parseFloat(s.paddingLeft) + parseFloat(s.paddingRight) + parseFloat(s.borderLeftWidth) + parseFloat(s.borderRightWidth);
    };
    var hideF = document.createElement('style'); hideF.textContent = '.col-filter, .tc-grip { display: none !important; }';
    var firstDT = null;
    document.querySelectorAll('.tab-pane:not(#tab-topology)').forEach(function (p) {
        show(p);
        p.querySelectorAll('table.table').forEach(function (t) {
            if (!t.tHead || t.tHead.rows.length !== 1 || !t.tBodies.length) return;
            var hr = t.tHead.rows[0], n = hr.cells.length, menu = t.id && document.getElementById('tcc-' + t.id);
            if ([].some.call(t.querySelectorAll('[colspan], [rowspan]'), function (c) { return !c.classList.contains('dataTables_empty') && (c.colSpan > 1 || c.rowSpan > 1); })) return;
            if (n < 6) { if (menu) r.menusmall++; return; }
            r.elig++;
            var boxes = menu ? menu.querySelectorAll('input[type=checkbox]').length : -1, hash = lab(hr.cells[0]) === '#';
            if (boxes !== n - (hash ? 1 : 0)) r.menubad++;
            if (menu && !firstDT && $.fn.DataTable.isDataTable(t)) firstDT = t;
            document.head.appendChild(hideF);
            var rows = [].filter.call(t.tBodies[0].rows, function (x) { return x.cells.length === n; });
            [].forEach.call(hr.cells, function (th, k) {
                if (!vis(th)) return;
                var m = need(th); rows.forEach(function (x) { m = Math.max(m, need(x.cells[k])); });
                var w = th.getBoundingClientRect().width; r.fitcols++;
                if (Math.abs(w - m) > 2) { r.fitbad++; if (r.fitfirst === '-') r.fitfirst = (t.id || '?') + ':' + lab(th).replace(/\W+/g, '_') + ':' + Math.round(w) + 'vs' + Math.round(m); }
            });
            hideF.remove();
        });
    });
    var csvCols = function (s) { return s.split('\n')[0].split(',').length; };
    if (firstDT) {
        var t = firstDT, menu = document.getElementById('tcc-' + t.id), cb = menu.querySelector('input[type=checkbox]'), i = +cb.getAttribute('data-i');
        show(t.closest('.tab-pane'));
        var name = lab(t.tHead.rows[0].cells[i]), cells = function () { return [].filter.call(t.querySelectorAll('.tcc' + i), vis).length; };
        var c0 = cells(), v0 = csvCols(window.tableCsvText(t.id));
        cb.checked = false; cb.dispatchEvent(new Event('change'));
        var c1 = cells(), csv1 = window.tableCsvText(t.id), v1 = csvCols(csv1), has = csv1.split('\n')[0].split(',').indexOf(name) >= 0 ? 1 : 0;
        cb.checked = true; cb.dispatchEvent(new Event('change'));
        r.hide = [c0, c1, cells(), v0, v1, has].join('/');
    }
    // narrowing: on that table its widest column but '#' is dragged 40 px narrower by the handle on its header's right
    // border, then 100 px wider
    if (firstDT) {
        var t = firstDT, hr = t.tHead.rows[0], ths = [].filter.call(hr.cells, vis), best = null;
        show(t.closest('.tab-pane'));
        ths.forEach(function (th, k) { if (k < ths.length - 1 && th.querySelector('.tc-grip') && (!best || th.offsetWidth > best.offsetWidth)) best = th; });
        if (best) {
            var nb = ths[ths.indexOf(best) + 1], W = function (e) { return e.getBoundingClientRect().width; }, g = best.querySelector('.tc-grip');
            var drag = function (dx) { var x = g.getBoundingClientRect().right - 2, y = g.getBoundingClientRect().top + 2;
                g.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }));
                document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: x + dx, clientY: y }));
                document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: x + dx, clientY: y })); };
            var nat = W(best), n0 = W(nb), t0 = W(t);
            drag(-40);
            var got = W(best), n1 = W(nb), t1 = W(t), k = [].indexOf.call(hr.cells, best);
            var cut = [hr].concat([].slice.call(t.tBodies[0].rows)).filter(function (x) { var c = x.cells[k]; return c && c.scrollWidth > c.clientWidth + 1; });
            var tip = 0; if (cut.length) { var c = cut[0].cells[k]; c.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); tip = c.title && c.title === lab(c) ? 1 : 0; }
            drag(100);
            r.narrow = [Math.round(nat - got), Math.round(n1 - n0), Math.round(t0 - t1), cut.length ? 1 : 0, tip, Math.round(W(best) - nat)].join('/');
        }
    }
    var rt = document.getElementById('resultsTable'), rm = rt && document.getElementById('tcc-' + rt.id);
    if (rm && window.resultsCsvText) {
        var b = rm.querySelector('input[data-i="3"]'), a0 = csvCols(window.resultsCsvText());
        b.checked = false; b.dispatchEvent(new Event('change'));
        var h = window.resultsCsvText().split('\n')[0].split(',');
        b.checked = true; b.dispatchEvent(new Event('change'));
        r.rcsv = [a0, h.length, h.indexOf('Src IP') >= 0 ? 1 : 0].join('/');
    }
    r.err = tcpErr;
    tcpLater(r, show, vis, lab);
}
// the slider (after each tab is shown, a frame later: the page measures a table when its tab shows): shown under each
// table wider than its box, hidden under the rest; on the first such table with '#' the slider is set to 60 px, then
// a sideways wheel of 30 px
function tcpLater(r, show, vis, lab) {
    var panes = [].slice.call(document.querySelectorAll('.tab-pane:not(#tab-topology)')), nd = [0, 0, 0, 0], ft = null;
    var done = function () {
        r.need = nd.join('/'); r.scr = '-';
        if (ft && ft.parentElement.nextElementSibling && ft.parentElement.nextElementSibling.classList.contains('tc-slide')) {
            var w = ft.parentElement, s = w.nextElementSibling, hr = ft.tHead.rows[0], h0 = hr.cells[0], d0 = ft.tBodies[0].rows[0].cells[0], hl = [].filter.call(hr.cells, vis).pop();
            d0.scrollIntoView({ block: 'center', behavior: 'instant' });
            var L = function (e) { return e.getBoundingClientRect().left; }, a = [L(h0), L(d0), L(hl)];
            s.scrollLeft = 60; s.dispatchEvent(new Event('scroll'));
            var b = [L(h0), L(d0), L(hl)], dr = d0.getBoundingClientRect();
            var top = document.elementFromPoint(dr.left + dr.width / 2, dr.top + dr.height / 2), on = top && (top === d0 || d0.contains(top)) ? 1 : 0;
            w.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaX: 30 }));
            r.scr = [Math.round(b[0] - a[0]), Math.round(b[1] - a[1]), Math.round(b[2] - a[2]), on, s.scrollLeft].join('/');
            s.scrollLeft = 0; s.dispatchEvent(new Event('scroll'));
        }
        tcpFreeze(r, vis, lab, function () { document.body.setAttribute('data-probe', Object.keys(r).map(function (k) { return k + '=' + r[k]; }).join(' ')); });
    };
    var step = function (k) {
        if (k >= panes.length) { if (ft) { show(ft.closest('.tab-pane')); setTimeout(done, 100); } else done(); return; }
        var a = document.querySelector('.nav-tabs a[href="#' + panes[k].id + '"]'); if (a) a.click(); else show(panes[k]);   // through Bootstrap, as a click would
        setTimeout(function () {
            panes[k].querySelectorAll('table.tc-cols').forEach(function (t) {
                var w = t.parentElement, s = w.nextElementSibling, on = !!(s && s.classList.contains('tc-slide') && vis(s));
                if (t.offsetWidth > w.clientWidth + 1) { nd[0]++; if (on) nd[1]++; if (!ft && lab(t.tHead.rows[0].cells[0]) === '#') ft = t; } else { nd[2]++; if (!on) nd[3]++; }
            });
            step(k + 1);
        }, 400);
    };
    step(0);
}
// freeze and move, on the first DataTable wider than its box with '#' (its tab shown): frz = 1 for each of
//   f1 a double-click on its 3rd column freezes it next to '#'; f2 a 2nd one goes after it; rows each body row's cells
//   follow the header's order; pin with the slider at 80 px both frozen headers and cells stay put; nosort the two
//   double-clicks did not sort; back a double-click on the 1st frozen one puts it back in its first place among the
//   rest, the other stays frozen; sort1 a single click sorts (a moment later); drag a drag puts the 4th rest column
//   first among the rest; grp a rest column dragged left of the frozen ones stays first among the rest; fdrag a frozen
//   column dragged left of the other frozen one goes first; csv the CSV's first columns are the frozen ones in order;
//   page on page 2 the rows follow the header too (1 when one page); nofreeze a double-click on a table that needs no slider freezes nothing
function tcpFreeze(r, vis, lab, fin) {
    r.frz = '-';
    var t = null, calm = null;
    document.querySelectorAll('.tab-pane:not(#tab-topology) table.tc-cols').forEach(function (x) {
        if (!x._tcs) return;
        if (!t && x.classList.contains('tc-need') && x._tcs.hash && $.fn.DataTable.isDataTable(x) && x._tcs.rest.length > 4) t = x;
        if (!calm && !x.classList.contains('tc-need') && x._tcs.rest.length > 2 && x.offsetWidth) calm = x;
    });
    if (!t) { fin(); return; }
    var p = t.closest('.tab-pane'), a = document.querySelector('.nav-tabs a[href="#' + p.id + '"]'); a.click();
    var st = t._tcs, dt = $(t).DataTable(), hr = t.tHead.rows[0], cell = function (i) { return tcCell(hr, i); };
    var ev = function (el, type, o) { var b = el.getBoundingClientRect(); o = o || {};
        el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, detail: o.detail || 0, clientX: o.x !== undefined ? o.x : b.left + b.width / 2, clientY: b.top + b.height / 2 })); };
    var dbl = function (el) { ev(el, 'click', { detail: 1 }); ev(el, 'click', { detail: 2 }); ev(el, 'dblclick', { detail: 2 }); };
    var drag = function (el, x) { var b = el.getBoundingClientRect(), y = b.top + b.height / 2;
        el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX: b.left + b.width / 2, clientY: y }));
        document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, clientX: x, clientY: y }));
        document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: x, clientY: y })); };
    var order = function (row) { return [].map.call(row.cells, function (c) { return c._tci; }).join(); };
    var rowsOk = function () { var h = order(hr); return [].every.call(t.tBodies[0].rows, function (x) { return x.cells.length !== st.n || order(x) === h; }) ? 1 : 0; };
    var L = function (e) { return Math.round(e.getBoundingClientRect().left); };
    setTimeout(function () {
        var o = {}, ord0 = JSON.stringify(dt.order()), A = st.rest[2], B = st.rest[4];
        dbl(cell(A)); o.f1 = st.frozen.join() === String(A) && order(hr).split(',')[1] === String(A) ? 1 : 0;
        dbl(cell(B)); o.f2 = st.frozen.join() === A + ',' + B && order(hr).split(',').slice(1, 3).join() === A + ',' + B ? 1 : 0;
        o.rows = rowsOk();
        var s = t.parentElement.nextElementSibling, d = t.tBodies[0].rows[0], before = [L(cell(A)), L(cell(B)), L(tcCell(d, A)), L(tcCell(d, B))];
        s.scrollLeft = 80; s.dispatchEvent(new Event('scroll'));
        var after = [L(cell(A)), L(cell(B)), L(tcCell(d, A)), L(tcCell(d, B))];
        o.pin = s.scrollLeft === 80 && before.join() === after.join() ? 1 : 0;
        s.scrollLeft = 0; s.dispatchEvent(new Event('scroll'));
        setTimeout(function () {
            o.nosort = JSON.stringify(dt.order()) === ord0 ? 1 : 0;
            dbl(cell(A));
            var sorted = st.rest.every(function (v, k) { return k === 0 || st.rest[k - 1] < v; });
            o.back = st.frozen.join() === String(B) && sorted && st.rest.indexOf(A) >= 0 ? 1 : 0;
            var sc = [].filter.call(hr.cells, function (c) { return c.classList.contains('sorting') && vis(c); })[0];
            ev(sc, 'click', { detail: 1 });
            setTimeout(function () {
                o.sort1 = JSON.stringify(dt.order()) !== ord0 ? 1 : 0;
                var X = st.rest[3], first = cell(st.rest[0]);
                drag(cell(X), first.getBoundingClientRect().left + 2); o.drag = st.rest[0] === X && rowsOk() ? 1 : 0;
                var Y = st.rest[2]; drag(cell(Y), cell(B).getBoundingClientRect().left + 2);
                o.grp = st.rest[0] === Y && st.frozen.join() === String(B) && order(hr).split(',')[1] === String(B) ? 1 : 0;
                dbl(cell(A)); drag(cell(A), cell(B).getBoundingClientRect().left + 2);
                o.fdrag = st.frozen.join() === A + ',' + B && order(hr).split(',').slice(1, 3).join() === A + ',' + B ? 1 : 0;
                var h = window.tableCsvText(t.id).split('\n')[0].split(',');
                o.csv = h[0] === lab(cell(A)) && h[1] === lab(cell(B)) ? 1 : 0;
                o.page = 1; if (dt.page.info().pages > 1) { dt.page(1).draw('page'); o.page = rowsOk() && t.tBodies[0].rows.length > 0 ? 1 : 0; dt.page(0).draw('page'); }
                o.nofreeze = 1;
                if (calm) { var c0 = calm._tcs.rest[1]; dbl(tcCell(calm.tHead.rows[0], c0)); o.nofreeze = calm._tcs.frozen.length === 0 ? 1 : 0; }
                r.frz = ['f1', 'f2', 'rows', 'pin', 'nosort', 'back', 'sort1', 'drag', 'grp', 'fdrag', 'csv', 'page', 'nofreeze'].map(function (k) { return o[k]; }).join('');
                fin();
            }, 500);
        }, 500);
    }, 400);
}
