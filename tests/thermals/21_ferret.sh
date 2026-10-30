#!/opt/homebrew/bin/bash
# FF_FERRET (the viewer) in thermals_capture.sh: without a terminal the run is the plain run (1 vs 0 vs unset, stdout
# and stderr captured apart); python3 missing is said once, then the plain run; a viewer that dies after two lines
# (FF_VIEWER names harness_ferret's stub) keeps the rc, the rows and the files, and the fallback line names no run log.
# tier: fast
# checks: 13
# secs: 20
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
STUB=$H/../fixtures/units/stub_viewer.sh
# cap <dir> VAR=... cmd...: as lib's run, stdout and stderr apart ($W/<dir>.out, $W/<dir>.err); the fake case "all"
cap() { local d=$W/$1; shift; mkdir -p "$d/fake" "$d/out"; echo all > "$d/fake/case.198.19.104.1"
        ( cd "$d" && timeout 180 env PATH=$H/fake:$PATH FAKE_TC=$d/fake FF_OUT_DIR=$d/out "$@" > "$d.out" 2> "$d.err" ); }
norm() { strip_time < "$1" | sed -E "/^# To copy here from a jump host/d; s#$W/[a-z0-9]+/out/#$W/X/out/#"; }   # a stderr without the clock, file names, the capture dir and the scp line
for f in 0 1 unset; do if [[ $f == unset ]]; then ev=; else ev="FF_FERRET=$f"; fi
    cap l$f env $ev FF_HOSTS=198.19.104.1,198.19.104.2 $B $TC --list; echo $? > $W/l$f.rc; done
chk "FF_FERRET=1 without a terminal: --list's stdout, stderr and rc identical to FF_FERRET=0 and to unset; 0 escape bytes" \
    "cmp -s $W/l1.out $W/l0.out && cmp -s $W/l1.err $W/l0.err && cmp -s $W/l1.rc $W/l0.rc && cmp -s $W/lunset.out $W/l0.out && cmp -s $W/lunset.err $W/l0.err && [ -s $W/l0.out ] && [ \$(cat $W/l1.out $W/l1.err | LC_ALL=C tr -cd '\033' | wc -c) = 0 ]" \
    "$(diff $W/l1.out $W/l0.out; diff $W/l1.err $W/l0.err; echo "rc $(cat $W/l1.rc) $(cat $W/l0.rc)")"
cap fp FF_HOSTS=198.19.104.1 $B $TC -o jsonl,md; prc=$?
cap f1 FF_FERRET=1 FF_HOSTS=198.19.104.1 $B $TC -o jsonl,md; orc=$?
cap fv FF_FERRET=1 FF_VIEWER=$STUB FF_HOSTS=198.19.104.1 $B $TC -o jsonl,md; vrc=$?
chk "FF_FERRET=1 without a terminal, a full run: rc, the rows and stderr (clock and file names aside) are the plain run's; 0 escape bytes" \
    "[ $orc = $prc ] && cmp -s $W/f1.out $W/fp.out && [ -s $W/fp.out ] && cmp -s <(norm $W/f1.err) <(norm $W/fp.err) && [ \$(cat $W/f1.out $W/f1.err | LC_ALL=C tr -cd '\033' | wc -c) = 0 ]" \
    "rc $orc vs $prc; $(diff $W/f1.out $W/fp.out; diff <(norm $W/f1.err) <(norm $W/fp.err))"
chk "viewer dies after two lines: the run keeps its rc and its rows" "[ $vrc = $prc ] && cmp -s $W/fv.out $W/fp.out && [ -s $W/fv.out ]" "rc $vrc vs $prc; $(diff $W/fv.out $W/fp.out)"
chk "viewer dies: line 3 on the terminal is the fallback line, naming no run log" "[ \"\$(sed -n 3p $W/fv.err)\" = '# FF_FERRET: the ferret viewer stopped (rc 3); the run continues plainly' ]" "$(head -n 4 $W/fv.err)"
sed '3d' $W/fv.err > $W/fv3.err
chk "viewer dies: the terminal minus the fallback line is the plain run's stderr (every later line arrived)" "[ \$(wc -l < $W/fp.err) -gt 5 ] && cmp -s <(norm $W/fv3.err) <(norm $W/fp.err)" "$(diff <(norm $W/fv3.err) <(norm $W/fp.err) | head -n 6)"
chk "viewer dies: the jsonl holds the plain run's readings (the files hold the data)" "cmp -s <(strip_time < $W/fv/out/*.jsonl) <(strip_time < $W/fp/out/*.jsonl) && [ \$(wc -l < $W/fp/out/*.jsonl) -gt 10 ]" "$(diff <(strip_time < $W/fv/out/*.jsonl) <(strip_time < $W/fp/out/*.jsonl) | head -n 4)"
chk "control: the plain run's stderr has no fallback line, and the two differ before the line is removed" "! grep -q 'the ferret viewer stopped' $W/fp.err && ! cmp -s $W/fv.err $W/fp.err" "$(grep -c 'viewer stopped' $W/fp.err)"
# python3 missing: a PATH of /bin and /usr/bin links without it (--list needs no ssh, so the fake dir can go)
mkdir -p $W/nopy; for b in /bin/* /usr/bin/*; do n=$(basename "$b"); [[ $n == python3* ]] || ln -sf "$b" $W/nopy/$n; done
cap np env PATH=$W/nopy FF_FERRET=1 FF_HOSTS=198.19.104.1,198.19.104.2 $B $TC --list; nrc=$?
chk "FF_FERRET=1 with no python3 on PATH: one line says so, then the plain run (stdout identical, rc the same)" \
    "[ \"\$(head -n 1 $W/np.err)\" = '# FF_FERRET: python3 not found, running without the ferret' ] && cmp -s <(tail -n +2 $W/np.err) $W/l0.err && cmp -s $W/np.out $W/l0.out && [ $nrc = \$(cat $W/l0.rc) ]" \
    "rc $nrc; $(head -n 3 $W/np.err)"
chk "control: with python3 on PATH the line is not there" "! grep -q 'running without the ferret' $W/l1.err" "$(cat $W/l1.err)"
# --- a -t file's settings lines work as the command line (read first, exported; 10-28): FF_FERRET and FF_VIEWER
# from the file start the stand-in viewer (harness_ferret's env_viewer.sh), which prints the FF_FERRET and FF_SSH_USER
# it was given; the environment still wins, noted once; a bad line dies before any viewer ---
EV=$H/../fixtures/units/env_viewer.sh
mkf() { local f=$W/$1; shift; printf '%s\n' "$@" > "$f"; chmod 600 "$f"; echo "$f"; }
tf=$(mkf f_tf 'backend,198.19.104.1' 'FF_FERRET=1' "FF_VIEWER=$EV" 'FF_SSH_USER=u1')
cap tf env -u FF_HOSTS -u FF_SSH_USER $B $TC --list -t "$tf"; trc=$?
chk "-t file with FF_FERRET=1, FF_VIEWER=<stand-in>, FF_SSH_USER=u1: the stand-in runs and prints FF_FERRET=1 FF_SSH_USER=u1 once (exported to a child); rc as the plain --list; the target listed" \
    "[ $trc = \$(cat $W/l0.rc) ] && [ \$(grep -c '^# viewer sees FF_FERRET=1 FF_SSH_USER=u1\$' $W/tf.err) = 1 ] && grep -q '198.19.104.1' $W/tf.out" "rc $trc; $(cat $W/tf.err | head -n 4)"
tf0=$(mkf f_tf0 'backend,198.19.104.1'); cap tf0 env -u FF_HOSTS -u FF_SSH_USER $B $TC --list -t "$tf0"
chk "control: the same file without the settings lines starts no viewer (0 'viewer sees' lines; 1 above), the target listed" "[ \$(grep -c 'viewer sees' $W/tf0.err) = 0 ] && grep -q '198.19.104.1' $W/tf0.out" "$(cat $W/tf0.err | head -n 3)"
cap tfe env -u FF_HOSTS FF_SSH_USER=u2 $B $TC --list -t "$tf"
chk "env beats file: FF_SSH_USER=u2 exported with the file's u1: the stand-in prints FF_SSH_USER=u2, and line 4's value is noted as ignored, once (through the viewer: main logs it)" \
    "[ \$(grep -c '^# viewer sees FF_FERRET=1 FF_SSH_USER=u2\$' $W/tfe.err) = 1 ] && [ \$(grep -c \"^# -t $tf line 4: FF_SSH_USER is set in the environment; the file's value is ignored\$\" $W/tfe.err) = 1 ]" "$(cat $W/tfe.err | head -n 4)"
tfx=$(mkf f_tfx 'backend,198.19.104.1' 'FF_FOO=1' 'FF_FERRET=1' "FF_VIEWER=$EV"); cap tfx env -u FF_HOSTS -u FF_SSH_USER $B $TC --list -t "$tfx"; xrc=$?
chk "a bad settings line dies in the pre-pass, before the viewer: unknown FF_FOO on line 2, rc 2, the ERROR names file and line, 0 'viewer sees' lines, 0 escape bytes" \
    "[ $xrc = 2 ] && grep -q \"^ERROR: -t $tfx line 2: unknown setting FF_FOO;\" $W/tfx.err && [ \$(grep -c 'viewer sees' $W/tfx.err) = 0 ] && [ \$(cat $W/tfx.out $W/tfx.err | LC_ALL=C tr -cd '\033' | wc -c) = 0 ]" "rc $xrc; $(cat $W/tfx.err | head -n 3)"
finish
