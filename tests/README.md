# Tests

Both tools' suites, run from a clone: `tests/run [--fast|--full] [-j N] [ff|tc|all] [group ...]`.

| Suite | What | Groups | --fast | --full |
|---|---|---|---|---|
| ff | fabric_ferret.sh + generate_dashboard.py on a fake 5-host cluster (tests/fake/ssh), the dashboard on stored bundles, awk units | tests/ff/NN_*.sh | ~35 s, every commit | ~7 min, before a push |
| tc | thermals_capture.sh on a fake (tests/thermals/fake/ssh), its parser units, html in headless Chrome | tests/thermals/NN_*.sh | ~15 s | ~100 s |

`tests/run` runs ff then tc, one after the other; `tests/run --fast ff 14 61` runs two ff groups. One group alone, no
runner: `/opt/homebrew/bin/bash tests/ff/14_uplinks.sh fabric_ferret.sh generate_dashboard.py`.

## Contracts (run_all.sh)
- Every group states `# checks: N` in its header; the runner FAILs a group whose PASS+FAIL lines differ from N, so a
  check that went silent shows. `# secs: N` (its seconds alone) sets the launch order, longest first. `# tier: fast`
  puts it in the fast tier.
- A run cut off by its `timeout` makes every later check report `TIMEOUT after N s`, never a wrong count. A cut-off is
  2x the run's time in a full `tests/run --full all` (xrun prints `# run <name>: N s` into each group's output; read them
  from that run, not from the group alone), rounded up to a ten, floor 30 s: a hang is reported at twice the expected,
  not at an arbitrary multiple.
- A shell or awk error in a group's output is a FAIL even when its checks passed.
- `# needs: <command> ...` names a command a group cannot run without. Unmet, the group is SKIPPED by name, counted
  apart in result.txt (`X passed, Y failed, Z skipped (names)`), never as passed. Every fixture is synthetic: the fakes,
  the stored archives in fixtures/, and the site-sized inputs tests/tools make at run time (mksite.sh: a 253-host site's
  discovery and LLDP; mkmlx5.sh: mlx5 text; mkv2.sh: old-format archives). Nothing from a real cluster enters the tree.
- One suite at a time on a machine: every runner takes `$HOME/.cache/fabric_ferret/suite.lock` (FFT_SUITE_LOCK overrides);
  a second suite is refused naming the holder; a lock whose pid is gone is taken over, with a note.
- Results: `tests/regress.XXXX` (ff) and `tests/thermals/regress.XXXX` (tc): `result.txt`, `<group>.out`, `<group>.rc`
  (rc, seconds, start, end). Work dirs are removed when every check passed; the results stay.
- Fixtures (tests/fixtures): stored bundles (`bundles/`, made by tests/tools/mkbundles.sh at the commit named in
  `bundles/README`; an archive kept in an old format on purpose is a `.tar.gz`), the golden runs (`golden-B`, `golden-C`,
  regenerated with `FIXTURE_UPDATE=1 tests/run_all.sh <ff> <gd> 50 52`, which exits 3 and writes only a member whose
  normalised content changed), unit inputs (`units/`), expected outputs (`expected/`). Synthetic only.

## Addresses
The fakes live in 198.18.0.0/15 (RFC 2544 benchmarking space), which is never a site's: the public-repo leak gate blocks
any other private address. Renumbered 2026-10-29 from a private harness into these ranges:

| Here | What |
|---|---|
| 198.18.0.x | fabric fake hosts: h1..h5 = .1-.5, .6 unreachable, .7 = h1 again, .8 a BMC, h21..h32 = .21-.32 |
| 198.18.1.x | fabric fake clients c1..c4 (.1-.4), .9 = h1 again |
| 198.18.9.x | fake BMCs (-t bmc lines) |
| 198.19.N.x | rails A/B/C = 198.19.1-3.x, client data 198.19.10-11.x, the /16 case 198.19.0.0/16 |
| 198.19.(100+N).x | thermals' fake targets |
| 198.18.30.0/24, 198.18.30.10-198.18.31.20, 198.18.64-65.1-30 | 01's expansion examples |
| 198.19.178.x, 198.19.179.x, 198.19.201.11, 198.19.205.11 | units/iprail_gpu_ip.txt, nicdiag_gpu.txt (the GPU-fleet rail vote) |

192.0.2.x (TEST-NET-1) stays where it was (a jump host, a bond's address in a unit dump).

## Needs
bash 4.3+ first on PATH and at /opt/homebrew/bin/bash (the groups' shebang), python3 (the dashboard), node (rows.js: the
page's own JS), jq, perl, GNU timeout, /usr/bin/expect (01: the viewer on a pty), gawk and mawk beside the system awk for
the awk-portability checks (links made under tests/awkbin at run time, untracked), headless Google Chrome for three
thermals sections. A group that needs one it cannot find is SKIPPED by name.

## Adding a test
Add it to the group whose topic it shares, or make `tests/ff/NN_<name>.sh` (the number sets the print order) from this
shape; use `$FAKE_STATE` for the fake's files, give each collector run its own subdir (`xrun <dir> ...`), never read
another group's files, keep check names unique, end with `finish`. A new check needs a positive control: it must fail on
the code before the change. Every zero names its control in the same line.

```bash
#!/opt/homebrew/bin/bash
# one line: what this group covers
# checks: 1
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
out=$(xrun mycase FAKE_XSPEED=240 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1)
chk "my check name (control: ...)" "grep -q 'expected line' <<<\"\$out\"" "$(grep 'hint' <<<"$out")"
finish
```
