#!/opt/homebrew/bin/bash
# bash 4.3+ (declare -gA in td): checked first, in bash 3 syntax (10-26 20:04)
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } || {
    echo "61_hostfile_ff.sh: needs bash 4.3+ (this is bash $BASH_VERSION)" >&2; exit 2; }
# fabric_ferret.sh -t FILE (slice 3): types split into backends and clients, bmc lines read out of band, one login only, the
# argument loop, and the refusals; all through --list (no ssh). The run that judges coverage per type is in 62.
# tier: fast
# checks: 49
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
mk() { local f=$W/$1; shift; printf '%s\n' "$@" > "$f"; chmod 600 "$f"; echo "$f"; }   # mk <name> <line>...: a 600 file
# ls_ <script> [VAR=...]... args: the script run from $W with FF_HOSTS/FF_CLIENTS unset, stdout and stderr together
ls_() { local c=$1; shift; local -a ev=(); while [[ $1 == *=* ]]; do ev+=("$1"); shift; done
        ( cd $W && env -u FF_HOSTS -u FF_CLIENTS "${ev[@]}" $B "$c" "$@" 2>&1 ); }

# --- the repository's example file (hostlist.example.csv, 10-27): 23 backends (a /28 = 14, a range of 8, one
# named host), 64 clients (a /26 = 62, two named), one bmc row read out of band, both credential rows matched, no warning ---
ex=$(dirname "$C")/hostlist.example.csv
o=$(ls_ $C --list -t "$ex"); rc=$?
chk "hostlist.example.csv: 23 targets, 64 client targets, 1 bmc line skipped, no WARNING, no ERROR" \
    "[ $rc = 0 ] && grep -qx '# 23 targets' <<<\"\$o\" && grep -qx '# 64 client targets' <<<\"\$o\" && grep -qx '# -t: 1 bmc line(s) read out of band (ipmitool -I lanplus)' <<<\"\$o\" && ! grep -qE 'WARNING|ERROR' <<<\"\$o\" && grep -qx 'storage-09' <<<\"\$o\" && grep -qx 'client gpu-node-02' <<<\"\$o\"" "rc=$rc $(grep '^#' <<<"$o" | tr '\n' '|')"

# --- settings lines (10-27, step 2): FF_NAME=value as the whole line; the environment wins; thermals_capture.sh's
# names skipped and named; unknown, credential-looking or FF_HOSTS lines stop the run by line number, value unprinted ---
f=$(mk sl 'FF_MAX_TARGETS=2' 'backend,198.18.0.0/28')
o=$(ls_ $C --list -t $f); rc=$?
chk "settings line: FF_MAX_TARGETS=2 from the file applies (a /28 row is refused against it, by line number)" "[ $rc = 2 ] && grep -q \"^ERROR: -t $f line 2: the entry adds 14 targets, past FF_MAX_TARGETS=2\" <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C FF_MAX_TARGETS=100 --list -t $f); rc=$?
chk "settings line: the environment wins (FF_MAX_TARGETS=100 exported: 14 targets, the file's line named as ignored)" "[ $rc = 0 ] && grep -qx '# 14 targets' <<<\"\$o\" && grep -qx \"# -t $f line 1: FF_MAX_TARGETS is set in the environment; the file's value is ignored\" <<<\"\$o\"" "rc=$rc $(grep '^#' <<<"$o" | tr '\n' '|')"
# since 10dee6c every thermals_capture.sh setting (TC_KNOWN) is one fabric_ferret.sh reads too, so the "skipped for
# thermals_capture.sh" path has no name to take: a FF_PROCFS line is read, not skipped. If a thermals-only name ever
# returns, this check says so (the set below), and the skip line needs its test back (the old FF_PROCFS example, 10-28)
f=$(mk so 'FF_PROCFS=/x' 'backend,198.18.0.1')
o=$(ls_ $C --list -t $f); rc=$?
tconly=$(comm -23 <(sed -n 's/^TC_KNOWN="\(.*\)"$/\1/p' $C | tr ' ' '\n' | sort -u) <(sed -n 's/^FF_KNOWN="\(.*\)"$/\1/p' $C | tr ' ' '\n' | sort -u) | tr '\n' ' ')
chk "settings line: 0 thermals-only names (TC_KNOWN minus FF_KNOWN is empty; control: FF-only names >= 30), so a FF_PROCFS line is read: 0 'skipped' lines (a planted one counts 1), rc 0, the run goes on" "[ $rc = 0 ] && [ -z \"$tconly\" ] && [ \$(comm -13 <(sed -n 's/^TC_KNOWN=\"\\(.*\\)\"\$/\\1/p' $C | tr ' ' '\\n' | sort -u) <(sed -n 's/^FF_KNOWN=\"\\(.*\\)\"\$/\\1/p' $C | tr ' ' '\\n' | sort -u) | wc -l) -ge 30 ] && [ \$(grep -c 'setting line(s) for thermals_capture.sh skipped' <<<\"\$o\") = 0 ] && [ \$({ printf '%s\n' \"\$o\"; echo '# -t x: 1 setting line(s) for thermals_capture.sh skipped: FF_X'; } | grep -c 'setting line(s) for thermals_capture.sh skipped') = 1 ] && grep -qx '198.18.0.1' <<<\"\$o\"" "rc=$rc tc-only=[$tconly] $o"
for bad in "FF_FOO=secretvalue|line 2: unknown setting FF_FOO; this tool reads: FF_BUSY_CHECK, " "FF_SSH_PASSWORD=hunter2|line 2: FF_SSH_PASSWORD looks like a credential; a password goes in a row's pw field, never in a setting" "FF_SSH_PASSWORD = hunter3|line 2: FF_SSH_PASSWORD looks like a credential" "FF_HOSTS=198.18.0.9|line 2: FF_HOSTS is not a setting here; list the targets as rows" "FF_MAX_TARGETS=abc|line 2: FF_MAX_TARGETS must be a positive integer\$"; do
    l=${bad%%|*}; m=${bad#*|}; v=${l#*=}
    o=$(ls_ $C --list -t "$(mk sb 'backend,198.18.0.1' "$l")"); rc=$?
    chk "settings line refused by line number, value never printed: ${l%%=*}" "[ $rc = 2 ] && grep -q \"^ERROR: -t .* $m\" <<<\"\$o\" && ! grep -q \"$v\" <<<\"\$o\"" "rc=$rc $o"
done
# The file's settings lines are read first and exported (10-28), so FF_FERRET and FF_VIEWER work from the file
# and a child (the viewer) sees every value: the stand-in viewer (fixtures/units/env_viewer.sh) prints its environment's
# FF_FERRET and FF_SSH_USER; the same file without the settings lines starts no viewer
f=$(mk sf 'backend,198.18.0.1' 'backend,198.18.0.2' 'FF_FERRET=1' "FF_VIEWER=$S/fixtures/units/env_viewer.sh" 'FF_SSH_USER=u1'); o=$(ls_ $C --list -t "$f"); rc=$?
chk "settings lines FF_FERRET=1, FF_VIEWER=<stand-in>, FF_SSH_USER=u1 from the file: the stand-in runs and prints FF_FERRET=1 FF_SSH_USER=u1 (exported), rc 0, both targets listed" \
    "[ $rc = 0 ] && [ \$(grep -c '^# viewer sees FF_FERRET=1 FF_SSH_USER=u1\$' <<<\"\$o\") = 1 ] && grep -qx '198.18.0.1' <<<\"\$o\" && grep -qx '198.18.0.2' <<<\"\$o\"" "rc=$rc $o"
f2=$(mk sf2 'backend,198.18.0.1' 'backend,198.18.0.2'); o2=$(ls_ $C --list -t "$f2"); rc2=$?
chk "control: the same file without the settings lines starts no viewer (0 'viewer sees' lines; 1 above), lists its two targets" "[ $rc2 = 0 ] && [ \$(grep -c 'viewer sees' <<<\"\$o2\") = 0 ] && grep -qx '198.18.0.1' <<<\"\$o2\" && grep -qx '198.18.0.2' <<<\"\$o2\"" "rc=$rc2 $o2"
o=$(ls_ $C FF_SSH_USER=u2 --list -t "$f"); rc=$?
chk "env beats file: FF_SSH_USER=u2 exported with the file's u1: the stand-in prints FF_SSH_USER=u2, and the log says line 5's value is ignored, once" \
    "[ $rc = 0 ] && [ \$(grep -c '^# viewer sees FF_FERRET=1 FF_SSH_USER=u2\$' <<<\"\$o\") = 1 ] && [ \$(grep -c \"^# -t $f line 5: FF_SSH_USER is set in the environment; the file's value is ignored\$\" <<<\"\$o\") = 1 ]" "rc=$rc $o"
fx=$(mk svx 'backend,198.18.0.1' 'backend,198.18.0.2' 'FF_VIEWERX=1' "FF_VIEWER=$S/fixtures/units/env_viewer.sh" 'FF_FERRET=1'); ox=$(ls_ $C --list -t "$fx"); rcx=$?
chk "a bad settings line dies in the pre-pass before the viewer: FF_VIEWERX on line 3 is an unknown setting, rc 2, no 'viewer sees' line although lines 4-5 would start one" \
    "[ $rcx = 2 ] && grep -q \"^ERROR: -t $fx line 3: unknown setting FF_VIEWERX;\" <<<\"\$ox\" && [ \$(grep -c 'viewer sees' <<<\"\$ox\") = 0 ]" "rc=$rcx $ox"

# --- types: backends bare, clients as "client X", bmc lines counted as read out of band ---
f=$(mk ty 'backend,198.18.0.1' 'host,198.18.0.2' '198.18.0.3' 'client,198.18.1.1' 'Client,198.18.1.2' 'bmc,198.18.9.1' 'bmc,198.18.9.2,ADMIN,bmcpw')
o=$(ls_ $C --list -t $f); rc=$?
chk "-t: backend, host = backend, a bare line = backend; client lines as 'client X' (type in any case)" "[ $rc = 0 ] && [ \"\$(grep -v '^#' <<<\"\$o\" | tr '\n' '|')\" = '198.18.0.1|198.18.0.2|198.18.0.3|client 198.18.1.1|client 198.18.1.2|' ]" "rc=$rc $o"
chk "-t: bmc lines counted in one log line as read out of band (one with a password: taken, never printed); 0 'skipped' lines" "grep -qx '# -t: 2 bmc line(s) read out of band (ipmitool -I lanplus)' <<<\"\$o\" && ! grep -q bmcpw <<<\"\$o\" && [ \$(grep -c 'bmc line(s) skipped' <<<\"\$o\") = 0 ]" "$o"
chk "-t: the host counts as --list gives them for FF_HOSTS (3 targets, 2 client targets)" "grep -qx '# 3 targets' <<<\"\$o\" && grep -qx '# 2 client targets' <<<\"\$o\"" "$o"
f=$(mk rng 'backend,198.18.0.0/29' 'client,198.18.1.1-3')
o=$(ls_ $C --list -t $f)
chk "-t: a CIDR and a range expand as in FF_HOSTS (6 backends, 3 clients)" "grep -qx '# 6 targets' <<<\"\$o\" && grep -qx '# 3 client targets' <<<\"\$o\"" "$o"

# --- one login: FF_SSH_USER (default the current user) ---
f=$(mk same 'backend,198.18.0.1,ffu' 'backend,198.18.0.2')
o=$(ls_ $C FF_SSH_USER=ffu --list -t $f); rc=$?
chk "a row whose login is FF_SSH_USER is accepted" "[ $rc = 0 ] && grep -qx '# 2 targets' <<<\"\$o\"" "rc=$rc $o"
TPWD='Zq7-pw!x'   # not P: lib.sh's parser path (render() runs python3 $P); lib's single-letter globals are C P S B H G W d O
o=$(ls_ $C FF_SSH_USER=ffu --list -t "$(mk r_pw 'backend,198.18.0.1' "backend,198.18.0.2,bob,$TPWD")"); rc=$?
chk "a row with a password is accepted (slice 4); the password is not echoed" "[ $rc = 0 ] && grep -qx '# 2 targets' <<<\"\$o\" && ! grep -qF -- \"\$TPWD\" <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C FF_SSH_USER=ffu --list -t "$(mk other 'backend,198.18.0.1' 'backend,198.18.0.2,someone')"); rc=$?
chk "a row with its own login (not FF_SSH_USER) is accepted (slice 4: a login per row)" "[ $rc = 0 ] && grep -qx '# 2 targets' <<<\"\$o\" && ! grep -q someone <<<\"\$o\"" "rc=$rc $o"
# credential rows (slice 4): accepted, adding no targets; the password never echoed
for b in "glob|backend,198.18.0.1|backend,198.18.0.*,,$TPWD" "starstar|backend,198.18.0.1|*,*,ffu" "typestar|backend,198.18.0.1|client,198.18.1.1|backend,*,ffu"; do
    IFS='|' read -r n l1 l2 l3 <<<"$b"; lines=("$l1" "$l2"); [[ -n $l3 ]] && lines+=("$l3"); f=$(mk "r_$n" "${lines[@]}")
    o=$(ls_ $C FF_SSH_USER=ffu --list -t $f); rc=$?
    chk "credential row accepted ($n): rc 0, no target added, no password in the output" "[ $rc = 0 ] && grep -qx '# 1 targets' <<<\"\$o\" && ! grep -qF -- \"\$TPWD\" <<<\"\$o\"" "rc=$rc $o"
done
chk "control: the password is in the files (the no-text checks above could see it)" "grep -qF -- \"\$TPWD\" $W/r_pw && grep -qF -- \"\$TPWD\" $W/r_glob"
o=$(ls_ $C FF_SSH_USER='a b' --list -t $W/same)
chk "a bad FF_SSH_USER is refused" "grep -q 'ERROR: FF_SSH_USER: bad login' <<<\"\$o\"" "$o"
chk "FF_SSH_USER defaults to the current user, not root" "grep -qF '\"\${FF_SSH_USER:=\$(id -un)}\"' $C && ! grep -qF 'FF_SSH_USER:=root' $C" "$(grep -n 'FF_SSH_USER:=' $C)"

# --- not with FF_HOSTS/FF_CLIENTS; types that clash; nothing to test ---
o=$(cd $W && FF_HOSTS=198.18.0.1 $B $C --list -t $W/ty 2>&1); rc=$?
chk "-t with FF_HOSTS set: refused (rc 2)" "[ $rc = 2 ] && grep -q 'use FF_HOSTS/FF_CLIENTS or -t <file>, not both' <<<\"\$o\"" "rc=$rc $o"
o=$(cd $W && FF_CLIENTS=198.18.1.1 $B $C --list -t $W/ty 2>&1); rc=$?
chk "-t with FF_CLIENTS set: refused (rc 2)" "[ $rc = 2 ] && grep -q 'use FF_HOSTS/FF_CLIENTS or -t <file>, not both' <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t "$(mk clash 'backend,198.18.0.0/30' 'client,198.18.0.2')"); rc=$?
chk "a target as backend and client: refused naming both lines" "[ $rc = 2 ] && grep -q 'line 2: a target here is already listed as backend on line 1' <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t "$(mk noback 'client,198.18.1.1' 'bmc,198.18.9.1')"); rc=$?
chk "no backend lines: refused" "[ $rc = 2 ] && grep -q 'has no backend targets' <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t $W/nonexistent.csv); rc=$?
chk "a missing file: refused (rc 2)" "[ $rc = 2 ] && grep -q \"cannot read '$W/nonexistent.csv'\" <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t "$(mk bad 'backend,198.18.0.1' 'backend,198.18.0.300')"); rc=$?
chk "a bad entry: refused naming the file's line, never the text (a row may hold a password)" "[ $rc = 2 ] && grep -q 'line 2: bad octet$' <<<\"\$o\" && ! grep -q '300' <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t "$(mk badpw 'backend,198.18.0.1' 'FF_PASSWORD hunter4')"); rc=$?
chk "a bare 'FF_PASSWORD hunter4' line (no =) is a bad host: refused by line number, 0 lines carry the value" "[ $rc = 2 ] && grep -q 'line 2: not a hostname, IP, range or CIDR$' <<<\"\$o\" && [ \$(grep -c hunter4 <<<\"\$o\") = 0 ]" "rc=$rc $o"
o=$(ls_ $C --list -t "$(mk badcidr 'backend,198.18.0.1' 'backend,198.18.0.0/33')"); rc=$?
chk "control: a bad CIDR row is still refused, by its line number" "[ $rc = 2 ] && grep -q 'line 2: bad CIDR$' <<<\"\$o\"" "rc=$rc $o"
o=$(FF_HOSTS=198.18.0.0/33 $B $C --list 2>&1); rc=$?
chk "control: the same bad CIDR in FF_HOSTS still names the entry (no password can be there)" "[ $rc = 2 ] && grep -q \"^ERROR: FF_HOSTS: bad CIDR: '198.18.0.0/33'\" <<<\"\$o\"" "rc=$rc $o"

# --- the argument loop: any order; one duration; anything else refused ---
o=$(ls_ $C -t $W/ty 30 --list)
chk "order: -t FILE 30 --list" "grep -qx '# 3 targets' <<<\"\$o\"" "$o"
o=$(ls_ $C 30 -t$W/ty --list)
chk "order: 30 -tFILE --list" "grep -qx '# 3 targets' <<<\"\$o\"" "$o"
o=$(ls_ $C --list -t $W/ty extra); rc=$?
chk "an unexpected argument is refused" "[ $rc = 2 ] && grep -q \"unexpected argument 'extra' (arguments: \\[-t FILE\\] \\[--list\\] \\[duration_s\\]; --help)\" <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list 30 40 -t $W/ty); rc=$?
chk "a second duration is refused" "[ $rc = 2 ] && grep -q \"unexpected argument '40'\" <<<\"\$o\"" "rc=$rc $o"
o=$(ls_ $C --list -t); rc=$?
chk "-t with no file is refused" "[ $rc = 2 ] && grep -q -- '-t needs a file' <<<\"\$o\"" "rc=$rc $o"

# --- planted bugs: a copy of the collector with one rule broken must fail the checks above ---
# --- the privilege probe the sweep runs (PRIV_PROBE), here against stub tools: uid, then the first escalator ---
pb() {   # pb <probe mode> <uid> <tool:ok|no>...: PRIV_PROBE's answer with only those tools on PATH (plus timeout)
    local d m=$1 u=$2; d=$(mktemp -d $W/pb.XXXXXX); shift 2
    printf '#!/bin/sh\necho %s\n' "$u" > $d/id; ln -s "$(type -P timeout)" $d/timeout   # type -P: lib.sh's timeout is a function
    for x in "$@"; do case ${x#*:} in ok) printf '#!/bin/sh\ncase $1 in -n|-e) shift ;; esac\nexec "$@"\n' ;; no) printf '#!/bin/sh\nexit 1\n' ;; esac > $d/${x%%:*}; done
    chmod +x $d/*; ( source "${PB_SCRIPT:-$C}"; PATH=$d:/usr/bin:/bin sh -c "$PRIV_PROBE" ff-probe "$m" ) 2>&1; }
chk "probe: root needs none ('0 -')" "[ \"\$(pb probe 0 sudo:ok)\" = '0 -' ]" "$(pb probe 0 sudo:ok)"
chk "probe: dzdo -n first, though sudo works too" "[ \"\$(pb probe 1000 dzdo:ok sudo:ok)\" = '1000 dzdo_-n' ]" "$(pb probe 1000 dzdo:ok sudo:ok)"
chk "probe: dzdo refuses, doas -n works" "[ \"\$(pb probe 1000 dzdo:no doas:ok sudo:no)\" = '1000 doas_-n' ]" "$(pb probe 1000 dzdo:no doas:ok sudo:no)"
chk "probe: nothing works: none" "[ \"\$(pb probe 1000 sudo:no pbrun:no)\" = '1000 none' ]" "$(pb probe 1000 sudo:no pbrun:no)"
chk "probe: the mode argument is gone, every non-root login is probed (a password login too)" "[ \"\$(pb uid 1000 dzdo:ok)\" = '1000 dzdo_-n' ]" "$(pb uid 1000 dzdo:ok)"
# --- teardown on a sudo -S host: in the run (password in memory) it stops iperf3; after a crash (the state file has no
# password) it says so and sends nothing. A stub ssh records argv and stdin ---
mkdir -p $W/tdbin; printf '#!/opt/homebrew/bin/bash\nprintf "%%s\\n" "$*" >> %s/td.argv; cat >> %s/td.stdin\n' "$W" "$W" > $W/tdbin/ssh; chmod +x $W/tdbin/ssh
td() { ( source $C; WORK=$W; SSH_OPTS=(); SENTINEL=ff-0123456789abcdef; declare -gA T_TARGET=([5]=198.18.0.25) STARTED=([5]=1) TL=([198.18.0.25]=pat) TESC=([198.18.0.25]=S) TPW=()
         [[ $1 == mem ]] && TPW[198.18.0.25]=$TPWD; PATH=$W/tdbin:$PATH; stop_servers ) 2>&1; }
rm -f $W/td.argv $W/td.stdin; o=$(td mem)
chk "teardown in the run: pkill through sudo -S -k behind the sentinel guard; stdin is the password then the sentinel" "grep -q -- \"^-l pat 198.18.0.25 sudo -S -k -p '' sh -c IFS=.*ff-0123456789abcdef.*exec.* ff-sudo pkill -x iperf3\$\" $W/td.argv && [ \"\$(cat $W/td.stdin)\" = \"\$(printf '%s\n%s' \"\$TPWD\" ff-0123456789abcdef)\" ] && ! grep -q 'not stopped' <<<\"\$o\"" "$o | $(cat $W/td.argv 2>&1) | $(cat $W/td.stdin 2>&1)"
rm -f $W/td.argv $W/td.stdin; o=$(td crash)
chk "teardown after a crash (no password): the line says so, no ssh sent" "grep -qF '# iperf3 on 198.18.0.25 not stopped: its sudo needs the -t password, which is never saved; stop it by hand' <<<\"\$o\" && [ ! -e $W/td.argv ]" "$o | $(cat $W/td.argv 2>&1)"
perl -pe 's/for c in "dzdo -n" pbrun sesu pmrun "doas -n" "ksu -e" "sudo -n"; do/for c in "sudo -n" "ksu -e" "doas -n" pmrun sesu pbrun "dzdo -n"; do/' $C > $W/x_order.sh
chk "planted bug (probe order reversed): sudo picked over dzdo" "[ \$(diff $C $W/x_order.sh | grep -c '^>') = 1 ] && [ \"\$(PB_SCRIPT=$W/x_order.sh pb probe 1000 dzdo:ok sudo:ok)\" = '1000 sudo_-n' ]" "$(PB_SCRIPT=$W/x_order.sh pb probe 1000 dzdo:ok sudo:ok)"
perl -pe 's/if \[\[ \$\{T_TYPE\[\$k\]\} == client \]\]; then TF_CL\+=/if false; then TF_CL+=/' $C > $W/x_split.sh
o=$(ls_ $W/x_split.sh --list -t $W/ty)
chk "planted bug (clients not split out): no 'client' lines" "[ \$(diff $C $W/x_split.sh | grep -c '^>') = 1 ] && ! grep -q '^client ' <<<\"\$o\"" "$(diff $C $W/x_split.sh) $o"
finish
