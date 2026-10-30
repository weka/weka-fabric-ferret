#!/opt/homebrew/bin/bash
# per-host run lock (released, foreign lock stops, FF_IGNORE_LOCK), early stop RESULT
# checks: 3
# secs: 20
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# "a normal run leaves no lock" moved to 50_golden_B.sh (10-26)
rm -f $FAKE_STATE/lock.*
echo "other-run-01 since=x,from=jump2,user=ops" > $FAKE_STATE/lock.h2
out=$(FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3 FF_ITER=3 frunfull; echo "rc=$?")
chk "lock: foreign live lock stops run, ours released" "grep -q 'another fabric_ferret run is active on 1 hosts' <<<\"\$out\" && grep -q 'rc=2' <<<\"\$out\" && [ \"\$(ls $FAKE_STATE/lock.* | wc -l | tr -d ' ')\" = 1 ]"
out=$(FF_IGNORE_LOCK=1 FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3 FF_ITER=3 frunfull)
chk "lock: FF_IGNORE_LOCK proceeds, foreign lock kept" "grep -q 'coverage=COMPLETE' <<<\"\$out\" && grep -q other-run-01 $FAKE_STATE/lock.h2"
rm -f $FAKE_STATE/lock.*
out=$(cd $W; PATH=$S/fake:$PATH FF_HOSTS=198.18.0.1,198.18.0.2 timeout 60 $B $C 1 2>&1; echo "rc=$?")
chk "early stop: RESULT STOPPED rc=2" "grep -q '^RESULT coverage=STOPPED' <<<\"\$out\" && grep -q 'rc=2' <<<\"\$out\""
finish
