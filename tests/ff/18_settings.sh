#!/opt/homebrew/bin/bash
# unknown FF_* settings stop the run; the known list covers every FF_ the collector reads
# tier: fast
# checks: 17
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

out=$(FF_STREAM=4 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); chk "typo FF_STREAM stops with a hint" "grep -q 'unknown setting FF_STREAM; did you mean FF_STREAMS?' <<<\"\$out\""
out=$(FF_FOO=1 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); chk "unrelated FF_FOO stops with the known list" "grep -q 'unknown setting FF_FOO; this tool reads: FF_BUSY_CHECK, ' <<<\"\$out\""
out=$(FF_STREAMS=4 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); chk "valid settings pass the check" "grep -qx '198.18.0.21' <<<\"\$out\" && ! grep -q 'unknown setting' <<<\"\$out\"" "$out"
# FF_RAIL_A/FF_RAIL_B are removed: the collector names them only in its guard, so they are not in FF_KNOWN
# TC_KNOWN (thermals_capture.sh's names, shared through hostfile.sh so each tool can skip the other's) is left out of the scan
kn=$(sed -n 's/^FF_KNOWN="\(.*\)"$/\1/p' $C); miss=$(grep -v '^TC_KNOWN=' $C | grep -oE '\bFF_[A-Z][A-Z0-9_]*' | grep -vxE 'FF_KNOWN|TC_KNOWN|FF_RAIL_A|FF_RAIL_B' | sort -u | while read -r v; do [[ " $kn " == *" $v "* ]] || echo $v; done)
chk "FF_KNOWN lists every FF_ the collector reads" "[ -n \"\$kn\" ] && [ -z \"\$miss\" ] && [ \$(wc -w <<<\"\$kn\") -ge 30 ]" "missing: $miss"
newmiss=$(for v in FF_CLIENTS FF_CLIENT_NETS FF_CLIENT_NICS FF_CLIENT_RATIO FF_CLIENT_GBPS FF_EXPECT_CLIENTS FF_CLIENT_SPINE_LINKS FF_CLIENT_SPINE_GBPS; do [[ " $kn " == *" $v "* ]] || echo $v; done)
chk "FF_KNOWN has the client settings" "[ -n \"\$kn\" ] && [ -z \"\$newmiss\" ]" "missing: $(echo $newmiss)"
chk "FF_KNOWN drops FF_RAIL_A and FF_RAIL_B" "[ -n \"\$kn\" ] && [[ \" \$kn \" != *' FF_RAIL_A '* && \" \$kn \" != *' FF_RAIL_B '* ]]" "known: $kn"
out=$(FF_CLIENT_RATIO=2 FF_CLIENTS=198.18.1.1 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); chk "client settings pass the unknown-setting check" "! grep -q 'unknown setting' <<<\"\$out\"" "$out"
out=$(FS_ITER=all FF_HOSTS=198.18.0.21 $B $C --list 2>&1); rc=$?
chk "old FS_ITER stops with the FF_ name" "[ $rc = 2 ] && grep -q 'setting FS_ITER uses the old FS_ prefix; settings are now FF_ (FF_ITER)' <<<\"\$out\"" "rc=$rc $out"
# FF_FERRET (the viewer): without a terminal on stderr the run is the plain run, stream for stream; 1 vs 0 vs unset
# diffed on stdout and stderr captured apart. python3 missing (a PATH of /bin and /usr/bin links without it): one log
# line, then the plain run.
for f in 0 1 unset blocks; do if [[ $f == unset ]]; then ev=; else ev="FF_FERRET=$f"; fi
    env $ev FF_HOSTS=198.18.0.21,198.18.0.22 $B $C --list > $W/fer.$f.out 2> $W/fer.$f.err; echo $? > $W/fer.$f.rc; done
chk "FF_FERRET=1 without a terminal: stdout, stderr and rc identical to FF_FERRET=0 and to unset; 0 escape bytes" \
    "cmp -s $W/fer.1.out $W/fer.0.out && cmp -s $W/fer.1.err $W/fer.0.err && cmp -s $W/fer.1.rc $W/fer.0.rc && cmp -s $W/fer.unset.out $W/fer.0.out && cmp -s $W/fer.unset.err $W/fer.0.err && [ -s $W/fer.0.out ] && [ \$(cat $W/fer.1.out $W/fer.1.err | LC_ALL=C tr -cd '\033' | wc -c) = 0 ]" \
    "$(diff $W/fer.1.out $W/fer.0.out; diff $W/fer.1.err $W/fer.0.err; echo "rc $(cat $W/fer.1.rc) $(cat $W/fer.0.rc)")"
chk "FF_FERRET=blocks (half-block cells) without a terminal: stdout, stderr and rc identical to FF_FERRET=0; 0 escape bytes" \
    "cmp -s $W/fer.blocks.out $W/fer.0.out && cmp -s $W/fer.blocks.err $W/fer.0.err && cmp -s $W/fer.blocks.rc $W/fer.0.rc && [ \$(cat $W/fer.blocks.out $W/fer.blocks.err | LC_ALL=C tr -cd '\033' | wc -c) = 0 ]" \
    "$(diff $W/fer.blocks.out $W/fer.0.out; diff $W/fer.blocks.err $W/fer.0.err; echo "rc $(cat $W/fer.blocks.rc) $(cat $W/fer.0.rc)")"
mkdir -p $W/nopy; for b in /bin/* /usr/bin/*; do n=$(basename "$b"); [[ $n == python3* ]] || ln -sf "$b" $W/nopy/$n; done
PATH=$W/nopy FF_FERRET=1 FF_HOSTS=198.18.0.21,198.18.0.22 $B $C --list > $W/fer.nopy.out 2> $W/fer.nopy.err; nrc=$?
chk "FF_FERRET=1 with no python3 on PATH: one line says so, then the plain run (stdout identical, rc the same)" \
    "[ \"\$(head -n 1 $W/fer.nopy.err)\" = '# FF_FERRET: python3 not found, running without the ferret' ] && cmp -s <(tail -n +2 $W/fer.nopy.err) $W/fer.0.err && cmp -s $W/fer.nopy.out $W/fer.0.out && [ $nrc = \$(cat $W/fer.0.rc) ]" \
    "rc $nrc; stderr: $(head -n 3 $W/fer.nopy.err)"
chk "control: with python3 on PATH the line is not there" "! grep -q 'running without the ferret' $W/fer.1.err" "$(cat $W/fer.1.err)"
# a viewer that dies must be cosmetic (10-28): FF_VIEWER (test hook: the viewer's command, terminal or not) names
# a stub that echoes two lines and exits 3. The fake-host run keeps its rc and stdout, run.log is the plain run's
# (timestamps and temp paths aside), and the terminal gets lines 1-2, the fallback line, then every later line.
frun() { fresh; mkdir -p $W/$1; ( cd $W/$1 && rm -f fabric_ferret_*; shift; env PATH=$S/fake:$PATH FF_RAILS='198.19.1.0/24;198.19.2.0/24' "$@" ); }
nrl() { sed -E 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/T/g; /^# Temp: /d' "$1"; }   # a run.log without its clock times and temp paths
frun fp FF_HOSTS=198.18.0.21,198.18.0.22,198.18.0.23 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=0 timeout 240 $B $C 1 > $W/fp.out 2> $W/fp.err; prc=$?
frun fv FF_FERRET=1 FF_VIEWER=$S/fixtures/units/stub_viewer.sh FF_HOSTS=198.18.0.21,198.18.0.22,198.18.0.23 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=0 timeout 240 $B $C 1 > $W/fv.out 2> $W/fv.err; vrc=$?
bfile fp run.log > $W/fp.runlog; bfile fv run.log > $W/fv.runlog
# the two runs' lines are compared sorted: parallel iperf3 jobs print their lines in finish order (10-29 16:07: 2 of 7 runs
# differed by one line's position with cmp on the raw files)
chk "viewer dies after two lines: the run keeps its rc and its stdout (the same lines, order aside)" "[ $vrc = $prc ] && cmp -s <(sort $W/fv.out) <(sort $W/fp.out) && [ -s $W/fv.out ]" "rc $vrc vs $prc; $(diff <(sort $W/fv.out) <(sort $W/fp.out))"
chk "viewer dies: line 3 on the terminal is the fallback line" "[ \"\$(sed -n 3p $W/fv.err)\" = '# FF_FERRET: the ferret viewer stopped (rc 3); the run continues plainly, the full log is in run.log' ]" "$(head -n 4 $W/fv.err)"
chk "viewer dies: the terminal minus the fallback line is run.log (every later line arrived)" "[ \$(wc -l < $W/fv.runlog) -gt 40 ] && cmp -s <(sed '3d' $W/fv.err | head -n \$(wc -l < $W/fv.runlog)) $W/fv.runlog" "$(diff <(sed '3d' $W/fv.err | head -n $(wc -l < $W/fv.runlog)) $W/fv.runlog | head -n 6)"
chk "viewer dies: run.log is the plain run's, clock times, temp paths and line order aside" "cmp -s <(nrl $W/fv.runlog | sort) <(nrl $W/fp.runlog | sort)" "$(diff <(nrl $W/fv.runlog | sort) <(nrl $W/fp.runlog | sort) | head -n 6)"
chk "control: the plain run's terminal has no fallback line, and the two run.logs differ before normalizing" "! grep -q 'the ferret viewer stopped' $W/fp.err && ! cmp -s $W/fv.runlog $W/fp.runlog" "$(grep -c 'viewer stopped' $W/fp.err)"
finish
