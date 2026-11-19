// sticky_probe.js: appended to a dashboard page as an inline script, run in headless Chrome (--dump-dom) after the
// page's own ready handlers (DataTables). A table's box grows to its rows (issue 13), so the page scrolls: for every
// tab, every table of 3 or more rows is scrolled 40 px past the window's top (a tall spacer at the page's end lets
// the last table get there), and every cell of its header row is measured from the window's top (the cell farthest
// from it counts). Writes body[data-probe] = "boxes=<n> maxgap=<px> mingap=<px>"; 0 = the header row stays at the
// window's top; below 0 = it scrolled away with the rows.
window.addEventListener('load', function () { setTimeout(probe, 1500); });
function probe() {
    var n = 0, mx = -1, mn = 1e9, pad = document.createElement('div');
    pad.style.height = '4000px'; document.body.appendChild(pad);
    document.querySelectorAll('.tab-pane:not(#tab-topology)').forEach(function (p) {
        document.querySelectorAll('.tab-pane').forEach(function (x) { x.classList.remove('active', 'show'); });
        p.classList.add('active', 'show');
        p.querySelectorAll('table.table').forEach(function (t) {
            if (!t.tHead || !t.tBodies.length || t.tBodies[0].rows.length < 3 || !t.offsetParent) return;
            window.scrollTo({ top: t.getBoundingClientRect().top + window.scrollY + 40, behavior: 'instant' });   // not smooth (Bootstrap's default)
            var g = 0;
            t.querySelectorAll('thead tr:first-child th').forEach(function (h) { var d = Math.round(h.getBoundingClientRect().top); if (Math.abs(d) > Math.abs(g)) g = d; });
            n++; if (g > mx) mx = g; if (g < mn) mn = g;
        });
    });
    window.scrollTo({ top: 0, behavior: 'instant' }); pad.remove();
    document.body.setAttribute('data-probe', 'boxes=' + n + ' maxgap=' + mx + ' mingap=' + (n ? mn : -1));
}
