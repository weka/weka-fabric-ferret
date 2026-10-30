# ---------- a temperature capture after the targets are loaded (both tools: thermals_capture.sh, and
# fabric_ferret.sh --thermals-only) ----------

THERMALS_VERSION=1.0

# tc_cleanup: the EXIT trap of a capture: close the ssh masters, remove SOCKET_DIR and WORK, keep the exit code
tc_cleanup() {
    local rc=$? t
    trap '' INT TERM HUP
    if [[ -n $SOCKET_DIR ]]; then
        for t in "${!TARGETS[@]}"; do ssh -O exit -o "ControlPath=$SOCKET_DIR/%C" -l "${T_LOGIN[$t]}" "${TARGETS[$t]}" >> "$WORK/cleanup.log" 2>&1 & done
        wait
        rm -rf "${SOCKET_DIR:?}"
    fi
    [[ -n $WORK ]] && rm -rf "${WORK:?}"
    exit $rc
}

# tc_check_settings: the settings a capture reads, after a -t file's settings lines have had their say
tc_check_settings() {
    local v
    [[ $FF_IPMI == 0 || $FF_IPMI == 1 ]] || die "FF_IPMI must be 0 or 1, got '$FF_IPMI'"
    for v in FF_TEMP_MARGIN FF_TEMP_RISE; do [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number, got '${!v}'"; done
    for v in FF_IPMI_TIMEOUT FF_SSH_PARALLEL; do
        [[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v must be a positive integer, got '${!v}'"
    done
}

# tc_list: --list, the targets and BMCs a capture would read, one a line; exits 0
tc_list() {
    (( ${#TARGETS[@]} )) && printf '%s\n' "${TARGETS[@]}"; (( ${#BMCS[@]} )) && printf '%s (bmc)\n' "${BMCS[@]}"; exit 0
}

# tc_check_opts: -o into FMTS, -d and -i into the caller's du and iv (its locals: fmt du iv), refused loudly when wrong
tc_check_opts() {
    local v
    FMTS=(); local -A seen=(); local -a fl
    IFS=, read -ra fl <<<"$fmt"
    [[ -n $fmt && $fmt != *, && $fmt != ,* && $fmt != *,,* ]] || die "-o takes a comma-separated list of jsonl, html, md; got '$fmt'"
    for v in "${fl[@]}"; do
        [[ $v == jsonl || $v == html || $v == md ]] || die "-o takes a comma-separated list of jsonl, html, md; got '$v' in '$fmt'"
        [[ -n ${seen[$v]+x} ]] || { seen[$v]=1; FMTS+=("$v"); }
    done
    # -d 0 (default): one point-in-time read. -d N: a read now and one N seconds later (min/max), or every -i seconds
    : "${du:=0}"
    [[ $du =~ ^[0-9]+$ ]] || die "-d must be a whole number of seconds (0 = one reading), got '$du'"
    [[ -z $iv || ( $iv =~ ^[0-9]+$ && $iv -gt 0 ) ]] || die "-i must be a positive whole number of seconds, got '$iv'"
    [[ -z $iv ]] || (( du > 0 )) || die "-i needs -d (how long to sample)"
    (( du > 0 )) && : "${iv:=$du}"
    [[ -z $iv ]] || (( du >= iv )) || die "-d ($du) must be at least -i ($iv)"
}

# tc_run: the capture itself, the caller's verbose, du and iv in scope: samples, summary, stderr and stdout, the
# thermcap_<UTC> files in FF_OUT_DIR, the RESULT line; exits 0 COMPLETE, 3 PARTIAL, 4 NONE
tc_run() {
    local v
    [[ -d $FF_OUT_DIR && -w $FF_OUT_DIR ]] || die "FF_OUT_DIR '$FF_OUT_DIR' is not a writable directory"
    [[ -n $(command -v ssh) ]] || die "ssh not found"

    LOCAL_IPMITOOL=; (( ${#BMCS[@]} )) && { LOCAL_IPMITOOL=$(command -v ipmitool); [[ -n $LOCAL_IPMITOOL ]] || log "ipmitool is not installed here: the bmc lines will have no data"; }
    # a password ssh login: SSH_ASKPASS reading a one-use fifo (no sshpass, never in an environment or argv); pw_transport
    # (auth.sh) checks this ssh takes it unattended, or dies
    SETSID=; (( ${#T_PW[@]} )) && pw_transport
    MODE=-; (( FF_IPMI )) && MODE=ipmi
    # a host's whole read is cut off 30 s after the ipmitool timeout (a hung sysfs read or ssh), where timeout exists
    HOST_LIMIT=$(( FF_IPMI_TIMEOUT + 30 )); TO=$(command -v timeout || command -v gtimeout)
    [[ -n $TO ]] || log "no timeout command here: a hung host would stall the capture"

    WORK=$(mktemp -d "${TMPDIR:-/tmp}/thermals.XXXXXX") || die "mktemp failed"
    trap tc_cleanup EXIT   # from here every exit removes WORK, and SOCKET_DIR once it exists
    SOCKET_DIR=$(mktemp -d /tmp/tc_ssh.XXXXXX) || die "mktemp failed"
    # BatchMode and -l are per target (rssh); ssh keeps the first value it sees for an option
    SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=5m -o "ControlPath=$SOCKET_DIR/%C"
              -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15)
    AUTH=$WORK/auth; mkdir -m 700 "$AUTH" || die "mkdir $AUTH failed"; write_askpass "$AUTH/askpass"
    echo "Label Host Source Chip Dev Sensor Temp_C High_C Crit_C Status" > "$WORK/temps.txt"
    : > "$WORK/samples"; : > "$WORK/hosts"

    local start end n=0 t0 next sp k
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "Reading temperatures on ${#TARGETS[@]} host(s)$( (( ${#BMCS[@]} )) && echo " and ${#BMCS[@]} BMC(s) out of band"): hwmon, nvidia-smi$( (( FF_IPMI )) && echo ", BMC (ipmitool, timeout ${FF_IPMI_TIMEOUT}s)")$([[ -n $iv ]] && echo ", every ${iv}s for ${du}s" || echo ", one reading"); read only"
    STOP=0; trap 'STOP=1; log "Stopping after this sample (Ctrl-C again does nothing; each host read ends within its timeout)"' INT TERM HUP
    t0=$SECONDS
    while :; do
        n=$(( n + 1 )); sample $n
        [[ -z $iv ]] && break
        (( STOP )) && { log "Stopped after $n sample(s)"; break; }
        next=$(( n * iv ))
        (( next > du )) && break
        if (( SECONDS - t0 < next )); then
            sleep $(( next - (SECONDS - t0) )) & sp=$!; wait $sp
            (( STOP )) && k=$(kill "$sp" 2>&1)   # Ctrl-C ended the wait early; the sleep is still running
        else log "sample $n took longer than -i ${iv}s; sample $(( n + 1 )) starts now"; fi
        (( STOP )) && { log "Stopped after $n sample(s)"; break; }
    done
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ); NSAMP=$n
    unreachable_targets
    # "target reason" per unreachable target: the html's Not read panel lists them (stderr only with -v)
    for i in "${UNREACH[@]}"; do echo "${TARGETS[$i]} $(awk 'NF {l = $2} END {print l}' "$WORK/unreach.$i")"; done | sort -V > "$WORK/unreachlist"
    local nt=$(( ${#TARGETS[@]} - ${#UNREACH[@]} + ${#BMCS[@]} ))

    # the summary (tc_summary.sh, shared with fabric_ferret.sh); the high = 95% of crit copy replaces temps.txt here,
    # so the jsonl carries the thresholds the flags used (10-26)
    summarize_temps "$WORK/temps.txt" "$WORK/temps.hi" "$WORK/temps_summary.txt" && mv "$WORK/temps.hi" "$WORK/temps.txt"
    awk -v ns="$NSAMP" "$VIEW_AWK" "$WORK/temps_summary.txt" > "$WORK/view"
    awk "$HOST_MAX_AWK" "$WORK/temps_summary.txt" | sort -k1,1V > "$WORK/hostmax"
    # the html's per-type tables: "group type chip dev sensor host value high crit flag", BMC first, then by type,
    # chip, device and sensor (version order, any case: Core_2 before Core_10, asic before Module0); hosts likewise
    awk '#@awk tc_main.pivot' \
        "$WORK/temps_summary.txt" | sort -k1,1n -k2,2n -k3,3 -k4,4V -k5,5V | cut -d' ' -f6- > "$WORK/pivot"
    awk 'NR > 1 && $6 != "none" {print $1}' "$WORK/temps_summary.txt" | sort -u | sort -V > "$WORK/hostorder"
    local sensors flagged nodata hwd res rc
    read -r sensors flagged nodata hwd < <(awk '#@awk tc_main.counts' "$WORK/temps_summary.txt")
    if (( sensors == 0 )); then res=NONE rc=4; elif (( nodata > 0 )); then res=PARTIAL rc=3; else res=COMPLETE rc=0; fi
    print_summary >&2
    # stdout: one row per host and source (the summary and the closing counts stay on stderr)
    if awk 'NR > 1 {f = 1} END {exit !f}' "$WORK/view"; then
        awk "$SRC_AWK" "$WORK/temps_summary.txt" | { read -r hdr; echo "$hdr"; sort -k1,1 -k2,2; } | column -t
    fi
    (( nt == 0 )) && echo "NO TEMPERATURE DATA: none of the ${#TARGETS[@]} targets took an ssh connection$( (( verbose )) || echo " (-v lists them)")" >&2
    if (( verbose && ${#UNREACH[@]} )); then
        echo "Unreachable: ${#UNREACH[@]} target(s) took no ssh connection in any sample (left out of every count and file):" >&2
        sed 's/^/  /' "$WORK/unreachlist" >&2
        echo "" >&2
    fi

    local label=${FF_LABEL:-$(awk 'NR > 1 && $6 != "none" {print $1; exit}' "$WORK/temps_summary.txt")}
    label=$(clean "${label:-${TARGETS[0]:-${BMCS[0]}}}")
    local base=$FF_OUT_DIR/thermcap_$(date -u +%Y%m%dT%H%M%SZ) f out=()
    local -a common=(-v ver="$THERMALS_VERSION" -v label="$label" -v start="$start" -v end="$end" -v res="$res" -v hwd="$hwd"
                     -v nt="$nt" -v unreach="${#UNREACH[@]}" -v ipmi="$FF_IPMI" -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" -v nsamp="$NSAMP")
    for v in "${FMTS[@]}"; do
        f=$base.$v
        case $v in
            jsonl) awk "${common[@]}" -v iv="$iv" -v du="$du" -v ito="$FF_IPMI_TIMEOUT" -v user="$FF_SSH_USER" "$JSONL_AWK" \
                       "$WORK/samples" "$WORK/hosts" "$WORK/temps.txt" "$WORK/temps_summary.txt" > "$f.tmp" ;;
            html) { printf '%s\n' "${HTML_HEAD//@TITLE@/Thermals $label}"
                    awk "${common[@]}" "$HTML_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" "$WORK/pivot" "$WORK/hostorder" "$WORK/unreachlist"
                    printf '%s\n' "$HTML_TAIL"; } > "$f.tmp" ;;
            md) awk "${common[@]}" "$MD_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" "$WORK/pivot" "$WORK/hostorder" > "$f.tmp" ;;
        esac && mv "$f.tmp" "$f" || die "could not write $f"
        out+=("$f")
    done
    # every ssh error the run saw (each failed or noisy read: "sample target rc: stderr"), when there were any: the reason
    # a host gave no data is its last line; the whole text separates a dead host from one refused under load
    local i e trc; for n in $(seq 1 "$NSAMP"); do for i in "${!TARGETS[@]}"; do
        if [[ -e $WORK/e1.$n.$i ]]; then   # the first try of a read that was retried
            printf 's%s %s rc=255 (retried): ' "$n" "${TARGETS[$i]}"; tr -d '\r' < "$WORK/e1.$n.$i" | tr '\n' '|'; echo; fi
        e=$WORK/e.$n.$i; trc=$(<"$WORK/rc.$n.$i")
        { [[ $trc != 0 ]] || [[ -s $e ]]; } || continue
        printf 's%s %s rc=%s: ' "$n" "${TARGETS[$i]}" "$trc"; if [[ -s $e ]]; then tr -d '\r' < "$e" | tr '\n' '|'; else printf '(no message)'; fi; echo
    done; done > "$base.ssh_errors.log.tmp"
    if [[ -s $base.ssh_errors.log.tmp ]]; then mv "$base.ssh_errors.log.tmp" "$base.ssh_errors.log"; out+=("$base.ssh_errors.log"); else rm -f "$base.ssh_errors.log.tmp"; fi
    for f in "${out[@]}"; do log "Wrote $f"; done
    log "To copy here from a jump host: scp '$(hostname -f 2>&1):$(cd "$(dirname "${out[0]}")" && pwd)/${base##*/}.*' ."
    # the closing count: unreachable (no ssh connection) and unavailable (reachable, no reading at all)
    if (( ${#UNREACH[@]} || nt - hwd )); then
        echo "Unreachable: ${#UNREACH[@]} (no ssh connection$( (( ${#UNREACH[@]} && ! verbose )) && echo "; -v lists them")), unavailable: $(( nt - hwd )) (connected, no readings)" >&2
    fi
    echo "RESULT data=$res hosts=$hwd/$nt sensors=$sensors flagged=$flagged nodata=$nodata unreachable=${#UNREACH[@]}" >&2
    exit $rc
}
