// sticky_probe.js: appended to a dashboard page as an inline script, run in headless Chrome (--dump-dom). For every
// tab, every card box that holds a table of 3 or more rows is cut to 120 px (so it scrolls) and scrolled past its first table's top; the gap between the box's
// top inner edge and every cell of that table's sticky header row is measured (the one farthest from the edge counts). Writes body[data-probe] = "boxes=<n> maxgap=<px>
// mingap=<px>". A gap above 0 means rows show between the box's edge and the header while it scrolls.
window.addEventListener('load', function () { setTimeout(probe, 1500); });   // after the page's own ready handlers (DataTables)
function probe() {
    var n = 0, mx = -1, mn = 1e9;
    document.querySelectorAll('.tab-pane').forEach(function (p) {
        document.querySelectorAll('.tab-pane').forEach(function (x) { x.classList.remove('active', 'show'); });
        p.classList.add('active', 'show');
        p.querySelectorAll('.scroll').forEach(function (sc) {
            var t = sc.querySelector('table'), th = t && t.querySelector('thead th');
            if (!th || t.tBodies.length == 0 || t.tBodies[0].rows.length < 3) return;
            sc.style.flex = "none"; sc.style.height = "120px"; sc.style.minHeight = "0";   // short enough to scroll
            if (sc.scrollHeight - sc.clientHeight < 40) return;
            var top = t.getBoundingClientRect().top - sc.getBoundingClientRect().top;
            sc.scrollTop = Math.min(sc.scrollHeight - sc.clientHeight, top + 40);
            var g = 0, edge = sc.getBoundingClientRect().top + sc.clientTop;
            t.querySelectorAll("thead tr:first-child th").forEach(function (h) { var d = Math.round(h.getBoundingClientRect().top - edge); if (Math.abs(d) > Math.abs(g)) g = d; });
            sc.scrollTop = 0; n++; if (g > mx) mx = g; if (g < mn) mn = g;
        });
    });
    document.body.setAttribute('data-probe', 'boxes=' + n + ' maxgap=' + mx + ' mingap=' + (n ? mn : -1));
}
