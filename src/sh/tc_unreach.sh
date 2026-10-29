# ssh's last error line when nothing took the connection (no host, no sshd, no route, name not found); auth and
# host key failures don't match: a host is there
NO_CONNECT_RE='Connection timed out|Connection refused|No route to host|Host is unreachable|Network is unreachable|Operation timed out|Could not resolve hostname|Name or service not known'

# unreachable_targets: a target that took no ssh connection in any sample goes to UNREACH (left out of every count
# and file; -v lists them). One that answered in another sample gets its none rows back for the samples it missed.
unreachable_targets() {
    local i n why h
    UNREACH=()
    for i in "${!TARGETS[@]}"; do
        [[ -s $WORK/unreach.$i ]] || continue
        if [[ -e $WORK/answered.$i ]]; then
            h=$(awk -v t="${TARGETS[$i]}" '$2 == t && $3 != t {print $3; exit}' "$WORK/hosts"); h=${h:-${TARGETS[$i]}}
            while read -r n why; do
                echo "s$n $h hwmon - - none - - - $why" >> "$WORK/temps.txt"
                [[ $MODE == ipmi ]] && echo "s$n $h ipmi bmc - none - - - $why" >> "$WORK/temps.txt"
            done < "$WORK/unreach.$i"
        else UNREACH+=("$i"); fi
    done
}
