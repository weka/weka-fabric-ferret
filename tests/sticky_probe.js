// sticky_probe.js: appended to a dashboard page as an inline script, run in headless Chrome (--dump-dom). For every
// tab, every scrolling card box that holds a table is scrolled past its first table's top; the gap between the box's
// top inner edge and that table's sticky header row is measured. Writes body[data-probe] = "boxes=<n> maxgap=<px>
// mingap=<px>". A gap above 0 means rows show between the box's edge and the header while it scrolls.
window.addEventListener('load', function () {
    var n = 0, mx = -1, mn = 1e9;
    document.querySelectorAll('.tab-pane').forEach(function (p) {
        document.querySelectorAll('.tab-pane').forEach(function (x) { x.classList.remove('active', 'show'); });
        p.classList.add('active', 'show');
        p.querySelectorAll('.scroll').forEach(function (sc) {
            var t = sc.querySelector('table'), th = t && t.querySelector('thead th');
            if (!th || sc.scrollHeight - sc.clientHeight < 60) return;
            var top = t.getBoundingClientRect().top - sc.getBoundingClientRect().top;
            sc.scrollTop = Math.min(sc.scrollHeight - sc.clientHeight, top + 40);
            var g = Math.round(th.getBoundingClientRect().top - (sc.getBoundingClientRect().top + sc.clientTop));
            sc.scrollTop = 0; n++; if (g > mx) mx = g; if (g < mn) mn = g;
        });
    });
    document.body.setAttribute('data-probe', 'boxes=' + n + ' maxgap=' + mx + ' mingap=' + (n ? mn : -1));
});
