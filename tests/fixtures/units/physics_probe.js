// usage: node physics_probe.js page.html
// Runs the page's own topoSetLayout over a stub network that records every setOptions call and plays the part of
// vis that caused the Force bug (10-29 12:25, recorded setOptions arguments; vis LayoutEngine.setOptions):
//   - a call that turns hierarchical ON backs up the physics it was handed ({enabled, solver || 'barnesHut'}) and
//     writes solver 'hierarchicalRepulsion' into that physics object (in place);
//   - a call that turns hierarchical OFF writes the backup into the physics object it was handed (in place), so the
//     layout's own physics object on the page carries vis's restored values from then on;
//   - what the network runs after a call = the physics object as it stands when the call returns.
// Prints one JSON line per step (mode, the physics the network runs, the page's force solver and radial enabled),
// then a summary line. Facts only; the group's checks assert.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const base = html.match(/    var topoBaseOpts = \{[\s\S]*?\n    \};/);
const lay = html.match(/    var topoLayouts = \{[\s\S]*?\n    \};/);
const fn = html.match(/    window\.topoSetLayout = function\(mode\) \{[\s\S]*?\n    \};/);
const frozen = html.match(/    var topoPhysics = \{\};\n[\s\S]*?function topoPhysicsCopy\(mode\) \{[^\n]*\n/);
if (!base || !lay || !fn) { console.log('block not found: base ' + !!base + ' layouts ' + !!lay + ' setLayout ' + !!fn); process.exit(2); }
let hier = false, backup = null, running = null, calls = 0;
const topoNetwork = {
  setOptions: function(o) {
    calls++;
    if (o.layout && o.layout.hierarchical !== undefined) {
      const on = !!o.layout.hierarchical && o.layout.hierarchical !== false;
      if (on && !hier) {
        if (o.physics === undefined || o.physics === true) { o.physics = { enabled: true, solver: 'hierarchicalRepulsion' }; backup = { enabled: true, solver: 'barnesHut' }; }
        else { backup = { enabled: o.physics.enabled === undefined ? true : o.physics.enabled, solver: o.physics.solver || 'barnesHut' }; o.physics.solver = 'hierarchicalRepulsion'; }
      } else if (!on && hier && backup) {
        if (o.physics === undefined || typeof o.physics !== 'object') o.physics = {};
        Object.assign(o.physics, backup);   // vis restores into the object it was handed
      }
      hier = on;
    }
    if (o.physics !== undefined) running = JSON.parse(JSON.stringify(o.physics));
  },
  stabilize: function() {}, fit: function() {}, unselectAll: function() {}
};
const topoNodes = { update: function() {} };
let topoRingIds = [], topoRadialLabels = {};
function topoRadialPlace() {}
function topoApplyLabels() {}
const btn = { classList: { add() {}, remove() {} } };
const document = { querySelectorAll: () => [btn], getElementById: () => btn };
const window = globalThis;
let topoCurrentLayout = 'radial';
eval(base[0] + '\n' + lay[0] + '\n' + (frozen ? frozen[0] : '') + fn[0]);
const out = [];
const step = (mode) => {
  topoSetLayout(mode);
  out.push({ step: out.length + 1, mode: mode, running: running, force_solver: topoLayouts.force.physics.solver, radial_enabled: topoLayouts.radial.physics.enabled, calls: calls });
  console.log(JSON.stringify(out[out.length - 1]));
};
['hierarchical', 'force', 'hierarchical', 'radial', 'force', 'radial'].forEach(step);
console.log('END steps=' + out.length + ' setOptions_calls=' + calls + ' frozen_block=' + !!frozen);
