#!/opt/homebrew/bin/bash
# Body of the 09_signal_<SIG> groups (not a group itself): SIGS names the signals to send mid-run.
# Cleanup must stop iperf3, keep partial data with its log, leave no own temp dirs or locks.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

for sig in ${SIGS:?SIGS}; do
    fresh; rm -f $FAKE_STATE/lock.*; cd $W && rm -f fabric_ferret_*.tgz
    # perl resets SIGINT/SIGQUIT to default before exec: a suite started in the background inherits them
    # ignored, bash cannot undo that, and INT would never land (the run then goes all 200 iterations)
    ( set -m; PATH=$S/fake:$PATH FF_HOSTS=198.18.0.1-5 FF_RAILS='198.19.1.0/24;198.19.2.0/24' FF_ITER=200 perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV or die "exec: $!\n"' $B $C 1 > $W/int.out 2>&1 &
      # signal mid-run: past discovery (the first iteration has started), else the collector drops its collect
      # dir by design. Gives up waiting at 90s, and says so.
      pid=$!; t0=$EPOCHSECONDS
      until grep -q 'Iteration 1 of' $W/int.out || (( EPOCHSECONDS - t0 >= 90 )); do sleep 0.2; done
      grep -q 'Iteration 1 of' $W/int.out || echo "TIMEOUT after 90 s (no 'Iteration 1 of' to signal in)" >> $W/timeout.note
      if [ $sig = TEEKILL ]; then pkill -KILL -g $pid -x tee; sleep 3; kill -INT -- -$pid; else kill -$sig -- -$pid; fi
      wait $pid; echo "rc=$?" >> $W/int.out ) > $W/job.out 2>&1
    # this run's own collect dir, from its "# Temp:" line; never pick by age (other runs share TMPDIR)
    pd=$(grep -m1 '^# Temp: ' $W/int.out | tr ' ' '\n' | grep 'dp_validation_' | head -n1)
    # this run's own temp paths, as it logged them (other runs, e.g. fsLab's, may share the machine)
    own=$(for x in $(grep -m1 '^# Temp: ' $W/int.out | sed 's/^# Temp: //; s/ (all removed.*//'); do case $x in *dp_validation_*) ;; *) [ -e "$x" ] && echo "$x" ;; esac; done)
    chk "signal $sig: exit code" "grep -q -E 'rc=(130|143|129)' $W/int.out" "$(tail -n1 $W/int.out)"
    chk "signal $sig: partial dir has run.log" "[ -s \"$pd/run.log\" ]"
    chk "signal $sig: no own temp dirs, no locks" "[ -z \"$own\" ] && [ \$(ls $FAKE_STATE/lock.* 2>&1 | grep -c -v 'No such') = 0 ]" "own=$own"
    case $pd in */dp_validation_*) [ -d "$pd" ] && rm -rf "${pd:?}" ;; esac
done
finish
