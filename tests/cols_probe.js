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
var tcpErr = 0; window.addEventListener('error', function () { tcpErr++; });
window.addEventListener('load', function () { setTimeout(tcpProbe, 1500); });
function tcpProbe() {
    var r = { err: 0, elig: 0, menubad: 0, menusmall: 0, fitcols: 0, fitbad: 0, fitfirst: '-', hide: '-', rcsv: '-' };
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
    var rt = document.getElementById('resultsTable'), rm = rt && document.getElementById('tcc-' + rt.id);
    if (rm && window.resultsCsvText) {
        var b = rm.querySelector('input[data-i="3"]'), a0 = csvCols(window.resultsCsvText());
        b.checked = false; b.dispatchEvent(new Event('change'));
        var h = window.resultsCsvText().split('\n')[0].split(',');
        b.checked = true; b.dispatchEvent(new Event('change'));
        r.rcsv = [a0, h.length, h.indexOf('Src IP') >= 0 ? 1 : 0].join('/');
    }
    r.err = tcpErr;
    document.body.setAttribute('data-probe', Object.keys(r).map(function (k) { return k + '=' + r[k]; }).join(' '));
}
