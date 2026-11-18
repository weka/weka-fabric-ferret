#!/opt/homebrew/bin/bash
# The user's own ssh config must not leak into the checks (2026-11-18): with ForwardX11 yes there, on hosts that refuse
# X11, every ssh session prints "X11 forwarding request failed on channel N" on stderr, and the checks that read the
# first line of a remote step's output (run lock, rail gateways, iperf3 listen) took it for the answer: every host
# failed, coverage NONE. Both tools now pass -o ForwardX11=no. The fake plays that config with FAKE_X11=1.
# checks: 5
# secs: 20
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
TC=$(dirname "$C")/thermals_capture.sh
RUN="FF_HOSTS=198.18.0.21-23 FF_ITER=2 FF_UDP=0"

# control: the fake prints the refusal without the option, and not with it
a=$(FAKE_X11=1 $S/fake/ssh -n 198.18.0.21 true 2>&1); b=$(FAKE_X11=1 $S/fake/ssh -n -o ForwardX11=no 198.18.0.21 true 2>&1)
chk "control: FAKE_X11=1's fake ssh prints 'X11 forwarding request failed on channel 0' without -o ForwardX11=no, nothing with it" \
    "grep -qx 'X11 forwarding request failed on channel 0' <<<\"\$a\" && ! grep -q X11 <<<\"\$b\"" "without=[$a] with=[$b]"

# (1) a key run under FAKE_X11=1: every check as without it
out=$(xrun kx env $RUN FAKE_X11=1 timeout 120 $B $C 1); rc=$?
chk "FAKE_X11=1 key run: rc 0, COMPLETE hosts=3/3, no X11 line, no 'could not take the run lock', no failed gateway, no 'not listening'" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && ! grep -qE 'X11|could not take the run lock|rail gateways that failed|not listening' <<<\"\$out\"" \
    "rc=$rc $(grep -E '^RESULT|X11|run lock|gateways that failed|not listening' <<<"$out" | head -n 5 | tr '\n' '|')"

# (2) a password run (the ssh that opens the master carries DISPLAY for askpass), as on the site that showed it
TPWD='Pw,with spaces!9'
printf '%s\n' "backend,198.18.0.21,bob,$TPWD" 'backend,198.18.0.22' 'backend,198.18.0.23' > $W/p.csv; chmod 600 $W/p.csv
printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
out=$(xrun px env FF_ITER=2 FF_UDP=0 FF_SSH_USER=ops FAKE_X11=1 timeout 120 $B $C -t $W/p.csv 1); rc=$?
chk "FAKE_X11=1 password run (-t row pw): rc 0, COMPLETE hosts=3/3, bob authenticated through askpass, no X11 line" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && grep -qx '198.18.0.21 bob' $FAKE_STATE/askpass.log && ! grep -q X11 <<<\"\$out\"" \
    "rc=$rc $(grep -E '^RESULT|X11' <<<"$out" | head -n 4 | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"
rm -f "${FAKE_STATE:?}"/pw.* "${FAKE_STATE:?}"/authed.*

# (3) planted bug: the option taken out again gives the site's symptom (control for (1))
perl -pe 's/ServerAliveInterval=15 -o ForwardX11=no\)/ServerAliveInterval=15)/' $C > $W/x_x11.sh
out=$(xrun xx env $RUN FAKE_X11=1 timeout 120 $B $W/x_x11.sh 1); rc=$?
chk "planted bug (no -o ForwardX11=no): one line changed; the run lock fails with the X11 line and the run is not COMPLETE" \
    "[ \$(diff $C $W/x_x11.sh | grep -c '^>') = 1 ] && grep -q 'could not take the run lock' <<<\"\$out\" && grep -q '^#   h21 X11 forwarding request failed' <<<\"\$out\" && ! grep -q '^RESULT coverage=COMPLETE' <<<\"\$out\"" \
    "$(diff $C $W/x_x11.sh | head -n 4) rc=$rc $(grep -E '^RESULT|run lock' <<<"$out" | tr '\n' '|')"

# (4) thermals_capture.sh passes the option too (its reader keeps stderr apart, so this pins the shape)
chk "thermals_capture.sh's ssh options carry -o ForwardX11=no (control: the collector carries it twice: its own and the --thermals-only capture's)" \
    "[ \$(grep -c -- '-o ForwardX11=no)' $TC) = 1 ] && [ \$(grep -c -- '-o ForwardX11=no)' $C) = 2 ]" "$(grep -n -- 'ForwardX11' $TC $C)"
finish
