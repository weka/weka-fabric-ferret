#!/opt/homebrew/bin/bash
# Passwords asked on the terminal (2026-11-18): a -t row whose pw is exactly ? (one prompt per login; a bmc row: per BMC
# user), --pw-prompt and FF_PW_PROMPT=1 (one password for every ssh target that has none, FF_HOSTS targets too). Each
# run is on a pty (/usr/bin/expect, fixtures/units/pw_prompt.exp) against the fake: pw.<target> = the password that
# host takes, through SSH_ASKPASS (askpass.log); any environment variable holding it -> pwenv.log.
# checks: 20
# secs: 25
# needs: expect perl
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
TC=$(dirname "$C")/thermals_capture.sh
TPWD='Pw,with spaces!9'; TPW2='second pw#2'; BPW='bmc pw!x'   # lib.sh's one-letter globals are not shadowed
mk() { local f=$W/$1 m=$2; shift 2; printf '%s\n' "$@" > "$f"; chmod "$m" "$f"; echo "$f"; }   # mk <name> <mode> <line>...
ans() { printf '%s\n' "$@" > "$W/ans.$$"; echo "$W/ans.$$"; }   # the answers, one per prompt
pwreset() { rm -f "${FAKE_STATE:?}"/authed.* "${FAKE_STATE:?}"/pw.* "${FAKE_STATE:?}"/{askpass,pwenv,logins}.log; }
# prun <dir> <answers> [VAR=...]... <script> [arg...]: the script on a pty from $W/<dir> on the fake rails; every byte
# the pty showed in $W/<dir>.cap; pw_prompt.exp's own cut-off (240 s, rc 99) is noted as a TIMEOUT
prun() {
    local d=$1 a=$2 rc t0=$SECONDS; shift 2; local -a ev=(); while [[ $1 == *=* ]]; do ev+=("$1"); shift; done
    fresh; mkdir -p $W/$d
    ( cd $W/$d && rm -f fabric_ferret_*; env PATH=$S/fake:$PATH FF_RAILS='198.19.1.0/24;198.19.2.0/24' "${ev[@]}" \
        /usr/bin/expect -f $S/fixtures/units/pw_prompt.exp $W/$d.cap 240 "$a" $B "$@" ); rc=$?
    (( rc == 99 )) && echo "TIMEOUT after 240 s (pw_prompt.exp, run $d)" >> "$W/timeout.note"
    echo "# run $d: $(( SECONDS - t0 )) s" >&2; return $rc
}
cap() { tr -d '\r' < "$W/$1.cap"; }
nprompt() { cap $1 | grep -cE '^(BMC p|P)assword for .*\): $'; }   # the prompt lines alone (a warning's 'passwords' is not one)
RUN="FF_ITER=2 FF_UDP=0"   # 3 hosts: one round leaves a host out, so two

# (1) a ? row: one prompt naming the login, the password through askpass, nowhere else; the file holds no password,
# so no chmod warning on a 644 file (old code took ? as the password: bob refused, and warned)
Q=$(mk q.csv 644 'backend,198.18.0.21,bob,?' 'backend,198.18.0.22' 'backend,198.18.0.23')
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun q "$(ans "$TPWD")" $RUN FF_SSH_USER=ops $C -t $Q 1; rc=$?
chk "? row: one prompt 'Password for login bob', bob's host authenticated through askpass, COMPLETE hosts=3/3 rc 0" \
    "[ $rc = 0 ] && [ \$(nprompt q) = 1 ] && cap q | grep -q 'Password for login bob (the -t rows whose pw is ?): ' && [ \"\$(cat $FAKE_STATE/askpass.log)\" = '198.18.0.21 bob' ] && cap q | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc prompts=$(nprompt q) askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)] $(cap q | grep -E '^RESULT|ERROR|assword')"
leak=$( { cap q; tar xzOf "$(bundle q)" 2>&1; cat $FAKE_STATE/logins.log; } | grep -cF -- "$TPWD")
chk "? row: the typed password not echoed on the pty, not in the bundle or a logged argv, in no environment (no pwenv.log); no 'holds passwords' warning for the 644 file (control: the answers file holds it)" \
    "[ $leak = 0 ] && [ ! -e $FAKE_STATE/pwenv.log ] && ! cap q | grep -q 'holds passwords' && grep -qF -- \"\$TPWD\" $W/ans.$$" \
    "leak=$leak pwenv=[$(cat $FAKE_STATE/pwenv.log 2>&1)] $(cap q | grep 'holds passwords')"

# (2) two logins with ?: one prompt each, in file order, each password to its own login's hosts
Q2=$(mk q2.csv 600 'backend,198.18.0.21,bob,?' 'backend,198.18.0.22,carol,?' 'backend,198.18.0.23')
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21; printf '%s' "$TPW2" > $FAKE_STATE/pw.198.18.0.22
prun two "$(ans "$TPWD" "$TPW2")" $RUN FF_SSH_USER=ops $C -t $Q2 1; rc=$?
chk "two ? logins: two prompts (bob, then carol), each host authenticated with its own, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \"\$(cap two | grep -o 'Password for login [a-z]*' | tr '\n' ' ')\" = 'Password for login bob Password for login carol ' ] && [ \"\$(sort $FAKE_STATE/askpass.log | tr '\n' ' ')\" = '198.18.0.21 bob 198.18.0.22 carol ' ] && cap two | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap two | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"

# (3) --pw-prompt on FF_HOSTS: one password for every target (only .21 needs it on the fake)
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun all "$(ans "$TPWD")" $RUN FF_SSH_USER=ops FF_HOSTS=198.18.0.21-23 $C --pw-prompt 1; rc=$?
chk "--pw-prompt with FF_HOSTS: one prompt for every ssh target, .21 authenticated as ops through askpass, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \$(nprompt all) = 1 ] && cap all | grep -q 'Password for every ssh target with no password of its own (--pw-prompt): ' && grep -qx '198.18.0.21 ops' $FAKE_STATE/askpass.log && cap all | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap all | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"

# (4) FF_PW_PROMPT=1 as a -t settings line: not refused as a credential name, and it asks
F=$(mk fl.csv 600 'FF_PW_PROMPT=1' 'backend,198.18.0.21-23')
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun fl "$(ans "$TPWD")" $RUN FF_SSH_USER=ops $C -t $F 1; rc=$?
chk "FF_PW_PROMPT=1 in the -t file: taken as a setting (not 'looks like a credential'), one prompt, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \$(nprompt fl) = 1 ] && ! cap fl | grep -q 'looks like a credential' && cap fl | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap fl | grep -E '^RESULT|ERROR|assword' | tr '\n' '|')"

# (5) a row's own password wins over --pw-prompt's
WN=$(mk win.csv 600 "backend,198.18.0.21,bob,$TPWD" 'backend,198.18.0.22' 'backend,198.18.0.23')
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun win "$(ans 'not-this-one')" $RUN FF_SSH_USER=ops $C --pw-prompt -t $WN 1; rc=$?
chk "--pw-prompt with a row password: the row's password is used for its host (the asked one would be refused), COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && grep -qx '198.18.0.21 bob' $FAKE_STATE/askpass.log && cap win | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap win | grep -E '^RESULT|ERROR' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"

# (6) no terminal (a new session, so /dev/tty can't open): stops before any ssh, rc 2
pwreset
out=$(xrun nt timeout 60 perl -MPOSIX -e 'my $p = fork; if ($p) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV or die "exec: $!"' $B $C -t $Q 1); rc=$?
chk "no terminal: rc 2, 'needs a terminal, and there is none', no ssh made (no logins.log)" \
    "[ $rc = 2 ] && grep -q 'ERROR: a password prompt (--pw-prompt, FF_PW_PROMPT=1 or a -t pw of ?) needs a terminal, and there is none' <<<\"\$out\" && [ ! -e $FAKE_STATE/logins.log ]" \
    "rc=$rc $(grep -E 'ERROR|RESULT' <<<"$out" | head -n 3) logins=[$(head -n 2 $FAKE_STATE/logins.log 2>&1)]"

# (7) an empty password, and end of input: rc 2, before any ssh
pwreset; prun em "$(ans '')" $C -t $Q 1; rc=$?
chk "empty password: rc 2 'empty password: Password for login bob', no ssh made" \
    "[ $rc = 2 ] && cap em | grep -q 'ERROR: empty password: Password for login bob\$' && [ ! -e $FAKE_STATE/logins.log ]" "rc=$rc $(cap em | grep -E 'ERROR|assword')"
pwreset; prun eof "$(ans '^D')" $C -t $Q 1; rc=$?
chk "end of input (^D): rc 2 'no password read (end of input)', no ssh made" \
    "[ $rc = 2 ] && cap eof | grep -q 'ERROR: no password read (end of input): Password for login bob\$' && [ ! -e $FAKE_STATE/logins.log ]" "rc=$rc $(cap eof | grep -E 'ERROR|assword')"

# (8) --list asks nothing, with --pw-prompt and a ? row
pwreset; prun ls "$(ans 'unused')" $C --pw-prompt --list -t $Q; rc=$?
chk "--pw-prompt --list -t (a ? row): no prompt, the 3 targets listed, rc 0, no ssh" \
    "[ $rc = 0 ] && [ \$(nprompt ls) = 0 ] && [ \"\$(cap ls | grep -c '^198\\.18\\.0\\.2[123]\$')\" = 3 ] && [ ! -e $FAKE_STATE/logins.log ]" "rc=$rc $(cap ls | head -n 6 | tr '\n' '|')"

# (9) only a pw of exactly ? asks: '?Pw x' is a password as written. Planted bug: '?'* asks for it
QP=$(mk qp.csv 600 'backend,198.18.0.21,bob,?Pw x' 'backend,198.18.0.22' 'backend,198.18.0.23')
pwreset; printf '%s' '?Pw x' > $FAKE_STATE/pw.198.18.0.21
prun qp "$(ans 'unused')" $RUN FF_SSH_USER=ops $C -t $QP 1; rc=$?
chk "a pw '?Pw x' is a password: no prompt, bob's host authenticated with it, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \$(nprompt qp) = 0 ] && grep -qx '198.18.0.21 bob' $FAKE_STATE/askpass.log && cap qp | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" "rc=$rc $(cap qp | grep -E '^RESULT|ERROR|assword' | tr '\n' '|')"
perl -pe "s/if \\[\\[ \\\$pw == '\\?' \\]\\]; then/if [[ \\\$pw == '?'* ]]; then/" $C > $W/x_glob.sh
pwreset; printf '%s' '?Pw x' > $FAKE_STATE/pw.198.18.0.21
prun qx "$(ans 'unused')" $RUN FF_SSH_USER=ops $W/x_glob.sh -t $QP 1; rc=$?
chk "planted bug (a pw starting with ? asks): one line changed, and the run is not COMPLETE" \
    "[ \$(diff $C $W/x_glob.sh | grep -c '^>') = 1 ] && ! cap qx | grep -q '^RESULT coverage=COMPLETE'" "$(diff $C $W/x_glob.sh | head -n 4) rc=$rc $(cap qx | grep -E '^RESULT|ERROR')"

# (10) FF_PW_PROMPT takes 0 or 1
out=$(xrun bv env FF_PW_PROMPT=2 timeout 30 $B $C -t $Q 1); rc=$?
chk "FF_PW_PROMPT=2: rc 2 'FF_PW_PROMPT must be 0 or 1, got '2''" "[ $rc = 2 ] && grep -q \"ERROR: FF_PW_PROMPT must be 0 or 1, got '2'\" <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR' <<<"$out")"

# (11) a bmc row with ?: its own prompt (per BMC user), the password to ipmitool through -f; the fake takes only
# bmcpw.<bmc> (no session otherwise) and logs each read that matched
BM=$(mk bm.csv 600 'backend,198.18.0.21-23' 'bmc,198.18.9.1,adm,?')
pwreset; rm -f $FAKE_STATE/bmcpw.*; printf '%s' "$BPW" > $FAKE_STATE/bmcpw.198.18.9.1
prun bm "$(ans "$BPW")" $RUN FF_SSH_USER=ops $C -t $BM 1; rc=$?
chk "bmc row with ?: one prompt 'BMC password for user adm', the BMC took it at every read (bmcpw.log >= 2 lines), lanplus readings in temps.txt, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \$(nprompt bm) = 1 ] && cap bm | grep -q 'BMC password for user adm (the -t bmc rows whose pw is ?): ' && [ \$(grep -cx '198.18.9.1 ok' $FAKE_STATE/bmcpw.log) -ge 2 ] && [ \$(bfile bm temps.txt | awk '\$2 == \"198.18.9.1\" && \$5 == \"lanplus\" && \$6 != \"none\"' | wc -l) -gt 0 ] && cap bm | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap bm | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') bmcpw=[$(sort $FAKE_STATE/bmcpw.log 2>&1 | uniq -c | tr '\n' ' ')] $(bfile bm temps.txt | awk '$2 == "198.18.9.1"' | head -n 2 | tr '\n' '|')"
rm -f $FAKE_STATE/bmcpw.*

# (12) --thermals-only --pw-prompt on FF_HOSTS: the thermals path takes the asked password too. Both hosts take it: a
# thermals login with a password runs ipmitool with sudo -S and it, with no escalator probe (as a row password does)
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21; printf "%s" "$TPWD" > $FAKE_STATE/pw.198.18.0.22
prun to "$(ans "$TPWD")" FF_SSH_USER=ops FF_HOSTS=198.18.0.21,198.18.0.22 FF_OUT_DIR=$W/to $C --thermals-only --pw-prompt; rc=$?
chk "--thermals-only --pw-prompt: one prompt, .21 authenticated as ops through askpass, RESULT data=COMPLETE hosts=2/2" \
    "[ $rc = 0 ] && [ \$(nprompt to) = 1 ] && grep -qx '198.18.0.21 ops' $FAKE_STATE/askpass.log && cap to | grep -q '^RESULT data=COMPLETE hosts=2/2'" \
    "rc=$rc $(cap to | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"

# (13) thermals_capture.sh beside the collector reads the same file the same way: a ? row asks (its run on the fabric
# fake, which also answers the reader); --pw-prompt ahead of -o is not read as getopts letters
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
TQ=$(mk tq.csv 600 'backend,198.18.0.21,bob,?' 'backend,198.18.0.22')
prun tq "$(ans "$TPWD")" FF_SSH_USER=ops FF_OUT_DIR=$W/tq $TC -t $TQ; rc=$?
chk "thermals_capture.sh -t with a ? row: one prompt for bob, authenticated through askpass, RESULT data=COMPLETE hosts=2/2" \
    "[ $rc = 0 ] && [ \$(nprompt tq) = 1 ] && grep -qx '198.18.0.21 bob' $FAKE_STATE/askpass.log && cap tq | grep -q '^RESULT data=COMPLETE hosts=2/2'" \
    "rc=$rc $(cap tq | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21; printf "%s" "$TPWD" > $FAKE_STATE/pw.198.18.0.22
prun tp "$(ans "$TPWD")" FF_SSH_USER=ops FF_HOSTS=198.18.0.21,198.18.0.22 FF_OUT_DIR=$W/tp $TC --pw-prompt -o jsonl; rc=$?
chk "thermals_capture.sh --pw-prompt -o jsonl (FF_HOSTS): one prompt, .21 as ops through askpass, data=COMPLETE hosts=2/2, one .jsonl written" \
    "[ $rc = 0 ] && [ \$(nprompt tp) = 1 ] && grep -qx '198.18.0.21 ops' $FAKE_STATE/askpass.log && cap tp | grep -q '^RESULT data=COMPLETE hosts=2/2' && [ \$(ls $W/tp | grep -c '^thermcap_.*\\.jsonl\$') = 1 ]" \
    "rc=$rc $(cap tp | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') files=[$(ls $W/tp 2>&1 | tr '\n' ' ')]"

# (14) a credential row with ? (the glob branch): *,*,bob,? gives every target bob's asked password
WC=$(mk wc.csv 600 '198.18.0.21-23' '*,*,bob,?')
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun wc "$(ans "$TPWD")" $RUN FF_SSH_USER=ops $C -t $WC 1; rc=$?
chk "credential row *,*,bob,?: one prompt for bob, .21 authenticated as bob through askpass, COMPLETE hosts=3/3" \
    "[ $rc = 0 ] && [ \$(nprompt wc) = 1 ] && cap wc | grep -q 'Password for login bob (the -t rows whose pw is ?): ' && grep -qx '198.18.0.21 bob' $FAKE_STATE/askpass.log && cap wc | grep -q '^RESULT coverage=COMPLETE hosts=3/3'" \
    "rc=$rc $(cap wc | grep -E '^RESULT|ERROR|assword' | tr '\n' '|') askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"

# (15) pinned as chosen: a thermals login with an asked password reads the BMC with sudo -S and that password (no
# escalator probe, as a row password does); a host whose sudo refuses it has no BMC data, with that reason
pwreset; printf '%s' "$TPWD" > $FAKE_STATE/pw.198.18.0.21
prun tr "$(ans "$TPWD")" FF_SSH_USER=ops FF_HOSTS=198.18.0.21,198.18.0.22 FF_OUT_DIR=$W/tr $TC --pw-prompt; rc=$?
chk "thermals --pw-prompt, .22's sudo refuses the password: rc 3, 'NO TEMPERATURE DATA: h22 ipmi (sudo_refused...', data=PARTIAL hosts=2/2 nodata=1 (control: (13)'s run, where .22 takes it, is COMPLETE)" \
    "[ $rc = 3 ] && cap tr | grep -q 'NO TEMPERATURE DATA: h22 ipmi (sudo_refused' && cap tr | grep -q '^RESULT data=PARTIAL hosts=2/2 .*nodata=1'" "rc=$rc $(cap tr | grep -E '^RESULT|ERROR|NO TEMP' | tr '\n' '|')"

# (16) the prompt is shown by read -rs -p, which turns echo off first; a printf of the prompt before read -s left a
# window where a password typed at once was echoed (17 of 60 expect runs under CPU load on a23ad0d; 0 of 60 with -p).
# The race needs load to show, so this pins the shape in both built tools (control: a23ad0d's printf form fails it)
pwshape() { awk '/^pw_prompts\(\) \{/ {f = 1} f {print} f && /^}/ {exit}' "$1"; }
chk "both tools show the prompt with read -rs -p \"\$label\" from /dev/tty, never a printf of it first (control: 2 pw_prompts bodies found)" \
    "[ \$(cat <(pwshape $C) <(pwshape $TC) | grep -c '^pw_prompts() {') = 2 ] && [ \$(cat <(pwshape $C) <(pwshape $TC) | grep -cF 'read -rs -p \"\$label\" pw < /dev/tty 2> /dev/tty') = 2 ] && ! cat <(pwshape $C) <(pwshape $TC) | grep -qF '\"\$label\" > /dev/tty'" \
    "$(pwshape $C | grep -nE 'label|read ')"
finish
