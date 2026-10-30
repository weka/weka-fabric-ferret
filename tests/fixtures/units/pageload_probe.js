// usage: node pageload_probe.js page.html
// Runs the page's inline script at "load" under stubs (document, jQuery's $(fn) runs fn at once, vis, Plotly, bootstrap),
// the way a browser would run it before any click, and prints what a reader of the page cannot see from the HTML: the
// exceptions thrown at load (message and the first stack line), and whether the page's window.* entry points exist
// afterwards. Facts only; the group's checks assert. Stubs never throw: a throw comes from the page's own code.
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.log('no inline script'); process.exit(2); }
const errors = [];
const anything = () => new Proxy(function () {}, {
  get: (t, p) => { if (p === Symbol.toPrimitive) return () => ''; if (p === 'length') return 0; if (p === 'then') return undefined; return anything(); },
  set: () => true, apply: () => anything(), construct: () => anything(), has: () => true });
// an element knows the classes its tag carries in the HTML (by id), so classList.contains('active') answers as the page is
const classesOf = (id) => { const t = html.match(new RegExp('<[a-z]+ [^>]*id="' + id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"[^>]*>')); const c = t && t[0].match(/class="([^"]*)"/); return c ? c[1].split(/\s+/) : []; };
const els = {};   // one element per id, kept, so what the page writes into the drawer can be read back
const el = (id) => { if (id && els[id]) return els[id]; const cls = new Set(classesOf(id || '')); const e = new Proxy({ id: id || '', classList: { add(c) { cls.add(c); }, remove(c) { cls.delete(c); }, toggle(c, on) { on === undefined ? (cls.has(c) ? cls.delete(c) : cls.add(c)) : (on ? cls.add(c) : cls.delete(c)); }, contains(c) { return cls.has(c); } }, style: {}, dataset: {}, innerHTML: '', value: '', textContent: '' }, {
  get: (t, p) => (p in t) ? t[p] : anything(), set: (t, p, v) => { t[p] = v; return true; } }); if (id) els[id] = e; return e; };
const document = { getElementById: (id) => el(id), querySelector: () => el(), querySelectorAll: () => [], addEventListener() {}, body: el(), documentElement: el(), createElement: () => el(), readyState: 'complete' };
const run = (f) => { try { f(); } catch (e) { errors.push(e); } };
// $(fn), $(document).ready(fn) and $(window).on('load', fn) all run fn at once, as the browser does at load
const jq = () => new Proxy(function () {}, { get: (t, p) => p === 'ready' ? (f) => { run(f); return jq(); } : p === 'on' ? (ev, f) => { if (typeof f === 'function' && /load|ready/.test(ev)) run(f); return jq(); } : jq(), apply: () => jq(), construct: () => jq(), has: () => true });
const $ = function (a) { if (typeof a === 'function') { run(a); return; } return jq(); };
$.fn = anything(); $.each = () => {}; $.extend = () => ({}); $.ajax = () => anything();   // $.fn.dataTable.isDataTable and the like
// vis.DataSet keeps the page's own nodes and edges, so the panels read real data; vis.Network stays a stub
const dataSets = [];   // every DataSet the page makes, so the "ring" mode can read the nodes after the page's own calls
class DataSet { constructor(a) { this.items = Array.isArray(a) ? a.map(x => Object.assign({}, x)) : []; dataSets.push(this); }
  get(id, o) { if (id === undefined || (id && typeof id === 'object' && !Array.isArray(id))) return this.items; if (Array.isArray(id)) return id.map(i => this.items.find(x => x.id === i)); return this.items.find(x => x.id === id); }
  getIds() { return this.items.map(x => x.id); } update(u) { (Array.isArray(u) ? u : [u]).forEach(c => { const x = this.items.find(y => y.id === c.id); if (x) Object.assign(x, c); }); }
  add(u) { (Array.isArray(u) ? u : [u]).forEach(c => this.items.push(Object.assign({}, c))); } remove() {} forEach(f) { this.items.forEach(f); } map(f) { return this.items.map(f); } get length() { return this.items.length; } }
// bootstrap.Tab records every .show(): an IP click that switches tabs shows up here (criterion 4: it must not)
const tabShows = [], tabHides = []; class Tab { constructor(e) { this.e = e; } show() { tabShows.push(this.e && this.e.id ? this.e.id : String(this.e)); } hide() { tabHides.push(this.e && this.e.id ? this.e.id : String(this.e)); } static getOrCreateInstance(e) { return new Tab(e); } static getInstance(e) { return new Tab(e); } }
const bootstrapStub = new Proxy({ Tab }, { get: (t, p) => (p in t) ? t[p] : anything() });
const sandbox = { document, $, jQuery: $, vis: { DataSet, Network: anything() }, Plotly: anything(), bootstrap: bootstrapStub, console: { log() {}, warn() {}, error() {} },
  setTimeout: (f) => 0, clearTimeout() {}, requestAnimationFrame: () => 0, navigator: {}, location: { hash: '', href: '' }, performance: { now: () => 0 },
  localStorage: { getItem: () => null, setItem() {} }, Math, JSON, Object, Array, String, Number, parseInt, parseFloat, isNaN, Date, RegExp, Error, Map, Set, Promise, Symbol };
Object.assign(sandbox, { addEventListener() {}, removeEventListener() {}, getComputedStyle: () => ({ getPropertyValue: () => '' }), innerWidth: 1280, innerHeight: 800, devicePixelRatio: 1, matchMedia: () => ({ matches: false, addEventListener() {} }), scrollTo() {} });
sandbox.window = sandbox; sandbox.globalThis = sandbox; sandbox.self = sandbox;
const ctx = vm.createContext(sandbox);
// "planted" as the second argument appends one bootstrap.Tab .show() (the control that the Tab counter is live; before
// 10-29 the sandbox named bootstrap twice and the stub never saw a call) and a call to an undefined function: the
// control that an error at load is seen
const script = m[1] + (process.argv[3] === 'planted' ? '\n$(function () { new bootstrap.Tab({ id: "planted-tab" }).show(); });\n$(function () { nosuchfn_planted(); });\n' : '');
try { vm.runInContext(script, ctx, { filename: 'inline', timeout: 10000 }); } catch (e) { errors.push(e); }
const names = ['topoOpen', 'topoSetLayout', 'topoSetLabels', 'resetTopo', 'topoFit', 'topoNicPanel', 'topoShowPanel'];
console.log(JSON.stringify({ errors: errors.map(e => String(e && e.message || e).slice(0, 160)), fns: Object.fromEntries(names.map(n => [n, typeof sandbox[n]])), tab_shows: tabShows.length, tab_hides: tabHides.length }));
// "ring" as the second argument: the hot-host ring (hot: true, border #ff7a1a, borderWidth 4) counted in the page's node
// DataSet at load, after window.resetTopo() and after topoSetLayout('force'): the map's own calls must not strip it
if (process.argv[3] === 'ring') {
  const ds = dataSets.find(d => d.items.some(x => x.group === 'host' || x.group === 'leaf' || x.group === 'client'));
  const ring = () => ds ? ds.items.filter(x => x.hot === true && x.color && x.color.border === '#ff7a1a' && x.borderWidth === 4).length : -1;
  const hot = ds ? ds.items.filter(x => x.hot === true).length : -1;
  const r = { hot, load: ring() };
  try { sandbox.resetTopo(); } catch (e) { errors.push(e); } r.reset = ring();
  try { sandbox.topoSetLayout('force'); } catch (e) { errors.push(e); } r.force = ring();
  console.log(JSON.stringify({ ring: r, ring_errors: errors.length }));
}
// "panels" as the second argument: open every NIC panel (window.topoNicPanel(ip) for each ip in topoNicData) and every
// node panel (window.topoShowPanel('node', id) for each node that has one) through the page's own entry points, read
// the drawer (#topoLinkPanel, #topoPanelTitle) after each, and print per kind: count, cells that read undefined / NaN /
// [object, empty cells, IP links and those with a title and an onclick, the NIC panels' "+N more" and run-table lines
if (process.argv[3] === 'panels') {
  const look = (h) => ({ bad: (h.match(/undefined|NaN|\[object/g) || []).length, empty: (h.match(/<td><\/td>/g) || []).length,
    links: (h.match(/class="ip-link"/g) || []).length, linksOk: (h.match(/class="ip-link" title="[^"]+" onclick="topoNicPanel\('[^']+'\); return false;"/g) || []).length });
  const out = {}; const add = (k, h, extra) => { const c = look(h); const o = out[k] = out[k] || { n: 0, bad: 0, empty: 0, links: 0, linksOk: 0, titled: 0 };
    o.n++; o.bad += c.bad; o.empty += c.empty; o.links += c.links; o.linksOk += c.linksOk; if (els.topoPanelTitle && els.topoPanelTitle.textContent) o.titled++; if (extra) for (const [a, b] of Object.entries(extra)) o[a] = (o[a] || 0) + b; };
  // the data lines sit inside the ready function, so they are read from the HTML, not the sandbox
  const line = (name) => { const m = html.match(new RegExp('^    var ' + name + ' = (.*?);(?:   //.*)?$', 'm')); return m ? JSON.parse(m[1].replace(/, topoLeafData = .*$/, '')) : null; };
  const nic = line('topoNicData') || {}; const nodes = line('topoNodesData') || [];
  const tabShowsAtLoad = tabShows.length;
  for (const ip of Object.keys(nic)) { try { if (els.topoPanelTitle) els.topoPanelTitle.textContent = ''; sandbox.topoNicPanel(ip); } catch (e) { errors.push(e); }
    const h = (els.topoLinkPanel && els.topoLinkPanel.innerHTML) || '';
    add('nic', h, { runs: /Backend runs, slowest first/.test(h) ? 1 : 0, noruns: /No backend runs for this NIC/.test(h) ? 1 : 0, more: /\+\d+ more \(all in Raw Data\)/.test(h) ? 1 : 0 }); }
  if (out.nic) out.nic.tab_shows_by_ip_clicks = tabShows.length - tabShowsAtLoad;   // criterion 4: an IP click must not switch tabs
  // the IP links inside <details> rows (Needs Repair's grouped no-switch NICs): each must open a titled NIC panel too
  // (the page writes the quotes as &#x27; inside the attribute; a planted row may use ')
  const dIps = (html.match(/<details>[\s\S]*?<\/details>/g) || []).flatMap(d => [...d.matchAll(/topoNicPanel\((?:'|&#x27;)([^'&]+)(?:'|&#x27;)\)/g)].map(x => x[1]));
  const dt = { ips: dIps.length, titled: 0, norow: 0, errors: 0 };   // norow: the panel's "No NIC row for <ip> in this run."
  for (const ip of dIps) { try { if (els.topoPanelTitle) els.topoPanelTitle.textContent = ''; sandbox.topoNicPanel(ip); } catch (e) { errors.push(e); dt.errors++; }
    if (els.topoPanelTitle && els.topoPanelTitle.textContent) dt.titled++;
    if (/No NIC row for/.test((els.topoLinkPanel && els.topoLinkPanel.innerHTML) || '')) dt.norow++; }
  out.details = dt;
  for (const n of nodes) { if (!n.panel) continue; try { if (els.topoPanelTitle) els.topoPanelTitle.textContent = ''; sandbox.topoShowPanel('node', n.id); } catch (e) { errors.push(e); }
    const h = (els.topoLinkPanel && els.topoLinkPanel.innerHTML) || '';
    add(n.panel.kind, h, n.panel.kind === 'leaf' ? { paths: /Runs to the other leaves|No backend runs/.test(h) ? 1 : 0, declared: /Declared/.test(h) ? 1 : 0, grid: /NIC.*IP.*Rail.*Leaf.*Worst run.*Drops/.test(h) ? 1 : 0 } : n.panel.kind === 'spine' ? { linkrows: /link/i.test(h) ? 1 : 0 } : {}); }   // linkrows: the spine's uplink rows, not IP links
  console.log(JSON.stringify({ panels: out, panel_errors: errors.length }));
}
console.log('END errors=' + errors.length);
