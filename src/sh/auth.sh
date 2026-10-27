# ---------- passwords: one-use fifos read by an SSH_ASKPASS helper (both tools) ----------

# write_askpass path: ssh's SSH_ASKPASS helper (as wekatester's): no to a new host key, nothing for a key passphrase,
# else ONE line from the fifo $THERMCAP_PW_FIFO names, once (a second prompt, a wrong password, gets nothing)
write_askpass() {
    printf '%s\n' '#!/bin/sh' 'case "$1" in' '    *"continue connecting"*|*"(yes/no"*) echo no; exit 0 ;;' '    *[Pp]assphrase*) exit 1 ;;' 'esac' \
        '[ ! -e "$THERMCAP_PW_FIFO.used" ] || exit 1' ': > "$THERMCAP_PW_FIFO.used"' 'IFS= read -r pw < "$THERMCAP_PW_FIFO"' "printf '%s\\n' \"\$pw\"" > "$1"
    chmod 700 "$1" || die "cannot make the askpass helper executable"
}
# pwfifo name pw: a one-use fifo in AUTH holding pw, open read-write on fd 4 (a fifo drops what it holds when its last
# fd closes; the write can't block). The pw goes in by printf (a builtin: no argv). Caller: exec 4>&-; rm the fifo.
pwfifo() { local f=$AUTH/$1.fifo; rm -f "$f" "$f.used"; mkfifo -m 600 "$f" || return 1; exec 4<>"$f"; printf '%s\n' "$2" >&4; PWFIFO=$f; }
