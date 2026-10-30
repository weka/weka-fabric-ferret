// usage: node rows.js page.html -> prints per-host Status counts from the page's own JS (host view of allResultsTable)
const fs = require('fs'); const html = fs.readFileSync(process.argv[2], 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
let captured = {};
const any = new Proxy(function () {}, { get: (t, p) => p === Symbol.toPrimitive ? () => '' : (p === 'length' ? 0 : any), apply: () => any, construct: () => any });
function $(sel) { if (typeof sel === "function") { try { sel(); } catch (e) { if (process.env.DBG) console.error("ready error:", e.message); } return any; } return new Proxy(function () {}, { get: (t, p) => {
    if (p === "ready") return (fn) => { try { fn(); } catch (e) { console.error("ready error:", e.stack.split("\n").slice(0,3).join(" | ")); } }; if (p === "html") return (x) => { if (x !== undefined) captured[sel] = x; return $(sel); };
    if (p === 'length') return 0; if (p === Symbol.toPrimitive) return () => ''; return any; }, apply: () => any }); }
$.fn = { DataTable: { isDataTable: () => false } }; $.extend = (...a) => Object.assign({}, ...a.slice(1));
global.$ = global.jQuery = $; global.window = global; global.document = new Proxy({}, { get: (t, p) => any }); global.vis = any; global.Chart = any; global.Plotly = any; global.setTimeout = () => 0; global.Set = Set;
global.localStorage = any; global.navigator = any; global.Blob = any; global.URL = any;
// the page's Topology pane opens at load (10-29): topoShown() runs in the ready block and asks the window for listeners
global.addEventListener = () => {}; global.removeEventListener = () => {}; global.getComputedStyle = () => ({ getPropertyValue: () => '' }); global.innerWidth = 1280; global.innerHeight = 800; global.requestAnimationFrame = () => 0;
for (const s of scripts) { try { eval(s); } catch (e) { if (process.env.DBG) console.error('script error:', e.message); } }
const tb = captured['#allResultsTable tbody'] || '';
const st = [...tb.matchAll(/<tr><td><\/td><td>([^<]*?)( <span class="badge badge-down" title="[^"]*">HOT<\/span>)?<\/td><td><span class="badge[^"]*">([^<]*)<\/span>/g)].map(m => [m[1] + (m[2] ? '(HOT)' : ''), m[3]]);
const c = {}; st.forEach(([h, s]) => c[s] = (c[s] || 0) + 1);
console.log(JSON.stringify(c)); if (process.env.ROWS) st.forEach(x => console.log(x.join(' ')));
