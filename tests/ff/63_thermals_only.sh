#!/opt/homebrew/bin/bash
# fabric_ferret.sh --thermals-only / FF_THERMALS_ONLY=1 (10-29 12:22, 12:28): the thermals capture inside wff, equal to
# thermals_capture.sh on the same targets (files, RESULT, rc), with thermals' -o/-d/-i/-v only in that mode; a -t settings
# line turns it on; a thermals run writes no bundle and a fabric run writes no thermcap_* file. Targets on the fake:
# backends 198.18.0.21-22 (h21, h22), client 198.18.1.1 (c1); thermals_capture.sh is the one beside the collector.
# checks: 9
# secs: 15
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
TC=$(dirname "$C")/thermals_capture.sh
HC="FF_HOSTS=198.18.0.21,198.18.0.22 FF_CLIENTS=198.18.1.1"
printf '%s\n' 'backend,198.18.0.21' 'backend,198.18.0.22' 'client,198.18.1.1' > $W/t.csv
# the per-run values: the UTC stamps (in the records, the html/md header line and the file names), the run's own
# output dir on the "Wrote" lines, and this machine's name on the scp hint line
norm() { sed -E 's/"(time|start|end)":"[^"]*"/"\1":"T"/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/T/g; s/thermcap_[0-9]{8}T[0-9]{6}Z/thermcap_X/g; s/scp .[^:]*:/scp H:/' "$1" | sed -e "s#$W/tc/#D/#g" -e "s#$W/ff/#D/#g"; }   # two -e: BSD sed has no \| alternation
# trun <dir> <cmd...>: a thermals run in $W/<dir> on the fake, stdout/stderr apart, rc in <dir>.rc; no FF_RAILS (none needed)
trun() { local d=$W/$1; shift; mkdir -p $d; ( cd $d && env PATH=$S/fake:$PATH FF_OUT_DIR=$d "$@" > $d/out 2> $d/err ); echo $? > $d.rc; }
fresh; trun tc $B $TC -t $W/t.csv -o jsonl,html,md
fresh; trun ff env $HC $B $C --thermals-only -o jsonl,html,md
# (1) parity: the three files and the RESULT line, per-run values aside; one planted line breaks the compare
pair() { cmp -s <(norm $W/tc/thermcap_*.$1) <(norm $W/ff/thermcap_*.$1); }
chk "parity: --thermals-only writes the same thermcap_<UTC>.jsonl, .html and .md as thermals_capture.sh -t (stamps and file names normalised), one file of each (control: a planted extra line in a jsonl copy gives 1 diff line)" \
    "[ \$(ls $W/tc | grep -c '^thermcap_') = 3 ] && [ \$(ls $W/ff | grep -c '^thermcap_') = 3 ] && pair jsonl && pair html && pair md && [ \$(diff <(norm $W/tc/thermcap_*.jsonl) <({ norm $W/ff/thermcap_*.jsonl; echo '{\"type\":\"planted\"}'; }) | grep -c '^[<>]') = 1 ]" \
    "tc: $(ls $W/tc | tr '\n' ' ') ff: $(ls $W/ff | tr '\n' ' ') | jsonl diff: $(diff <(norm $W/tc/thermcap_*.jsonl) <(norm $W/ff/thermcap_*.jsonl) | head -n 4 | cut -c1-120 | tr '\n' '|')"
chk "parity: stderr identical (the scp hint's machine name normalised), rc equal (0), RESULT data=COMPLETE hosts=3/3 in both; control: the two RESULT lines are non-empty and the same text" \
    "cmp -s <(norm $W/tc/err) <(norm $W/ff/err) && [ \"\$(cat $W/tc.rc)\" = \"\$(cat $W/ff.rc)\" ] && [ \"\$(cat $W/ff.rc)\" = 0 ] && [ \"\$(grep '^RESULT' $W/ff/err)\" = \"\$(grep '^RESULT' $W/tc/err)\" ] && grep -q '^RESULT data=COMPLETE hosts=3/3' $W/ff/err" \
    "rc $(cat $W/tc.rc) $(cat $W/ff.rc); $(diff <(norm $W/tc/err) <(norm $W/ff/err) | head -n 4 | cut -c1-140 | tr '\n' '|')"
# (2) refusals, each with its text and RESULT line; the fabric's own die says coverage=STOPPED, the mode's says data=STOPPED
o=$(env $HC $B $C -d 3 2>&1); rc=$?
chk "refused: -d outside the mode (rc 2, RESULT coverage=STOPPED, the message names --thermals-only)" "[ $rc = 2 ] && grep -q -- '-d is for --thermals-only (thermals_capture.sh.s options); this run tests the fabric' <<<\"\$o\" && grep -q '^RESULT coverage=STOPPED' <<<\"\$o\"" "rc=$rc $o"
o=$(env $HC $B $C --thermals-only 30 2>&1); rc=$?
chk "refused: a bare duration inside the mode (rc 2, RESULT data=STOPPED, 'use -d for --thermals-only')" "[ $rc = 2 ] && grep -q 'use -d for --thermals-only' <<<\"\$o\" && grep -q '^RESULT data=STOPPED' <<<\"\$o\"" "rc=$rc $o"
o=$(env $HC FF_THERMALS_ONLY=2 $B $C --list 2>&1); rc=$?
chk "refused: FF_THERMALS_ONLY=2 (rc 2, 'must be 0 or 1, got '2'')" "[ $rc = 2 ] && grep -q \"FF_THERMALS_ONLY must be 0 or 1, got '2'\" <<<\"\$o\" && grep -q 'STOPPED' <<<\"\$o\"" "rc=$rc $o"
o=$(env FF_HOSTS=198.18.0.21,198.18.0.22 FF_CLIENTS=198.18.0.22 $B $C --thermals-only --list 2>&1); rc=$?
chk "refused: a target in both FF_HOSTS and FF_CLIENTS in the mode (rc 2, names it, RESULT data=STOPPED)" "[ $rc = 2 ] && grep -q 'target 198.18.0.22 is in both FF_HOSTS and FF_CLIENTS' <<<\"\$o\" && grep -q '^RESULT data=STOPPED' <<<\"\$o\"" "rc=$rc $o"
# (3) --list parity
env $HC $B $C --thermals-only --list > $W/ffl.out 2> $W/ffl.err; frc=$?
$B $TC --list -t $W/t.csv > $W/tcl.out 2> $W/tcl.err; trc=$?   # thermals takes --list first (its usage)
chk "--list parity: stdout and stderr identical to thermals_capture.sh -t --list, rc 0 both; control: the listing names the 3 targets" "[ $frc = 0 ] && [ $trc = 0 ] && cmp -s $W/ffl.out $W/tcl.out && cmp -s $W/ffl.err $W/tcl.err && [ \$(grep -c -E '^198\.18\.(0\.2[12]|1\.1)$' $W/ffl.out) = 3 ]" "rc $frc $trc; $(diff $W/ffl.out $W/tcl.out | head -n 3 | tr '\n' '|') $(cat $W/ffl.out | tr '\n' ' ')"
# (4) the mode from a -t settings line: a thermals capture, no bundle; (5) a fabric run with the setting unset: no thermcap file
printf '%s\n' 'FF_THERMALS_ONLY=1' 'backend,198.18.0.21' 'backend,198.18.0.22' > $W/ts.csv
fresh; trun ts $B $C -t $W/ts.csv
out=$(xrun fab FF_HOSTS=198.18.0.21,198.18.0.22 FF_SKIP_IPERF=1 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=0 timeout 120 $B $C 1); frc=$?
chk "FF_THERMALS_ONLY=1 from a -t settings line: the capture runs (RESULT data= line, a thermcap_*.jsonl written), 0 fabric_ferret_*.tgz in its dir; control: the fabric run below wrote 1 bundle" \
    "grep -q '^RESULT data=' $W/ts/err && [ \$(ls $W/ts | grep -c '^thermcap_.*\.jsonl$') = 1 ] && [ \$(ls $W/ts | grep -c '^fabric_ferret_.*\.tgz$') = 0 ] && [ \$(ls $W/fab | grep -c '^fabric_ferret_.*\.tgz$') = 1 ]" \
    "ts: rc $(cat $W/ts.rc) $(ls $W/ts | tr '\n' ' ') $(grep '^RESULT' $W/ts/err); fab: $(ls $W/fab | tr '\n' ' ')"
chk "a fabric run (FF_THERMALS_ONLY unset) writes no thermcap_* file and ends with RESULT coverage=; control: the thermals run above wrote 3" \
    "[ \$(ls $W/fab | grep -c '^thermcap_') = 0 ] && grep -q '^RESULT coverage=' <<<\"\$out\" && [ \$(ls $W/ff | grep -c '^thermcap_') = 3 ]" "rc=$frc $(ls $W/fab | tr '\n' ' ') $(grep '^RESULT' <<<"$out")"
finish
