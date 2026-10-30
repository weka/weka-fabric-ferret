#!/opt/homebrew/bin/bash
# SIGKILL main mid-run: no trap can run in main, so the wrapper must finish cleanup (the 1-in-76 INT case looked
# the same: main's EXIT trap never started). Expect main's rc, run.log kept, own temp paths, locks and servers gone.
# checks: 6
# secs: 6
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
fresh; rm -f $FAKE_STATE/lock.* $FAKE_STATE/pkill.log; cd $W && rm -f fabric_ferret_*.tgz
( set -m; PATH=$S/fake:$PATH FF_HOSTS=198.18.0.1-5 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=200 perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV or die "exec: $!\n"' $B $C 1 > $W/int.out 2>&1 &
  pid=$!; t0=$EPOCHSECONDS
  until grep -q 'Iteration 1 of' $W/int.out || (( EPOCHSECONDS - t0 >= 90 )); do sleep 0.2; done
  grep -q 'Iteration 1 of' $W/int.out || echo "TIMEOUT after 90 s (no 'Iteration 1 of' to signal in)" >> $W/timeout.note
  # main = the wrapper's bash child (the other pipeline child is tee)
  m=$(pgrep -P $pid -x bash); echo "main=$m kids=$(pgrep -P $pid | tr '\n' ' ')" > $W/main.txt
  : > $FAKE_STATE/pkill.log   # count only the stops after the kill
  kill -KILL $m; wait $pid; echo "rc=$?" >> $W/int.out ) > $W/job.out 2>&1
pd=$(grep -m1 '^# Temp: ' $W/int.out | tr ' ' '\n' | grep 'dp_validation_' | head -n1)
own=$(for x in $(grep -m1 '^# Temp: ' $W/int.out | sed 's/^# Temp: //; s/ (all removed.*//'); do case $x in *dp_validation_*) ;; *) [ -e "$x" ] && echo "$x" ;; esac; done)
chk "kill main: one main found" "[ \$(awk '{print \$1}' $W/main.txt | grep -c -E '^main=[0-9]+\$') = 1 ]" "$(cat $W/main.txt)"
chk "kill main: exit code is main's (137)" "grep -q -x 'rc=137' $W/int.out" "$(tail -n1 $W/int.out)"
chk "kill main: partial dir has run.log" "[ -s \"$pd/run.log\" ]"
chk "kill main: no own temp paths" "[ -z \"$own\" ]" "own=$own"
chk "kill main: no locks left" "[ \$(ls $FAKE_STATE/lock.* 2>&1 | grep -c -v 'No such') = 0 ]" "$(ls $FAKE_STATE/lock.* 2>&1)"
chk "kill main: servers stopped on every tested host" "[ \$(sort -u $FAKE_STATE/pkill.log | wc -l) -ge 4 ]" "pkill.log: $(sort -u $FAKE_STATE/pkill.log | tr '\n' ' ')"
case $pd in */dp_validation_*) [ -d "$pd" ] && rm -rf "${pd:?}" ;; esac
finish
