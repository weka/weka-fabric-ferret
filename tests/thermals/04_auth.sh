#!/opt/homebrew/bin/bash
# password transport units (slice 2): the askpass helper over a one-use fifo, rssh and rbmc with stub ssh/ipmitool,
# and the reader's sudo -S, each with a planted export that must be caught. No thermals_capture run.
# tier: fast
# checks: 24
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
P='Pw,with spaces!9'
mkdir -p $W/stub $W/auth
# fn <script> <cmds>: thermals_capture's functions from <script>, with the globals rssh/rbmc read, then <cmds>
fn() { ( source "$1"; AUTH=$W/auth; SSH_OPTS=(); TO=; SETSID=; FF_IPMI_TIMEOUT=5; HOST_LIMIT=5
         TARGETS=(198.19.160.1); T_LOGIN=(alice); T_PW=("$P"); BMCS=(198.19.161.1 198.19.161.2); B_LOGIN=(adm adm); B_PW=("$P" "")
         PATH=$W/stub:$PATH; eval "$2" ) 2>&1; }
# stubs: dump argv and environment, then ask the helper (ssh) or read -f (ipmitool) as the real ones would
printf '%s\n' '#!/opt/homebrew/bin/bash' 'd=${STUB_OUT:?}; printf "%s\n" "$@" > $d.argv; env > $d.env' \
    '"$SSH_ASKPASS" "alice@198.19.160.1'"'"'s password: " > $d.got; ls "$THERMCAP_PW_FIFO" > $d.fifo 2>&1' > $W/stub/ssh
printf '%s\n' '#!/opt/homebrew/bin/bash' 'd=${STUB_OUT:?}; printf "%s\n" "$@" > $d.argv; env > $d.env; f=' \
    'while (( $# )); do [[ $1 == -f ]] && f=$2; shift; done; if [[ -n $f ]]; then IFS= read -r p < "$f"; printf "%s\n" "$p" > $d.got; fi' > $W/stub/ipmitool
chmod +x $W/stub/ssh $W/stub/ipmitool

# --- the askpass helper ---
o=$(fn "$TC" 'write_askpass $AUTH/ap; pwfifo t0 "$P"; f=$PWFIFO
    a=$(THERMCAP_PW_FIFO=$f $AUTH/ap "alice@h'"'"'s password: "); b=$(THERMCAP_PW_FIFO=$f $AUTH/ap "again: "); brc=$?
    c=$(THERMCAP_PW_FIFO=$f $AUTH/ap "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
    d=$(THERMCAP_PW_FIFO=$f $AUTH/ap "Enter passphrase for key: "); drc=$?
    printf "first[%s] second[%s] rc=%s hostkey[%s] passphrase[%s] rc=%s mode=%s\n" "$a" "$b" $brc "$c" "$d" $drc "$(stat -f %Lp $AUTH/ap)"')
chk "askpass helper: the password once from the fifo; a second prompt gets nothing (rc 1)" "grep -qF 'first[$P] second[] rc=1' <<<\"\$o\"" "$o"
chk "askpass helper: a new host key gets 'no'; a key passphrase gets nothing (rc 1); the helper is 700" "grep -qF 'hostkey[no] passphrase[] rc=1 mode=700' <<<\"\$o\"" "$o"

# --- rssh: the password through the helper, nowhere in ssh's argv or environment ---
fn "$TC" 'write_askpass $AUTH/askpass; STUB_OUT=$W/ss rssh 0 bash -s -- x' > $W/ss.out
chk "rssh: ssh got the password through SSH_ASKPASS" "[ \"\$(cat $W/ss.got)\" = \"\$P\" ]" "$(cat $W/ss.got $W/ss.out 2>&1)"
chk "rssh: no password in ssh's argv or environment" "! grep -qF -- \"\$P\" $W/ss.argv $W/ss.env && grep -q '^THERMCAP_PW_FIFO=$W/auth/t0\\.[0-9]*\\.fifo\$' $W/ss.env" "$(grep -E 'THERMCAP|ASKPASS' $W/ss.env)"
chk "rssh: the fifo is gone after the call; BatchMode=no for a password login" "! ls $W/auth/t0.*.fifo > $W/ls.out 2>&1 && grep -qx 'BatchMode=no' $W/ss.argv" "$(ls $W/auth)"
# --- rbmc: -f <fifo> for a password, -E with an empty IPMI_PASSWORD without one ---
fn "$TC" 'STUB_OUT=$W/b0 rbmc 0; STUB_OUT=$W/b1 rbmc 1' > $W/b.out
chk "rbmc: ipmitool read the password from -f <fifo in AUTH>; not in its argv or environment" "[ \"\$(cat $W/b0.got)\" = \"\$P\" ] && grep -qx -- '-f' $W/b0.argv && grep -q '^$W/auth/b0\\.[0-9]*\\.fifo\$' $W/b0.argv && ! grep -qF -- \"\$P\" $W/b0.argv $W/b0.env" "$(cat $W/b0.argv) | $(grep IPMI $W/b0.env)"
chk "rbmc: no password: -E with IPMI_PASSWORD empty" "grep -qx -- '-E' $W/b1.argv && grep -qx 'IPMI_PASSWORD=' $W/b1.env" "$(cat $W/b1.argv) | $(grep IPMI $W/b1.env)"
# --- the reader's sudo -S: the password ahead of the script on stdin, an unexported shell variable ---
# rd <script> <case>: the reader through the fake ssh with a password line first, as sample() sends it
rd() { local d; d=$(mktemp -d "$W/rd.XXXXXX"); echo "$2" > $d/case.198.19.162.1; printf '%s' "$P" > $d/sudopw.198.19.162.1
       ( source "$1"; { printf 'IFS= read -r TC_PW\n%s\n' "$P"; printf '%s\n' "$TEMP_SCRIPT"; } | FAKE_TC=$d $H/fake/ssh -l erin 198.19.162.1 bash -s -- ipmi 5 ) 2>&1
       echo "== calls: $(grep -c . $d/calls.log) pwenv: $(grep -c '^pwenv' $d/calls.log)"; }
o=$(rd "$TC" sudopw)
chk "reader sudo -S: the BMC read through sudo -S with the password; no pwenv from the remote sudo" "grep -q '^@@IPMI .* Inlet_Temp ' <<<\"\$o\" && grep -q 'pwenv: 0\$' <<<\"\$o\"" "$o"

# --- the escalator probe (non-root, no row password): dzdo -n, pbrun, sesu, pmrun, doas -n, ksu -e, sudo -n ---
# (rx is in lib.sh; the hung-dzdo case, 5 s, is in 05_escslow, full tier: fast stays under 15 s)
o=$(rx "$TC" esc_dzdo)
chk "probe: dzdo -n works: @@ESC dzdo_-n, ipmitool through dzdo -n, sudo never tried" "grep -qx '@@ESC n1 dzdo_-n' <<<\"\$o\" && grep -q '^@@IPMI n1 Inlet_Temp ' <<<\"\$o\" && grep -q 'esc: dzdo -n true;dzdo -n ipmitool sensor; ' <<<\"\$o\"" "$o"
o=$(rx "$TC" esc_doas)
chk "probe: only doas: @@ESC doas_-n (dzdo, pbrun, sesu, pmrun absent), sudo never tried" "grep -qx '@@ESC n1 doas_-n' <<<\"\$o\" && grep -q 'esc: doas -n true;doas -n ipmitool sensor; ' <<<\"\$o\"" "$o"
o=$(rx "$TC" esc_none)
chk "probe: nothing works: @@ESC none and the no-escalator reason; sudo -n true was the last try" "grep -qx '@@ESC n1 none' <<<\"\$o\" && grep -qx '@@IPMI n1 none no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo' <<<\"\$o\" && grep -q 'esc: sudo -n true; ' <<<\"\$o\"" "$o"
o=$(rx "$TC" esc_both dzdo_-n)
chk "cache: an escalator from an earlier sample is used with no probe (no 'true' call)" "grep -qx '@@ESC n1 dzdo_-n' <<<\"\$o\" && grep -q 'esc: dzdo -n ipmitool sensor; ' <<<\"\$o\"" "$o"
o=$(rx "$TC" esc_none none)
chk "cache: none from an earlier sample: no probe, no ipmitool, the reason again" "grep -qx '@@IPMI n1 none no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo' <<<\"\$o\" && grep -q 'esc: (no escalator run) ' <<<\"\$o\"" "$o"
o=$(rx "$TC" all)
chk "probe: root skips it (no @@ESC, ipmitool direct)" "! grep -q '^@@ESC' <<<\"\$o\" && grep -q '^@@IPMI n1 Inlet_Temp ' <<<\"\$o\"" "$o"
perl -pe 's/for e in "dzdo -n" pbrun sesu pmrun "doas -n" "ksu -e" "sudo -n"; do/for e in "sudo -n" "ksu -e" "doas -n" pmrun sesu pbrun "dzdo -n"; do/' "$TC" > $W/x_order.sh
o=$(rx $W/x_order.sh esc_both)
chk "planted bug (probe order reversed): with dzdo and sudo both working, sudo is picked" "[ \$(diff $TC $W/x_order.sh | grep -c '^>') = 1 ] && grep -qx '@@ESC n1 sudo_-n' <<<\"\$o\"" "$(diff $TC $W/x_order.sh) $o"
perl -pe 's/^    if \[ -z "\$esc" \]; then$/    if true; then/' "$TC" > $W/x_cache.sh
o=$(rx $W/x_cache.sh esc_both dzdo_-n)
chk "planted bug (cache ignored): the probe runs again (dzdo -n true)" "[ \$(diff $TC $W/x_cache.sh | grep -c '^>') = 1 ] && grep -q 'esc: dzdo -n true;' <<<\"\$o\"" "$(diff $TC $W/x_cache.sh) $o"

# --- sudoers NOPASSWD: sudo -S takes nothing, so the password line stays on ipmitool's stdin, where nothing runs it ---
o=$(rd "$TC" sudonopw)
chk "reader, NOPASSWD sudo: the BMC is read; the password is in no reader output line (sudo's argv has -S, no password)" "grep -q '^@@IPMI .* Inlet_Temp ' <<<\"\$o\" && ! grep -qF -- \"\$P\" <<<\"\$o\" && grep -q 'pwenv: 0\$' <<<\"\$o\"" "$o"
# planted control: a reader that hands the line sudo left to a shell that writes it out (on the ssh session's stderr):
# the password shows. (A reader that merely *ran* the line would not show it: the reader captures sudo's stream
# with 2>&1 and prints only parsed sensor rows, so the line could at most reach the mangled rc=... reason.)
perl -pe 's/\| tmo "\$ito" sudo -S -p "" ipmitool sensor 2>&1\)/| tmo "\$ito" sudo -S -p "" sh -c '"'"'IFS= read -r l; echo "stray: \$l" >\&2; ipmitool sensor'"'"')/' "$TC" > $W/x_execline.sh
o=$(rd $W/x_execline.sh sudonopw)
chk "planted control (a reader that lets the line sudo left reach a shell's stderr): the password shows in the output" "[ \$(diff $TC $W/x_execline.sh | grep -c '^>') = 1 ] && grep -qF -- \"stray: \$P\" <<<\"\$o\"" "$(diff $TC $W/x_execline.sh) $(grep -F -- "$P" <<<"$o" | head -n 2)"

# --- planted exports: one per place, each must show up ---
perl -pe 's/(    pwfifo "t\$i\.\$BASHPID")/    export THERMCAP_PW=\${T_PW[\$i]}\n$1/' "$TC" > $W/x_rssh.sh
fn $W/x_rssh.sh 'write_askpass $AUTH/askpass; STUB_OUT=$W/xs rssh 0 bash -s -- x' > $W/xs.out
chk "planted bug (rssh exports the password): it shows in ssh's environment" "[ \$(diff $TC $W/x_rssh.sh | grep -c '^>') = 1 ] && grep -qF -- \"\$P\" $W/xs.env" "$(diff $TC $W/x_rssh.sh)"
perl -pe 's/(    if \[\[ -n \$\{B_PW\[\$j\]\} \]\]; then pwfifo)/    export IPMI_PASSWORD=\${B_PW[\$j]}\n$1/' "$TC" > $W/x_rbmc.sh
fn $W/x_rbmc.sh 'STUB_OUT=$W/xb rbmc 0' > $W/xb.out
chk "planted bug (rbmc exports the password): it shows in ipmitool's environment" "[ \$(diff $TC $W/x_rbmc.sh | grep -c '^>') = 1 ] && grep -qF -- \"\$P\" $W/xb.env" "$(diff $TC $W/x_rbmc.sh)"
perl -pe 's/^(s=; \[ "\$\(id -u\)" = 0 \] \|\| \{ s=n; \[ -n "\$\{TC_PW\+x\}" \] && s=S; \})$/$1; export TC_PW/' "$TC" > $W/x_reader.sh
o=$(rd $W/x_reader.sh sudopw)
chk "planted bug (the reader exports TC_PW): the remote sudo logs pwenv" "[ \$(diff $TC $W/x_reader.sh | grep -c '^>') = 1 ] && grep -q 'pwenv: [1-9]' <<<\"\$o\"" "$(diff $TC $W/x_reader.sh) $o"
# the fake ssh's own check: a password in ssh's environment is logged (its pwenv loop works)
d=$W/fk; mkdir -p $d; printf '%s' "$P" > $d/pw.198.19.163.1; printf '%s\n' '#!/bin/sh' "printf '%s\\n' '$P'" > $W/ap2; chmod +x $W/ap2
( export LEAK="$P"; FAKE_TC=$d SSH_ASKPASS=$W/ap2 SSH_ASKPASS_REQUIRE=force $H/fake/ssh -l x 198.19.163.1 true ) > $W/fk.out 2>&1
chk "fake ssh: a password in its environment is logged as pwenv (the control for every 'no pwenv' check)" "grep -qx 'pwenv 198.19.163.1 LEAK' $d/calls.log" "$(cat $d/calls.log)"
chk "sshpass is never run or fed (no 'command -v sshpass', no SSHPASS variable)" "! grep -qE 'command -v sshpass|SSHPASS' $TC" "$(grep -nE 'command -v sshpass|SSHPASS' $TC)"
chk "control: the script does name SSH_ASKPASS (the grep above can match)" "grep -q SSH_ASKPASS $TC"
finish
