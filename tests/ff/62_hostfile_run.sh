#!/opt/homebrew/bin/bash
# fabric_ferret.sh -t end to end (slice 3): a backend CIDR and two named clients, one of them unreachable. The range
# flag is kept per type, so the backend range must not make the dead client look normal: it counts as missing.
# checks: 24
# secs: 55
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
# two bmc lines: 198.18.9.1 answers (fake/ipmitool), 198.18.9.2 is a dead BMC (FAKE_BMC_DOWN: no lanplus session, rc 1)
printf '%s\n' 'backend,198.18.0.20/30' 'client,198.18.1.1' 'client,198.18.1.5' 'bmc,198.18.9.1' 'bmc,198.18.9.2' > $W/t.csv; chmod 600 $W/t.csv
TF="FF_CLIENT_NETS=198.19.10.0/24,198.19.11.0/24 FF_ITER=1 FF_UDP=0"
out=$(xrun tf env $TF FAKE_BMC_DOWN=198.18.9.2 timeout 240 $B $C -t $W/t.csv); rc=$?
chk "-t run: backends from the CIDR (.21 .22) and client c1 tested; 198.18.1.5 unreachable" "grep -qE '^RESULT coverage=PARTIAL hosts=2/2 .*clients=1/2' <<<\"\$out\"" "rc=$rc $(grep -E '^RESULT|unreachable' <<<"$out" | head -n 3)"
chk "-t run: rc 3 (a client missing makes the coverage PARTIAL), the 2 bmc lines read out of band and said; temps.txt holds 198.18.9.1's lanplus rows at iter1_pre and end (the fake ipmitool's Inlet_Temp), typed inlet in the summary; 0 'skipped' lines (control: 'read out of band' counted 1)" "[ $rc = 3 ] && grep -q -- '-t: 2 bmc line(s) read out of band (ipmitool -I lanplus)' <<<\"\$out\" && [ \"\$(bfile tf temps.txt | awk '\$2 == \"198.18.9.1\" && \$5 == \"lanplus\" && \$6 == \"Inlet_Temp\" {print \$1}' | sort | tr '\n' ' ')\" = 'end iter1_pre ' ] && bfile tf temps_summary.txt | awk '\$1 == \"198.18.9.1\" && \$3 == \"inlet\" && \$6 == \"Inlet_Temp\" {f = 1} END {exit !f}' && [ \$(grep -c 'bmc line(s) skipped' <<<\"\$out\") = 0 ] && [ \$(grep -c 'bmc line(s) read out of band' <<<\"\$out\") = 1 ]" "rc=$rc $(bfile tf temps.txt | awk '$2 == "198.18.9.1"' | tr '\n' '|')"
# a dead BMC (gap 2 of COVERAGE.md): its two reads give one none row each with the session failure as the reason, no
# reading, the summary carries it as nodata and the log says NO TEMPERATURE DATA for it; the live BMC's rows above are
# the control in the same run, and the fake logged exactly one lanplus call per BMC per read (2 BMCs x 2 reads)
chk "-t run: dead BMC 198.18.9.2 (no lanplus session): temps.txt has a none row at iter1_pre and end with the reason (rc=1_Error:_Unable_to_establish...), 0 reading rows; summary nodata row; 'NO TEMPERATURE DATA: 198.18.9.2 ipmi' logged; 4 lanplus calls logged (2 BMCs x 2 reads)" \
    "[ \"\$(bfile tf temps.txt | awk '\$2 == \"198.18.9.2\" && \$5 == \"lanplus\" && \$6 == \"none\" && \$10 ~ /^rc=1_Error:_Unable_to_establish/ {print \$1}' | sort | tr '\n' ' ')\" = 'end iter1_pre ' ] && [ \$(bfile tf temps.txt | awk '\$2 == \"198.18.9.2\" && \$6 != \"none\"' | wc -l) = 0 ] && [ \$(bfile tf temps.txt | awk '\$2 == \"198.18.9.1\" && \$6 != \"none\"' | wc -l) -gt 0 ] && bfile tf temps_summary.txt | awk '\$1 == \"198.18.9.2\" && \$2 == \"ipmi\" && \$12 ~ /^nodata:/ {f = 1} END {exit !f}' && grep -q 'NO TEMPERATURE DATA: 198.18.9.2 ipmi' <<<\"\$out\" && [ \$(grep -c '^ipmitool -I lanplus -H 198.18.9.[12] ' $FAKE_STATE/ipmi_calls.log) = 4 ]" \
    "$(bfile tf temps.txt | awk '$2 == "198.18.9.2"' | tr '\n' '|') | summary: $(bfile tf temps_summary.txt | awk '$1 == "198.18.9.2"') | calls: $(cat $FAKE_STATE/ipmi_calls.log 2>&1 | tr '\n' '|')"
# planted bug: the client count judged by the backends' range flag (the file-wide flag)
perl -pe 's/CL_RANGES=\$\{HF_RANGES\[client\]\}/CL_RANGES=\$\{HF_RANGES[backend]\}/' $C > $W/x_ranges.sh
out=$(xrun tx env $TF timeout 240 $B $W/x_ranges.sh -t $W/t.csv); rc=$?
chk "planted bug (one range flag for the file): the dead client looks normal (clients=1/1, not 1/2)" "[ \$(diff $C $W/x_ranges.sh | grep -c '^>') = 1 ] && grep -qE '^RESULT .*clients=1/1' <<<\"\$out\"" "$(diff $C $W/x_ranges.sh) rc=$rc $(grep '^RESULT' <<<"$out")"
# the same file as FF_HOSTS/FF_CLIENTS gives the same verdict (control: -t only changes where the targets come from)
out=$(xrun fh env $TF FF_HOSTS=198.18.0.20/30 FF_CLIENTS=198.18.1.1,198.18.1.5 timeout 240 $B $C); rc=$?
chk "control: FF_HOSTS=198.18.0.20/30 FF_CLIENTS=198.18.1.1,198.18.1.5 gives the same clients=1/2" "[ $rc = 3 ] && grep -qE '^RESULT coverage=PARTIAL hosts=2/2 .*clients=1/2' <<<\"\$out\"" "rc=$rc $(grep '^RESULT' <<<"$out")"
# --- a login per row (slice 4): .21 accepts only alice, .22 only FF_SSH_USER=ops; each call carries its target's login ---
printf '%s\n' 'backend,198.18.0.21,alice' 'backend,198.18.0.22' 'backend,198.18.0.23' > $W/l.csv; chmod 600 $W/l.csv
LG="FAKE_LOGIN=198.18.0.21:alice"
rm -f "${FAKE_STATE:?}/logins.log"   # the earlier runs' lines out: this run's logins only
out=$(xrun lg env "$LG" FF_SSH_USER=ops FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/l.csv); rc=$?
chk "logins per row: .21 as alice, .22 and .23 as FF_SSH_USER (ops), every call; COMPLETE" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && [ \"\$(sort -u $FAKE_STATE/logins.log | tr '\n' '|')\" = '198.18.0.21 alice|198.18.0.22 ops|198.18.0.23 ops|' ]" "rc=$rc $(grep '^RESULT' <<<"$out") $(sort $FAKE_STATE/logins.log | uniq -c | tr '\n' '|')"
perl -pe 's/ -l "\$\{TL\[\$t\]:-\$FF_SSH_USER\}"//' $C > $W/x_login.sh
out=$(xrun lx env "$LG" FF_SSH_USER=ops FF_ITER=2 FF_UDP=0 timeout 240 $B $W/x_login.sh -t $W/l.csv); rc=$?
# 6 ssh sites carry -l since commit 1's rlogin_bash (the reader as the login); 5 before it
chk "planted bug (no -l per call, 6 sites changed): alice's host refuses the default login, hosts 2/3" "[ \$(diff $C $W/x_login.sh | grep -c '^>') = 6 ] && grep -qE '^RESULT .*hosts=2/3' <<<\"\$out\"" "$(diff $C $W/x_login.sh | head -n 4) rc=$rc $(grep '^RESULT' <<<"$out")"
out=$(xrun ld env "FAKE_LOGIN=198.18.0.21:nobody 198.18.0.22:nobody 198.18.0.23:nobody" FF_SSH_USER=ops FF_ITER=1 timeout 120 $B $C -t $W/l.csv); rc=$?
chk "nobody answers: the stop names the logins tried (alice ops)" "[ $rc != 0 ] && grep -q 'no target answered ssh (logins tried: alice ops)' <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR|RESULT' <<<"$out")"
# --- a password per row (slice 4): read once where the ssh master opens, through the askpass fifo ---
# lib.sh's single-letter globals a group must not shadow: C P (collector, parser: render() runs python3 $P), S B H G W d O
TPWD='Pw,with spaces!9'   # the row password (was P, which shadowed the parser path and broke render(); 10-29 15:42)
printf '%s\n' "backend,198.18.0.21,bob,$TPWD" 'backend,198.18.0.22' 'backend,198.18.0.23' > $W/p.csv; chmod 600 $W/p.csv
pwsetup() { rm -f "${FAKE_STATE:?}"/authed.* "${FAKE_STATE:?}/askpass.log" "${FAKE_STATE:?}/pwenv.log"; printf '%s' "$TPWD" > "$FAKE_STATE/pw.198.18.0.21"; }
pwsetup
out=$(xrun pw env FF_SSH_USER=ops FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/p.csv); rc=$?
chk "row password: bob's host authenticates once (one askpass, at the sweep), COMPLETE hosts=3/3" "[ $rc = 0 ] && grep -qE '^RESULT coverage=COMPLETE hosts=3/3' <<<\"\$out\" && [ \"\$(cat $FAKE_STATE/askpass.log)\" = '198.18.0.21 bob' ]" "rc=$rc $(grep '^RESULT' <<<"$out") askpass=[$(cat $FAKE_STATE/askpass.log 2>&1)]"
leak=$( { printf '%s\n' "$out"; tar xzOf "$(bundle pw)" 2>&1; cat $FAKE_STATE/logins.log; } | grep -cF -- "$TPWD")
chk "row password: in no environment (fake: no pwenv), not in the output, the bundle or any argv the fake logged" "[ ! -e $FAKE_STATE/pwenv.log ] && [ $leak = 0 ] && grep -qF -- \"\$TPWD\" $W/p.csv" "pwenv=[$(cat $FAKE_STATE/pwenv.log 2>&1)] leak=$leak"
# planted bugs: the sweep without the password path (BatchMode=yes only); the password exported to ssh's environment
perl -pe 's/^(\s+)\[\[ -n \$\{TPW\[\$t\]\+x\} \]\] \|\| \{ rsh "\$t" "\$\@"; return; \}$/$1rsh "\$t" "\$\@"; return/' $C > $W/x_sweep.sh
pwsetup; out=$(xrun px env FF_SSH_USER=ops FF_ITER=2 FF_UDP=0 timeout 240 $B $W/x_sweep.sh -t $W/p.csv); rc=$?
chk "planted bug (no password at the sweep): bob's host refuses, hosts 2/3" "[ \$(diff $C $W/x_sweep.sh | grep -c '^>') = 1 ] && grep -qE '^RESULT .*hosts=2/3' <<<\"\$out\"" "$(diff $C $W/x_sweep.sh) rc=$rc $(grep '^RESULT' <<<"$out")"
perl -pe 's/^(\s+)pwfifo "s\.\$BASHPID" "\$\{TPW\[\$t\]\}" \|\| return 255$/$1export FF_LEAK=\${TPW[\$t]}; pwfifo "s.\$BASHPID" "\${TPW[\$t]}" || return 255/' $C > $W/x_env.sh
pwsetup; out=$(xrun pe env FF_SSH_USER=ops FF_ITER=2 FF_UDP=0 timeout 240 $B $W/x_env.sh -t $W/p.csv); rc=$?
chk "planted bug (the password exported): the fake logs pwenv" "[ \$(diff $C $W/x_env.sh | grep -c '^>') = 1 ] && grep -qx '198.18.0.21 FF_LEAK' $FAKE_STATE/pwenv.log" "$(diff $C $W/x_env.sh) pwenv=[$(cat $FAKE_STATE/pwenv.log 2>&1)]"
rm -f "${FAKE_STATE:?}/pw.198.18.0.21"

# --- root on each host its own way (slice 4): root login, a key user with dzdo, a password user (sudo -S -k), one with
# no escalator (unusable: answered ssh, can't run the steps, counted as missing) ---
printf '%s\n' 'backend,198.18.0.21,root' 'backend,198.18.0.22,kim' "backend,198.18.0.23,pat,$TPWD" 'backend,198.18.0.24,lee' > $W/e.csv; chmod 600 $W/e.csv
esetup() { rm -f "${FAKE_STATE:?}"/authed.* "${FAKE_STATE:?}"/{askpass,pwenv,esc,probe,reader}.log; printf '%s' "$TPWD" > "$FAKE_STATE/pw.198.18.0.23"; }
EV="FAKE_ESC=198.18.0.22:dzdo_-n 198.18.0.23:none 198.18.0.24:none"   # .23: no passwordless escalator, so its password is used
# FF_IPMI_TIMEOUT=7: the reader's second argument, so the caller-contract checks below see a value only the setting gives
esetup; out=$(xrun es env "$EV" FF_IPMI_TIMEOUT=7 FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/e.csv); rc=$?
chk "escalation: .21 root (none), .22 dzdo -n, .23 sudo -S -k with its password; .24 unusable: PARTIAL hosts=3/4" "[ $rc = 3 ] && grep -qE '^RESULT coverage=PARTIAL hosts=3/4' <<<\"\$out\" && [ \"\$(cut -d' ' -f1,3- $FAKE_STATE/esc.log | sort -u | tr '\n' '|')\" = \"198.18.0.22 dzdo -n|198.18.0.23 sudo -S -k -p ''|\" ]" "rc=$rc $(grep '^RESULT' <<<"$out") esc=[$(sort -u $FAKE_STATE/esc.log | tr '\n' '|')]"
chk "escalation: the unusable host is said, with its reason, login and uid, and is in the bundle's unusable.txt" "grep -q '1 of 4 targets answered ssh but can.t run the remote steps as root' <<<\"\$out\" && grep -q '198.18.0.24 no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo (login lee, uid 1000)' <<<\"\$out\" && tar xzOf \"\$(bundle es)\" --include='*/unusable.txt' | grep -q '^198.18.0.24 no_passwordless'" "$(grep -A2 'answered ssh but' <<<"$out")"
chk "escalation: one probe per host per run (the sweep), the password host probed like any other" "[ \"\$(sort $FAKE_STATE/probe.log | tr '\n' '|')\" = '198.18.0.21 root probe|198.18.0.22 kim probe|198.18.0.23 pat probe|198.18.0.24 lee probe|' ]" "$(sort $FAKE_STATE/probe.log | uniq -c | tr '\n' '|')"
leak=$( { printf '%s\n' "$out"; tar xzOf "$(bundle es)" 2>&1; cat $FAKE_STATE/esc.log $FAKE_STATE/logins.log; } | grep -cF -- "$TPWD")
chk "escalation: the sudo -S password in no output, bundle, logged argv or environment" "[ $leak = 0 ] && [ ! -e $FAKE_STATE/pwenv.log ]" "leak=$leak pwenv=[$(cat $FAKE_STATE/pwenv.log 2>&1)]"
# --- the temperature reader's caller contract (10-29 12:52 / 15:32: the reader runs as the login, thermals'
# conventions): fake/ssh writes reader.log, one line per reader call, "target login priv=y|n argv=... stdin=script|tcpw_ok|
# tcpw_bad" (priv=y = an escalator prefix was in front of the command; tcpw = the "IFS= read -r TC_PW" line and the
# password came first on stdin). (a) as the login, no prefix; (b) argv = mode, FF_IPMI_TIMEOUT, and the sweep's escalator
# as a third argument only where it found one; (c) the password host's stream; (d) the host unusable for the tests
# (lee: uid 1000, no escalator, no password) is still read, "temperatures only", and stays out of the coverage ---
# .24 (no escalator found): argument 3 is "none", so the reader skips its own probe (the PM's contract 15:40; left open at 15:32)
# mode: ipmi at iteration start and at the end (the BMC), '-' (hwmon and GPUs only) after every phase: both per host
chk "reader as the login (a, b): reader.log sorted -u = 8 lines, modes '-' and ipmi per host: .21 root (no argument 3), .22 kim with dzdo_-n as argument 3, .23 pat (none: the password path), .24 lee with 'none'; every call priv=n, timeout 7, stdin=script but .23's tcpw_ok; controls: a planted priv=y line counts 1 among 0 real, a planted no-argument-3 lee line counts 1 among 0 real, and esc.log shows the tests' own commands took dzdo on .22" \
    "[ \"\$(sort -u $FAKE_STATE/reader.log | tr '\n' '|')\" = '198.18.0.21 root priv=n argv=- 7 stdin=script|198.18.0.21 root priv=n argv=ipmi 7 stdin=script|198.18.0.22 kim priv=n argv=- 7 dzdo_-n stdin=script|198.18.0.22 kim priv=n argv=ipmi 7 dzdo_-n stdin=script|198.18.0.23 pat priv=n argv=- 7 stdin=tcpw_ok|198.18.0.23 pat priv=n argv=ipmi 7 stdin=tcpw_ok|198.18.0.24 lee priv=n argv=- 7 none stdin=script|198.18.0.24 lee priv=n argv=ipmi 7 none stdin=script|' ] && [ \$({ cat $FAKE_STATE/reader.log; echo '198.18.0.24 lee priv=n argv=ipmi 7 stdin=script'; } | grep -c '^198.18.0.24 lee priv=n argv=ipmi 7 stdin') = 1 ] && [ \$({ cat $FAKE_STATE/reader.log; echo 'px x priv=y argv=ipmi 7 stdin=script'; } | grep -c 'priv=y') = 1 ] && grep -q '^198.18.0.22 kim dzdo -n' $FAKE_STATE/esc.log" \
    "$(sort $FAKE_STATE/reader.log 2>&1 | uniq -c | tr '\n' '|')"
chk "password host (c): .23's reader calls carry tcpw_ok (at least 2: the first and the last read) and 0 tcpw_bad; the password in no reader argv, no environment (no pwenv.log), not in the output, bundle or logged argv (leak 0); controls: a planted tcpw_bad line counts 1, and the password is in e.csv" \
    "[ \$(grep -c '^198.18.0.23 pat .*stdin=tcpw_ok\$' $FAKE_STATE/reader.log) -ge 2 ] && [ \$(grep -c tcpw_bad $FAKE_STATE/reader.log) = 0 ] && [ \$({ cat $FAKE_STATE/reader.log; echo 'px x priv=n argv=ipmi 7 stdin=tcpw_bad'; } | grep -c tcpw_bad) = 1 ] && [ \$(grep -cF -- \"\$TPWD\" $FAKE_STATE/reader.log) = 0 ] && [ ! -e $FAKE_STATE/pwenv.log ] && [ $leak = 0 ] && grep -qF -- \"\$TPWD\" $W/e.csv" \
    "$(grep '^198.18.0.23' $FAKE_STATE/reader.log 2>&1 | sort | uniq -c | tr '\n' '|')"
chk "temperatures only (d): h24 (lee, unusable for the tests) has hwmon reading rows in temps.txt at iter1_pre and end, an ipmi none row with the no-escalator reason, a summary row (hwmon cpu); the bundle member temps_only.txt is exactly 'h24'; the log line 'Temperatures only (no root for the tests):' names it; RESULT still hosts=3/4; control: h23 (tested) is not on that line" \
    "[ \$(bfile es temps.txt | awk '\$2 == \"h24\" && \$3 == \"hwmon\" && \$6 != \"none\" {print \$1}' | sort -u | grep -c -x -e iter1_pre -e end) = 2 ] && [ \$(bfile es temps.txt | awk '\$2 == \"h24\" && \$3 == \"ipmi\" && \$6 == \"none\" && \$10 ~ /^no_passwordless_escalator/' | wc -l) -ge 1 ] && [ \$(bfile es temps_summary.txt | awk '\$1 == \"h24\" && \$2 == \"hwmon\" && \$3 == \"cpu\"' | wc -l) = 1 ] && [ \"\$(bfile es temps_only.txt)\" = h24 ] && grep -qE '^ *Temperatures only \(no root for the tests\): .*(h24|198\.18\.0\.24)' <<<\"\$out\" && ! grep -E '^ *Temperatures only' <<<\"\$out\" | grep -qE 'h23|198\.18\.0\.23' && grep -qE '^RESULT coverage=PARTIAL hosts=3/4' <<<\"\$out\"" \
    "$(bfile es temps.txt | awk '$2 == "h24"' | head -n 4 | tr '\n' '|') | summary: $(bfile es temps_summary.txt | awk '$1 == "h24"' | tr '\n' '|') | temps_only: $(bfile es temps_only.txt | tr '\n' ' ') | $(grep '^ *Temperatures only' <<<"$out")"
render es; rrc=$?
chk "dashboard (d): the page carries a 'temperatures only' note naming h24 and not h23 (render rc 0 or 3); control: a planted note line naming h23 counts 1" \
    "{ [ $rrc = 0 ] || [ $rrc = 3 ]; } && grep -q -i 'temperatures only[^<]*h24' $W/es.html && ! grep -q -i 'temperatures only[^<]*h23' $W/es.html && [ \$({ cat $W/es.html; echo 'temperatures only: h23'; } | grep -c -i 'temperatures only[^<]*h23') = 1 ]" \
    "rc=$rrc note=[$(grep -o -i 'temperatures only[^<]*' $W/es.html | tr '\n' '|')] $(tail -n 2 $W/es.pout)"
# (e) a TESC=S host with no password in memory (rroot's return 3) happens only after main crashed and lost TPW: this
# group cannot stage a restart mid-run, so it is not tested here (the rroot return is covered by 61's teardown check)
# precedence: a password login whose host has a passwordless escalator uses that, never sudo -S (the password stays home)
esetup; out=$(xrun ep env "FAKE_ESC=198.18.0.22:dzdo_-n 198.18.0.23:dzdo_-n 198.18.0.24:none" FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/e.csv); rc=$?
chk "precedence: pat's host has dzdo -n: it is used, sudo -S never runs" "grep -qE '^RESULT .*hosts=3/4' <<<\"\$out\" && grep -q '^198.18.0.23 pat dzdo -n' $FAKE_STATE/esc.log && ! grep -q 'sudo -S' $FAKE_STATE/esc.log" "$(sort -u $FAKE_STATE/esc.log | tr '\n' '|')"
# sudoers NOPASSWD: sudo -S takes nothing from the stream. The guard reads the password line away, so nothing runs it
esetup; out=$(xrun en env "$EV" FAKE_NOPASSWD=198.18.0.23 FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/e.csv); rc=$?
leak=$( { printf '%s\n' "$out"; tar xzOf "$(bundle en)" 2>&1; cat $FAKE_STATE/esc.log; } | grep -cF -- "$TPWD")
chk "NOPASSWD sudo (takes no password): the guard skips to the sentinel; no password in the output, ssh_errors.log, run.log or any bundle member; hosts=3/4" "[ $leak = 0 ] && grep -qE '^RESULT .*hosts=3/4' <<<\"\$out\" && tar tzf \"\$(bundle en)\" | grep -q 'ssh_errors.log' && grep -q '^198.18.0.23 pat sudo -S -k' $FAKE_STATE/esc.log" "leak=$leak $(grep '^RESULT' <<<"$out")"
# planted control: the pre-fix stream (no guard: sudo -S -k ... bash -s straight) under NOPASSWD runs the password as a command
perl -pe 's/"\$\{PRIV\[@\]\}" bash -c "\$\(sudo_guard .bash -s -- "\$@".\)" ff-sudo -- "\$@"$/"\${PRIV[@]}" bash -s -- "\$@"/' $C > $W/x_guard.sh
esetup; out=$(xrun eg env "$EV" FAKE_NOPASSWD=198.18.0.23 FF_ITER=2 FF_UDP=0 timeout 240 $B $W/x_guard.sh -t $W/e.csv); rc=$?
leak=$( { printf '%s\n' "$out"; tar xzOf "$(bundle eg)" 2>&1; } | grep -cF -- "$TPWD")
chk "planted control (no guard, the pre-fix stream) under NOPASSWD: bash runs the password line, and it lands in ssh_errors.log" "[ \$(diff $C $W/x_guard.sh | grep -c '^>') = 1 ] && [ $leak -gt 0 ] && tar xzOf \"\$(bundle eg)\" --include='*/ssh_errors.log' | grep -qF -- \"\$TPWD\"" "$(diff $C $W/x_guard.sh) leak=$leak"
# a cached sudo timestamp with -k (the real code): sudo still asks; with the guard the outcome is the same either way
esetup; out=$(xrun ec env "$EV" FAKE_SUDO_CACHED=1 FF_ITER=2 FF_UDP=0 timeout 240 $B $C -t $W/e.csv); rc=$?
leak=$( { printf '%s\n' "$out"; tar xzOf "$(bundle ec)" 2>&1; } | grep -cF -- "$TPWD")
chk "control: a cached sudo timestamp, no leak and hosts=3/4" "[ $leak = 0 ] && grep -qE '^RESULT .*hosts=3/4' <<<\"\$out\"" "leak=$leak $(grep '^RESULT' <<<"$out")"
rm -f "${FAKE_STATE:?}/pw.198.18.0.23"
finish
