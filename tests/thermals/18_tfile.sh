#!/opt/homebrew/bin/bash
# -t file: logins, passwords, bmc lines, field shapes (from test_thermals.sh, split into sections 10-26)

# checks: 24
# secs: 34
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# --- -t file: host and bmc lines, logins, passwords (never on a command line or in any output) ---
me=$(id -un)
P1='s3cr,et pw'; P3='wrong-one'; P4='bmc pw!x'; P5='nope'
tfile() {   # tfile <dir> <mode>: the target file plus the fake's expectations
    local d=$W/$1; mkdir -p "$d/fake" "$d/out"
    printf '%s\n' "# type,host,login,pw" "host,198.19.110.1,alice,$P1" "host , 198.19.110.2 ,," "host,198.19.110.3,bob,$P3" "" \
        "bmc,198.19.111.1,admin,$P4" "bmc,198.19.111.2,admin,$P5" "bmc,198.19.111.3,admin" "host,198.19.110.8/30,carol" > "$d/targets.csv"
    chmod "$2" "$d/targets.csv"
    echo alice > "$d/fake/login.198.19.110.1"; printf '%s' "$P1" > "$d/fake/pw.198.19.110.1"
    echo "$me" > "$d/fake/login.198.19.110.2"
    echo bob > "$d/fake/login.198.19.110.3"; printf '%s' 'the-right-one' > "$d/fake/pw.198.19.110.3"
    printf '%s' "$P4" > "$d/fake/bmcpw.198.19.111.1"; echo admin > "$d/fake/bmcuser.198.19.111.1"
    printf '%s' 'other' > "$d/fake/bmcpw.198.19.111.2"; echo hot > "$d/fake/bmc.198.19.111.3"
    echo carol > "$d/fake/login.198.19.110.9"; echo down > "$d/fake/case.198.19.110.10"
}
tfile tf 644; CASES=""
out=$(run tf $B $TC -t $W/tf/targets.csv -o jsonl,html,md); rc=$?
chk "-t: rc 3 PARTIAL, hosts=5/7 (5 ssh + 3 bmc less 1 unreachable), unreachable=1" "[ $rc = 3 ] && grep -qE '^RESULT data=PARTIAL hosts=5/7 .* unreachable=1\$' <<<\"\$out\"" "rc=$rc $(tail -n 3 <<<"$out")"
chk "-t: ssh as each line's login (alice, $me for no login, bob, carol for the range)" \
    "grep -q -- '-l alice .*198.19.110.1 bash' $W/tf/fake/calls.log && grep -q -- '-l $me .*198.19.110.2 bash' $W/tf/fake/calls.log && grep -q -- '-l bob .*198.19.110.3 bash' $W/tf/fake/calls.log && grep -q -- '-l carol .*198.19.110.9 bash' $W/tf/fake/calls.log" "$(grep -o -- '-l [^ ]* .*198\.19\.110\.[0-9]* bash' $W/tf/fake/calls.log)"
chk "-t: key logins keep BatchMode=yes; password logins use BatchMode=no and SSH_ASKPASS (no sshpass)" \
    "grep -q 'BatchMode=yes .*198.19.110.2 bash' $W/tf/fake/calls.log && grep -q 'BatchMode=no .*198.19.110.1 bash' $W/tf/fake/calls.log && grep -qx 'askpass 198.19.110.1' $W/tf/fake/calls.log" "$(cat $W/tf/fake/calls.log)"
# the fakes log "pwenv" for any environment variable holding a target's password (ssh, ipmitool, the remote sudo);
# their checks ran: alice's askpass line above, and the BMCs with passwords answered (198.19.111.1 below)
chk "-t: no password in any environment: ssh, the BMC ipmitool, the remote sudo (no pwenv line in either run)" "! grep -q '^pwenv' $W/tf/fake/calls.log" "$(grep '^pwenv' $W/tf/fake/calls.log)"
chk "-t: alice's password (comma and space in it) logged in: n1 has readings" "jl tf | jq -e 'select(.type == \"sensor\" and .host == \"n1\" and .sensor == \"Package_id_0\")' > $W/tf1.jq" "$(jl tf | jq -c 'select(.host == "n1")' | head -n 2)"
chk "-t: wrong password and the BMC auth failure are loud no-data with the reason" \
    "[ \"\$(jl tf | jq -r 'select(.type == \"nodata\") | \"\\(.host) \\(.source) \\(.why)\"' | tr '\n' '|')\" = '198.19.110.3 hwmon ssh_failed_bob_198.19.110.3:_Permission_denied__publickey_password_.|198.19.110.3 ipmi ssh_failed_bob_198.19.110.3:_Permission_denied__publickey_password_.|198.19.111.2 ipmi rc=1_Error:_Unable_to_establish_IPMI_v2___RMCP__session|' ]" "$(jl tf | jq -c 'select(.type == "nodata")')"
chk "-t: bmc read out of band: 198.19.111.1 CPU1/Inlet (dev lanplus), 198.19.111.3 inlet 45 status cr: crit" \
    "[ \"\$(jl tf | jq -r 'select(.type == \"sensor\" and .dev == \"lanplus\") | \"\\(.host):\\(.sensor):\\(.max_c):\\(.flag)\"' | tr '\n' ' ')\" = '198.19.111.1:Inlet_Temp:24.0:null 198.19.111.1:CPU1_Temp:61.0:null 198.19.111.3:Inlet_Temp:45.0:crit 198.19.111.3:CPU1_Temp:61.0:null ' ]" "$(jl tf | jq -c 'select(.dev == "lanplus")')"
chk "-t: ipmitool as -I lanplus -H <bmc> -U admin -f <a fifo in the private auth dir> sensor for the two BMCs with a password, -E (empty) for the one without" \
    "[ \$(grep -cE '^ipmitool -I lanplus -H 198\\.19\\.111\\.[12] -U admin -f /.*/auth/b[0-9]+\\.[0-9]+\\.fifo sensor\$' $W/tf/fake/ipmi_calls.log) = 2 ] && grep -qx 'ipmitool -I lanplus -H 198.19.111.3 -U admin -E sensor' $W/tf/fake/ipmi_calls.log" "$(cat $W/tf/fake/ipmi_calls.log)"
chk "-t: host records carry target_type, login, auth (password|key|none); no password field" \
    "[ \"\$(jl tf | jq -r 'select(.type == \"host\") | \"\\(.target):\\(.target_type):\\(.login):\\(.auth)\"' | sort | tr '\n' ' ')\" = \"198.19.110.1:backend:alice:password 198.19.110.2:backend:$me:key 198.19.110.3:backend:bob:password 198.19.110.9:backend:carol:key 198.19.111.1:bmc:admin:password 198.19.111.2:bmc:admin:password 198.19.111.3:bmc:admin:none \" ] && ! jl tf | jq -e 'select(has(\"pw\") or has(\"password\"))' > $W/tf2.jq" "$(jl tf | jq -c 'select(.type == "host")')"
leak=$(for p in "$P1" "$P3" "$P4" "$P5"; do grep -lF -- "$p" $W/tf/out/* $W/tf/fake/calls.log $W/tf/fake/ipmi_calls.log; grep -cF -- "$p" <<<"$out"; done 2>&1)
ctl=$(for p in "$P1" "$P3" "$P4" "$P5"; do grep -cF -- "$p" $W/tf/targets.csv; done | tr '\n' ' ')
chk "-t: no password in any output, the stderr log, or any argv (ssh, ipmitool); control: all 4 are in the file" \
    "[ \"\$leak\" = \"\$(printf '0\n0\n0\n0')\" ] && [ \"\$ctl\" = '1 1 1 1 ' ]" "leak=[$leak] ctl=[$ctl]"
chk "-t: file readable by others with passwords in it: WARNING" "grep -q 'WARNING: .*targets.csv holds passwords and is readable by group or others' <<<\"\$out\""
tfile tf6 600
out=$(run tf6 $B $TC -t $W/tf6/targets.csv); chk "-t: chmod 600: no warning (control)" "! grep -q WARNING <<<\"\$out\" && grep -q '^RESULT' <<<\"\$out\""
# (the sshpass check is gone: sshpass is no longer used, slice 2)
tfile tfo 600
out=$(FAKE_SSH_VERSION='OpenSSH_7.4p1, OpenSSL 1.0.2k' run tfo $B $TC -t $W/tfo/targets.csv); rc=$?
chk "-t password logins, OpenSSH 7.4 and no setsid (this Mac): refused (rc 2)" "[ $rc = 2 ] && grep -q 'password logins in -t need OpenSSH 8.4+ or setsid here (ssh -V: 7.4)' <<<\"\$out\"" "rc=$rc $out"
out=$(FF_HOSTS=198.19.112.1 run tfb $B $TC -t $W/tf/targets.csv); rc=$?
chk "FF_HOSTS and -t together: refused (rc 2), no ssh made" "[ $rc = 2 ] && grep -q 'use FF_HOSTS or -t <file>, not both' <<<\"\$out\" && [ ! -e $W/tfb/fake/calls.log ]" "rc=$rc $out"
out=$(run tfb2 $B $TC -t $W/tf/targets.csv extra); rc=$?
chk "unexpected argument after -t refused (rc 2)" "[ $rc = 2 ] && grep -q \"unexpected argument 'extra'\" <<<\"\$out\"" "rc=$rc $out"
chk "--list -t: the file's hosts (range expanded), then the BMCs" \
    "[ \"\$($B $TC --list -t $W/tf/targets.csv 2> $W/list.err | tr '\n' '|')\" = '198.19.110.1|198.19.110.2|198.19.110.3|198.19.110.9|198.19.110.10|198.19.111.1 (bmc)|198.19.111.2 (bmc)|198.19.111.3 (bmc)|' ]" "$($B $TC --list -t $W/tf/targets.csv 2>&1)"
# a host named on its own line after a range line that already covered it: the named line's login/pw win
d=$W/tov; mkdir -p $d/fake $d/out
printf '%s\n' "host,198.19.114.0/30,ops" "host,198.19.114.1,admin,$P1" > $d/targets.csv; chmod 600 $d/targets.csv
echo admin > $d/fake/login.198.19.114.1; printf '%s' "$P1" > $d/fake/pw.198.19.114.1; echo ops > $d/fake/login.198.19.114.2
out=$(run tov $B $TC -t $d/targets.csv); rc=$?
chk "override: .1 from the range then its own line -> admin + pw; .2 stays ops" \
    "[ $rc = 0 ] && grep -q -- '-l admin .*198.19.114.1 bash' $d/fake/calls.log && ! grep -q -- '-l ops .*198.19.114.1 bash' $d/fake/calls.log && grep -q -- '-l ops .*198.19.114.2 bash' $d/fake/calls.log && grep -q '^RESULT data=COMPLETE hosts=2/2 ' <<<\"\$out\"" "rc=$rc $(grep -o -- '-l [^ ]* .*198\.19\.114\.[0-9]* bash' $d/fake/calls.log) $(tail -n 1 <<<"$out")"
# a non-root password login: ipmitool through sudo -S with that password (stdin), not sudo -n
d=$W/tsu; mkdir -p $d/fake $d/out; P6='erin pw,9'
printf '%s\n' "host,198.19.116.1,erin,$P6" "host,198.19.116.2,frida,$P6" "host,198.19.116.3,gus" > $d/targets.csv; chmod 600 $d/targets.csv
for x in 1 2 3; do echo sudopw > $d/fake/case.198.19.116.$x; done
# .4: a password login on a NOPASSWD host (sudo -S takes nothing from stdin): the BMC is read, the password shows nowhere
printf '%s\n' "host,198.19.116.4,hal,$P6" >> $d/targets.csv; echo sudonopw > $d/fake/case.198.19.116.4; printf '%s' "$P6" > $d/fake/pw.198.19.116.4
printf '%s' "$P6" > $d/fake/pw.198.19.116.1; printf '%s' "$P6" > $d/fake/sudopw.198.19.116.1
printf '%s' "$P6" > $d/fake/pw.198.19.116.2; printf '%s' 'sudo-differs' > $d/fake/sudopw.198.19.116.2
printf '%s' 'unused' > $d/fake/sudopw.198.19.116.3
out=$(run tsu $B $TC -t $d/targets.csv -o jsonl,html,md); rc=$?
chk "sudo -S on a NOPASSWD host (hal, .4): the BMC is read; the password is in no output, jsonl, html, md, stderr or fake log (control: in the file)" \
    "[ \"\$(jl tsu | jq -r 'select(.type == \"sensor\" and .host == \"n4\" and .source == \"ipmi\") | .sensor' | tr '\n' ' ')\" = 'Inlet_Temp Exhaust_Temp ' ] && ! grep -qF -- \"\$P6\" $d/out/* $d/fake/calls.log $d/fake/sudo_calls.log && ! grep -qF -- \"\$P6\" <<<\"\$out\" && grep -qF -- \"\$P6\" $d/targets.csv && ls $d/out/*.html $d/out/*.md > $W/tsu.ls" "rc=$rc $(jl tsu | jq -c 'select(.host == "n4")' | head -n 3)"
chk "sudo -S: erin (password login, sudo takes it) gets the BMC: Inlet/Exhaust via in-band ipmitool" \
    "[ \"\$(jl tsu | jq -r 'select(.type == \"sensor\" and .host == \"n1\" and .source == \"ipmi\") | .sensor' | tr '\n' ' ')\" = 'Inlet_Temp Exhaust_Temp ' ]" "rc=$rc $(jl tsu | jq -c 'select(.host == "n1" and .source == "ipmi")') $(cat $d/fake/sudo_calls.log 2>&1)"
chk "sudo -S: frida (sudo wants another password) is loud no-data with sudo's reason; gus (key login: the probe, sudo -n refused) with the no-escalator reason" \
    "[ \"\$(jl tsu | jq -r 'select(.type == \"nodata\") | \"\\(.host) \\(.why)\"' | tr '\n' '|')\" = 'n2 sudo_refused_sudo:_1_incorrect_password_attempt|n3 no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo|' ]" "$(jl tsu | jq -c 'select(.type == "nodata")')"
chk "sudo -S: argv is 'sudo -S -p  ipmitool sensor' (erin, frida) / 'sudo -n true' (gus's probe, refused); the password in no argv, output or environment (no pwenv from the remote sudo)" \
    "[ \"\$(LC_ALL=C sort -u $d/fake/sudo_calls.log | tr '\n' '|')\" = 'sudo -S -p  ipmitool sensor|sudo -n true|' ] && ! grep -q '^pwenv' $d/fake/calls.log && ! grep -qF -- \"\$P6\" $d/fake/sudo_calls.log $d/fake/calls.log $d/out/* && ! grep -qF -- \"\$P6\" <<<\"\$out\" && grep -qF -- \"\$P6\" $d/targets.csv" "$(cat $d/fake/sudo_calls.log)"
# bmc lines only: no ssh at all; a slow BMC times out loudly; --list has no blank line
d=$W/tbo; mkdir -p $d/fake $d/out
printf '%s\n' "bmc,198.19.115.1,admin" "bmc,198.19.115.2,admin" > $d/targets.csv; echo slow > $d/fake/bmc.198.19.115.2
out=$(run tbo FF_IPMI_TIMEOUT=2 $B $TC -t $d/targets.csv -o jsonl,md); rc=$?
chk "bmc-only: rc 3, hosts=1/2, the slow BMC: ipmitool_timed_out_after_2s, no ssh call, label from the first BMC" \
    "[ $rc = 3 ] && grep -q '^RESULT data=PARTIAL hosts=1/2 ' <<<\"\$out\" && grep -q 'NO TEMPERATURE DATA: 198.19.115.2 ipmi (ipmitool_timed_out_after_2s)' <<<\"\$out\" && [ ! -e $d/fake/calls.log ] && grep -q '^# Thermals: 198.19.115.1\$' $d/out/*.md" "rc=$rc $(tail -n 4 <<<"$out") $(ls $d/out)"
chk "bmc-only --list: just the BMCs, no blank line" "[ \"\$($B $TC --list -t $d/targets.csv 2> $W/list2.err | tr '\n' '|')\" = '198.19.115.1 (bmc)|198.19.115.2 (bmc)|' ]" "$($B $TC --list -t $d/targets.csv 2>&1 | cat -e | head -n 3)"
# field shapes (10-26 on a real cluster): the --list and refusal checks moved to 03_hostfile (fast, no run);
# the plain list end to end stays, as FF_SSH_USER=svc: a bare line takes FF_SSH_USER (the no-login line in tf above
# is the unset case: the current user)
d=$W/tpl; mkdir -p $d
printf '%s\n' "# One host per line, a comment" "  # indented comment" "" "198.19.117.1" "198.19.117.2" "node-a" > $d/plain.lst
CASES="198.19.117.1:all 198.19.117.2:all node-a:nodns"
out=$(FF_SSH_USER=svc run tplr $B $TC -t $d/plain.lst); rc=$?
chk "-t plain list end to end, FF_SSH_USER=svc: node-a (name not found) silent, the two IPs read as svc with keys, COMPLETE" "grep -q -- '-l svc .*198.19.117.1 bash' $W/tplr/fake/calls.log && ! grep -q -- '-l $me ' $W/tplr/fake/calls.log && ! grep -q 'node-a' <<<\"\$out\" && grep -q '^RESULT data=COMPLETE hosts=2/2 .* unreachable=1\$' <<<\"\$out\"" "rc=$rc $(tail -n 4 <<<"$out") $(grep -o -- '-l [^ ]*' $W/tplr/fake/calls.log | sort -u)"
finish
