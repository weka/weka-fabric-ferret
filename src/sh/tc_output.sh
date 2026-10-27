# ---------- output ----------

# Type by what a sensor measures, whatever read it: GPUs (nvidia-smi, amdgpu) are gpu; a BMC sensor is typed by its
# name, first match wins: inlet/ambient; VRM/PSU/board/FPGA/HMC/HSC/PLX/PEX/PCH/SAS other; nic/aoc/ocp/cx<n>/port
# (so an HGX ConnectX is a NIC); gpu/hbm/nvlink/nvsw; nvme/ssd/m.2/drive; dimm/mem; cpu/proc/soc; else other.
# hwmon drivetemp is nvme, jc42/spd5118 mem. Appends Min_C (the lowest sample) as column 13. Reads temps.txt
# then temps_summary.txt (fabric_ferret's TEMP_SUM_AWK stays unchanged). The data rows come before the nodata rows
# (the spine sorts them so): a gpu nodata row on a host whose BMC rows were typed gpu (HGX GPU, HBM, NVLink) becomes
# note: instead, since the BMC has that host's GPU temperatures; a note is not a no-data (counts, verdict, Not read).
TYPE_AWK='
#@awk tc_type'

# per host the hottest reading of each type and its flags: "Host Inlet CPU GPU Mem NVMe NIC Other Flags"
HOST_MAX_AWK='#@awk tc_host_max'
HOST_MAX_HDR="Host Inlet CPU GPU Mem NVMe NIC Other Flags"

# stdout: one row per host and source (hwmon, which takes nvidia-smi's GPUs too, and ipmi), the hottest reading
# of each type and the flags
SRC_AWK='#@awk tc_src'

# the sensor rows as shown: one sample "... Sensor Temp High Crit Flag", several "... Sensor First Min Max Last High
# Crit Flag" (no-data rows left out; the flag is always the last column)
VIEW_AWK='#@awk tc_view'

# the 2 a.m. view, on stderr: counts, the per-host table, flagged sensors, every no-data source and reason (hosts
# with the same source and reason share one counted line, up to 8 named; each host's own row is in the jsonl, md and
# html), then the notes (gpu nodata covered by the BMC)
print_summary() {
    local ts=$WORK/temps_summary.txt
    echo ""
    local fk=10 mk=7; (( NSAMP > 1 )) && { fk=13; mk=9; }   # flag and max columns of the view
    echo "Temperatures, $( (( NSAMP > 1 )) && echo "$NSAMP samples" || echo "one reading") (hwmon, GPUs via nvidia-smi$( (( FF_IPMI )) && echo ", BMC via ipmitool"); flags: crit, high, near = within ${FF_TEMP_MARGIN}C of high$( (( NSAMP > 1 )) && echo ", rise = up more than ${FF_TEMP_RISE}C over the samples")):"
    awk '#@awk tc_print_summary' "$ts"
    if awk 'NR > 1 && $NF != "-" {f = 1} END {exit !f}' "$WORK/view"; then
        echo "  Flagged sensors:"
        { head -n 1 "$WORK/view"; awk 'NR > 1 && $NF != "-"' "$WORK/view" | sort -k${fk},${fk} -k${mk},${mk}nr; } | column -t | sed 's/^/    /'
    fi
    awk 'NR > 1 && $12 ~ /^(nodata|note):/ { k = substr($12, 1, 4) SUBSEP $2 SUBSEP substr($12, index($12, ":") + 1)
            if (!(k in c)) kord[++nk] = k; c[k]++; if (c[k] <= 8) hl[k] = hl[k] " " $1 }
        END { for (i = 1; i <= nk; i++) { k = kord[i]; split(k, p, SUBSEP); more = (c[k] > 8 ? " and " (c[k] - 8) " more" : "")
                if (p[1] == "note") printf "  NOTE: %d host(s) gave no nvidia-smi reading (%s); their GPU temperatures come from the BMC (HGX GPU, HBM, NVLink):%s%s\n", c[k], p[3], hl[k], more
                else if (c[k] == 1) printf "  NO TEMPERATURE DATA:%s %s (%s)\n", hl[k], p[2], p[3]
                else printf "  NO TEMPERATURE DATA: %s (%s): %d hosts:%s%s\n", p[2], p[3], c[k], hl[k], more } }' "$ts" | sort
    echo ""
}

# one JSON object per line: run, host (one per target), sample, reading, sensor (the summary), nodata, note, result.
# Strings are already [A-Za-z0-9_.:=-] (the reader and clean() map the rest to _); q() escapes anyway.
JSONL_AWK='
#@awk tc_jsonl'

# A self-contained page (no network): a left nav (after the cs plugin dashboards) with Overview, a page per type
# (its OS table, then its BMC / IPMI table) and Not read at the foot. A table is one row per host; columns are
# grouped by device, the same device on every host; cells the temperature (max with -d), flagged cells shaded.
# The tables are static HTML, so the page reads and
# prints without script; the inline script only switches panels and sorts a table on a header click.
read -r -d '' HTML_HEAD <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@TITLE@</title>
<style>
:root { --bg: #fbfbfa; --surface: #ffffff; --surface-2: #f2f1ed; --fg: #1d1f21; --fg-2: #52514e; --mut: #6b6a66;
  --line: #dcdcd8; --accent: #2a78d6; --crit: #b3261e; --critbg: #fde7e5; --high: #b45309; --highbg: #fdf0e1;
  --near: #8a6d00; --nearbg: #fbf6dc; --rise: #5b4bb7; --risebg: #eeebfb; --ok: #1e7d3c;
  --head: #dce9f9; --head-ink: #173b66; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #17181a; --surface: #1f2124;
  --surface-2: #26282c; --fg: #e6e6e3; --fg-2: #c3c2bd; --mut: #a0a3a8; --line: #33363a; --accent: #6aa6ef;
  --crit: #ff8a80; --critbg: #3d1c1a; --high: #ffb366; --highbg: #3a2a16; --near: #e6cf5c; --nearbg: #332e14;
  --rise: #b3a6ff; --risebg: #2a2640; --ok: #7bd88f; --head: #1d3350; --head-ink: #cfe2fb; } }
:root[data-theme="dark"] { --bg: #17181a; --surface: #1f2124; --surface-2: #26282c; --fg: #e6e6e3; --fg-2: #c3c2bd;
  --mut: #a0a3a8; --line: #33363a; --accent: #6aa6ef; --crit: #ff8a80; --critbg: #3d1c1a; --high: #ffb366;
  --highbg: #3a2a16; --near: #e6cf5c; --nearbg: #332e14; --rise: #b3a6ff; --risebg: #2a2640; --ok: #7bd88f;
  --head: #1d3350; --head-ink: #cfe2fb; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { padding: 14px 16px; border-bottom: 1px solid var(--line); background: var(--surface); }
h1 { font-size: 18px; margin: 0 0 2px; } h2 { font-size: 16px; margin: 4px 0 10px; } h3 { font-size: 14px; margin: 18px 0 8px; }
.mut { color: var(--mut); }
a { color: var(--accent); }
.body { display: flex; align-items: flex-start; }
#nav { position: sticky; top: 0; flex: 0 0 200px; padding: 14px 10px; display: flex; flex-direction: column; gap: 2px;
  height: 100vh; overflow-y: auto; scrollbar-width: thin; }
#nav button { font: inherit; text-align: left; cursor: pointer; background: transparent; border: 0; border-radius: 6px;
  color: var(--fg-2); padding: 6px 10px; display: flex; justify-content: space-between; gap: 8px; align-items: center; }
#nav button:hover { background: var(--surface-2); color: var(--fg); }
#nav button[aria-selected="true"] { background: var(--surface); color: var(--fg); font-weight: 600; box-shadow: inset 2px 0 0 var(--accent); }
#nav .count { color: var(--mut); font-size: 12px; font-variant-numeric: tabular-nums; font-weight: 400; }
#nav .navgroup { color: var(--mut); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; padding: 14px 10px 4px; }
/* Not read sits at the foot of the nav, as the cs dashboards pin their gear */
#nav-footer { margin-top: auto; padding-top: 10px; border-top: 1px solid var(--line); }
#nav-footer button { width: 100%; }
#nav button.warn .count { color: var(--high); font-weight: 600; }
main { flex: 1 1 auto; min-width: 0; padding: 14px 16px 32px; }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px; margin: 0 0 12px; }
.res { font-weight: 600; } .res.COMPLETE { color: var(--ok); } .res.PARTIAL, .res.NONE { color: var(--crit); }
.nodata { border-color: var(--crit); } .nodata h3 { color: var(--crit); margin-top: 0; }
/* a table scrolls inside its own box, no taller than the window, so its sideways scrollbar is always on screen;
   the scrollbars are styled, so they show even where the system hides them until you scroll */
.wrap { overflow: auto; max-height: calc(100vh - 150px); border: 1px solid var(--line); border-radius: 8px;
  background: var(--surface); scrollbar-width: auto; scrollbar-color: var(--mut) var(--surface-2); }
.wrap::-webkit-scrollbar { width: 12px; height: 12px; }
.wrap::-webkit-scrollbar-track { background: var(--surface-2); }
.wrap::-webkit-scrollbar-thumb { background: var(--mut); border-radius: 6px; border: 3px solid var(--surface-2); }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 4px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
thead { position: sticky; top: 0; z-index: 2; }
th { background: var(--head); color: var(--head-ink); font-weight: 600; }
th.grp { text-align: left; border-left: 2px solid var(--surface); }
th .chip { font-weight: 400; opacity: 0.75; font-size: 12px; margin-left: 6px; }
th.gs, td.gs { border-left: 2px solid var(--line); }
td.crit { background: var(--critbg); color: var(--crit); font-weight: 600; } td.high { background: var(--highbg); color: var(--high); font-weight: 600; }
td.near { background: var(--nearbg); color: var(--near); } td.rise { background: var(--risebg); color: var(--rise); }
th.n, td.n { text-align: right; }
table.sortable th { cursor: pointer; user-select: none; }
table.sortable th[aria-sort="ascending"]::after { content: " \25B2"; font-size: 10px; }
table.sortable th[aria-sort="descending"]::after { content: " \25BC"; font-size: 10px; }
td.host, th.host { position: sticky; left: 0; background: var(--surface); z-index: 1; }
th.host { background: var(--head); z-index: 2; }
th .dev { display: block; font-weight: 400; color: var(--mut); font-size: 12px; }
tr.crit td { background: var(--critbg); color: var(--crit); } tr.high td { background: var(--highbg); color: var(--high); }
tr.near td { background: var(--nearbg); color: var(--near); } tr.rise td { background: var(--risebg); color: var(--rise); }
@media (max-width: 860px) {
  .body { flex-direction: column; align-items: stretch; }
  main { width: 100%; min-width: 0; }
  #nav { position: static; flex: 1 1 auto; width: 100%; flex-direction: row; flex-wrap: wrap; max-height: none; }
  #nav .navgroup { width: 100%; padding: 6px 10px 2px; }
  #nav { height: auto; }
  #nav-footer { margin-top: 0; width: 100%; }
}
@media print { #nav { display: none; } section.panel[hidden] { display: block !important; } }
</style>
</head>
<body>
EOF
read -r -d '' HTML_TAIL <<'EOF'
<script>
(function () {
  "use strict";
  var nav = document.getElementById("nav");
  var panels = Array.prototype.slice.call(document.querySelectorAll("section.panel"));
  // each visible table box ends at the bottom of the window, so its sideways scrollbar is on screen
  // and the nav ends there too, so Not read at its foot is on screen (wide layout only; narrow, the nav wraps)
  function fitnav() {
    if (window.innerWidth <= 860) { nav.style.height = ""; return; }
    nav.style.height = (window.innerHeight - Math.max(0, nav.getBoundingClientRect().top)) + "px";
  }
  function fit() {
    Array.prototype.forEach.call(document.querySelectorAll("section.panel:not([hidden]) .wrap"), function (w) {
      var top = w.getBoundingClientRect().top + window.scrollY;
      w.style.maxHeight = Math.max(160, window.innerHeight - top - 12) + "px";
    });
    fitnav();
  }
  window.addEventListener("resize", fit);
  window.addEventListener("scroll", fitnav, { passive: true });
  // a panel's element id is "p-" + its name, so the #name in the URL never makes the browser jump to it
  function show(id) {
    panels.forEach(function (p) { p.hidden = p.id !== "p-" + id; });
    fit();
    Array.prototype.forEach.call(nav.querySelectorAll("button[data-panel]"), function (b) {
      b.setAttribute("aria-selected", b.getAttribute("data-panel") === id ? "true" : "false");
    });
    try { history.replaceState(null, "", "#" + id); } catch (e) { /* file:// in some browsers */ }
  }
  document.addEventListener("click", function (ev) {   // nav buttons, and links such as the Overview's "see Not read"
    var b = ev.target.closest("[data-panel]");
    if (!b) return;
    ev.preventDefault(); show(b.getAttribute("data-panel")); window.scrollTo(0, 0);
  });
  // sort on a header click: numbers by data-v (no reading always last), text naturally (host-2 before host-10)
  function val(row, i, num) {
    var c = row.children[i];
    if (!c) return null;
    if (num) { var v = c.getAttribute("data-v"); return v === null || v === "" ? null : parseFloat(v); }
    return c.textContent;
  }
  // the sortable headers carry data-col, their column index (a device group header above them doesn't sort)
  Array.prototype.forEach.call(document.querySelectorAll("table.sortable"), function (t) {
    var ths = t.tHead.querySelectorAll("th[data-col]");
    Array.prototype.forEach.call(ths, function (th) {
      var i = parseInt(th.getAttribute("data-col"), 10);
      th.addEventListener("click", function () {
        var dir = th.getAttribute("aria-sort") === "ascending" ? -1 : 1, num = th.classList.contains("n");
        if (num && !th.hasAttribute("aria-sort")) dir = -1;   // first click on a number: hottest first
        Array.prototype.forEach.call(ths, function (h) { h.removeAttribute("aria-sort"); });
        th.setAttribute("aria-sort", dir === 1 ? "ascending" : "descending");
        var body = t.tBodies[0], rows = Array.prototype.slice.call(body.rows);
        rows.sort(function (a, b) {
          var x = val(a, i, num), y = val(b, i, num);
          if (x === null && y === null) return 0;
          if (x === null) return 1;
          if (y === null) return -1;
          if (num) return dir * (x - y);
          return dir * x.localeCompare(y, undefined, { numeric: true });
        });
        rows.forEach(function (r) { body.appendChild(r); });
      });
    });
  });
  var want = location.hash.slice(1);
  show(want && document.getElementById("p-" + want) ? want : "overview");
})();
</script>
</body>
</html>
EOF

# The page body: header, nav and panels. Inputs: hostmax, view, temps_summary.txt, pivot ("group type chip dev sensor
# host value high crit flag", sorted), hosts (sorted). Strings are already [A-Za-z0-9_.:=-]; e() escapes anyway.
# A type table has a row of device groups over the sensors when any column has a device (gs[j] = 1 where a group
# starts); a sensor's crit goes under its name when every host has the same one, else into each cell.
HTML_AWK='
#@awk tc_html'

# Markdown, laid out like the html: contents, Overview (result, no-data list, hottest per host and type, flagged
# sensors), then a section per type with its OS and BMC / IPMI tables, one row per host. A BMC table has a column per sensor ("HGX GPU",
# crit in the header when every host has the same one, else in the cell). An OS table has a column per device
# ("ibp13s0 mlx5"); its cell lists that device's sensors ("asic 41.0 · Module0 26.4"), or "max T of N sensors" past 4 of
# them (a CPU socket's cores). A flagged reading is bold with its flag. Every single reading is in the jsonl.
MD_AWK='
#@awk tc_md'
