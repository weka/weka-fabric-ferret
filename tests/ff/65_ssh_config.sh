#!/opt/homebrew/bin/bash
# The user's own ssh config must not leak into the checks (2026-11-18): with ForwardX11 yes there, on hosts that refuse
# X11, every ssh session prints "X11 forwarding request failed on channel N" on stderr, and the checks that read the
# first line of a remote step's output (run lock, rail gateways, iperf3 listen) took it for the answer: every host
# failed, coverage NONE. Both tools now pass -o ForwardX11=no. The fake plays that config with FAKE_X11=1.
# checks: 10
# secs: 35
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

# (3) planted bugs: the option taken out and rq passing stderr through (it also keeps the X11 line off; issue 5a) give
# the site's symptom back (control for (1)); the option out alone, rq still catches the line, in ssh_errors.log
perl -pe 's/ServerAliveInterval=15 -o ForwardX11=no\)/ServerAliveInterval=15)/; s/^rq\(\) \{$/rq() { "\$@"; return \$?;/' $C > $W/x_x11.sh
out=$(xrun xx env $RUN FAKE_X11=1 timeout 120 $B $W/x_x11.sh 1); rc=$?
perl -pe 's/ServerAliveInterval=15 -o ForwardX11=no\)/ServerAliveInterval=15)/' $C > $W/x_x11b.sh
out2=$(xrun xy env $RUN FAKE_X11=1 timeout 120 $B $W/x_x11b.sh 1); rc2=$?
chk "planted bugs: no -o ForwardX11=no and rq pass-through (2 lines): the X11 line reaches the output and the run is not COMPLETE; the option out alone (1 line): COMPLETE, the line in ssh_errors.log as 'sshd: X11 ...'" \
    "[ \$(diff $C $W/x_x11.sh | grep -c '^>') = 2 ] && grep -qE 'X11 +forwarding +request +failed' <<<\"\$out\" && ! grep -q '^RESULT coverage=COMPLETE' <<<\"\$out\" && [ \$(diff $C $W/x_x11b.sh | grep -c '^>') = 1 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out2\" && bfile xy ssh_errors.log | grep -q '^sshd: X11 forwarding request failed'" \
    "$(diff $C $W/x_x11.sh | head -n 4) rc=$rc $(grep -E '^RESULT|run lock' <<<"$out" | tr '\n' '|') | alone: rc=$rc2 $(grep '^RESULT' <<<"$out2")"

# (4) thermals_capture.sh passes the option too (its reader keeps stderr apart, so this pins the shape)
chk "thermals_capture.sh's ssh options carry -o ForwardX11=no (control: the collector carries it twice: its own and the --thermals-only capture's)" \
    "[ \$(grep -c -- '-o ForwardX11=no)' $TC) = 1 ] && [ \$(grep -c -- '-o ForwardX11=no)' $C) = 2 ]" "$(grep -n -- 'ForwardX11' $TC $C)"

# --- the remote side's own stderr lines (2026-11-18, issue 5a): sshd prints "Could not chdir to home directory ..." on
# every session where the login's home is missing; the run lock read it as its answer, the iperf3 result parse took it
# for the first result line, and every host failed. rq keeps sshd's preamble off stderr (to ssh_errors.log) and puts
# any other stderr line after stdout; rcap gives the first/last-line checks (lock, gateway, path) stdout alone.
# (5) FAKE_SSHD_ERR=1 key run
out=$(xrun sd env $RUN FAKE_SSHD_ERR=1 timeout 120 $B $C 1); rc=$?
nlog=$(bfile sd ssh_errors.log | grep -c '^sshd: Could not chdir to home directory ')
chk "FAKE_SSHD_ERR=1 key run: rc 0, COMPLETE hosts=3/3, no 'chdir' line in the output, no run-lock warning; the bundle's ssh_errors.log keeps the lines as 'sshd: ...' (>= 3: one per host at least)" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && ! grep -qE 'chdir|could not take the run lock' <<<\"\$out\" && [ $nlog -ge 3 ]" \
    "rc=$rc ssh_errors.log sshd lines=$nlog $(grep -E '^RESULT|chdir|run lock' <<<"$out" | head -n 4 | tr '\n' '|')"
# (6) a password run under it (the site's case: a -t pw, sudo -S for a non-root login)
printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
out=$(xrun sp env FF_ITER=2 FF_UDP=0 FF_SSH_USER=ops FAKE_SSHD_ERR=1 timeout 120 $B $C -t $W/p.csv 1); rc=$?
chk "FAKE_SSHD_ERR=1 password run (-t row pw): rc 0, COMPLETE hosts=3/3, no 'chdir' line in the output" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && ! grep -q chdir <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|chdir' <<<"$out" | head -n 4 | tr '\n' '|')"
rm -f "${FAKE_STATE:?}"/pw.* "${FAKE_STATE:?}"/authed.*
# (7) a stderr line the tool does not know (a site banner): the checks still read their own answers
out=$(xrun sb env $RUN FAKE_STDERR='site banner: authorized use only' timeout 120 $B $C 1); rc=$?
chk "FAKE_STDERR banner run: rc 0, COMPLETE hosts=3/3, no run-lock warning, no failed gateway, 0 paths excluded" \
    "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && ! grep -qE 'could not take the run lock|rail gateways that failed' <<<\"\$out\" && ! grep -qE 'Path checks.* [1-9][0-9]* excluded' <<<\"\$out\"" \
    "rc=$rc $(grep -E '^RESULT|run lock|gateways that failed|Path checks' <<<"$out" | head -n 4 | tr '\n' '|')"
# (8) planted bug: rq passes stderr through as before: the sshd line reaches the result parse again
perl -pe 's/^rq\(\) \{$/rq() { "\$@"; return \$?;/' $C > $W/x_rq.sh
out=$(xrun xq env $RUN FAKE_SSHD_ERR=1 timeout 120 $B $W/x_rq.sh 1); rc=$?
chk "planted bug (rq passes stderr through): one line changed; under FAKE_SSHD_ERR=1 the chdir line shows and the run is not COMPLETE" \
    "[ \$(diff $C $W/x_rq.sh | grep -c '^>') = 1 ] && grep -q chdir <<<\"\$out\" && ! grep -q '^RESULT coverage=COMPLETE' <<<\"\$out\"" "$(diff $C $W/x_rq.sh | head -n 4) rc=$rc $(grep '^RESULT' <<<"$out")"
# (9) planted bug: rcap merges stderr again: the banner (after stdout, from rq) becomes the path check's last line
perl -pe 's/_rc_o=\$\("\$\@" 2> "\$e"\); rc=\$\?/_rc_o=\$("\$\@" 2>&1); rc=\$?/' $C > $W/x_rcap.sh
out=$(xrun xc env $RUN FAKE_STDERR='site banner: authorized use only' timeout 120 $B $W/x_rcap.sh 1); rc=$?
chk "planted bug (rcap merges stderr): one line changed; under FAKE_STDERR the gateways fail on the banner and the run is not COMPLETE" \
    "[ \$(diff $C $W/x_rcap.sh | grep -c '^>') = 1 ] && grep -q 'rail gateways that failed' <<<\"\$out\" && ! grep -q '^RESULT coverage=COMPLETE' <<<\"\$out\"" "$(diff $C $W/x_rcap.sh | head -n 4) rc=$rc $(grep -E '^RESULT|gateways' <<<"$out" | tr '\n' '|')"
finish
