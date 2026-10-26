#!/usr/bin/env bash
# thermals_capture: every hwmon temperature and the BMC's (ipmitool) on a set of hosts, read only, over ssh.
# One snapshot by default, or a sample every -i seconds for -d seconds. Output: any of .jsonl, .html, .md.
# Standalone companion to fabric_ferret.sh: same host syntax and FF_ settings, same reader and flags.

THERMALS_VERSION=1.0

usage() {
    cat <<'EOF'
Usage: FF_HOSTS=<targets> ./thermals_capture.sh [-o jsonl,html,md] [-d seconds [-i seconds]] [-v]
       ./thermals_capture.sh -t file [options]           (targets from the file alone)
       ./thermals_capture.sh --list [-t file]            (print expanded targets, no ssh)
Targets come from FF_HOSTS or from -t, not both.
From a jump host (settings ride in the remote command):
       ssh jump "FF_HOSTS=10.1.0.0/24 bash -s -- -o jsonl,md" < thermals_capture.sh
       The run ends by printing the scp line for the file(s) it left on the jump host.
Read only: each host reads /sys/class/hwmon (CPU, NVMe, NIC…; no package needed), where they are installed
`nvidia-smi -q -d TEMPERATURE` (NVIDIA GPUs, which hwmon doesn't show) and `ipmitool sensor` (the BMC: inlet,
GPU board, drives, DIMMs…). Nothing is installed, loaded or changed. Every sensor is typed by what it measures
(inlet, cpu, gpu, mem, nvme, nic, other), whichever of the three read it.

Options
  -t FILE          targets, one per line: <type>,<host>,<login>,<pw> (# comments). type is host or bmc. A line
                   with no comma is a host with the defaults, so a plain host list works; a line whose host
                   field is empty or starts with # is skipped.
                     host  an ssh target: IP, hostname, CIDR or range (as FF_HOSTS); hwmon + in-band ipmitool
                     bmc   one BMC address (no CIDR or range), read from here: ipmitool -I lanplus sensor
                   No login: the current user. No pw: key (passwordless) ssh; for a bmc, an empty password.
                   The pw is everything after the third comma. Passwords reach ssh only through the environment
                   (sshpass -e if installed, else SSH_ASKPASS: OpenSSH 8.4+ here) and ipmitool through -E,
                   never a command line, and are never written out. chmod 600 the file (warned otherwise).
                   A non-root host login with a pw runs ipmitool with sudo -S and that pw (sent on the ssh
                   stdin stream, not argv); without a pw, sudo -n. A line naming one host sets its login and pw
                   even if an earlier range line covered it. -t or FF_HOSTS, not both.
  -o LIST         output files, comma separated, any of jsonl (default), html, md:
                   thermcap_<UTC>.jsonl|.html|.md in FF_OUT_DIR (jsonl: every reading; html, md: the summary)
  -d SECONDS       0 (default): one point-in-time reading. Above 0: read now and again SECONDS later, giving
                   each sensor's first, min, max and last (and the rise flag)
  -i SECONDS       with -d, read every SECONDS instead (the first at 0, the last at or before -d)
  -v               list on stderr the unreachable targets: those that took no ssh connection (timed out, refused,
                   no route, name not found) in any sample. They are always left out of the counts and files,
                   silently without -v (RESULT unreachable=N counts them). A target that connects but fails
                   (auth refused, cut off, no hwmon…) is always reported as no data.
  -h, --help       this text

Settings (the same names as fabric_ferret.sh; default)
  FF_HOSTS         ssh targets (key ssh as FF_SSH_USER; sudo -n where not root), comma or space separated, any mix of: 10.1.0.5,node07 | 10.1.0.0/24 |
                   10.1.0.10-10.1.1.20 | 10.1.0.10-40 | 10.1.0-1.10-40 | @hosts.txt (# comments)
  FF_SSH_USER      ssh user (root); a non-root user reads hwmon as itself and runs ipmitool with sudo -n
  FF_SSH_PARALLEL  ssh sessions at once (64)
  FF_MAX_TARGETS   refuse to expand FF_HOSTS beyond this (4096)
  FF_IPMI (1)      also read each host's BMC with in-band ipmitool sensor; 0 = hwmon only (-t bmc lines are
                   read regardless)
  FF_IPMI_TIMEOUT  seconds per ipmitool read (60); a whole host read is cut off 30 s after it
  FF_TEMP_MARGIN   a sensor within this many °C of its high threshold is flagged near (5)
  FF_TEMP_RISE     a sensor whose highest sample is more than this many °C above its first is flagged rise (10)
  FF_LABEL         name in the report title inside the files (the first host with readings)
  FF_OUT_DIR       where the output goes (.)

Flags per sensor, worst first: crit (at or above crit, or BMC status cr/nr), high (at or above high, or BMC
nc), near (within FF_TEMP_MARGIN of high), then +rise. A threshold of 0 counts as unset. A host or source that
connected but gave no reading (auth refused, cut off, no hwmon, no ipmitool, sudo refused, ipmitool timed out) gets a nodata record
with the reason: no data is never shown as cool.

Output: stdout gets one row per host and source (hwmon, with nvidia-smi's GPUs, and ipmi): "Host Source Sensors Inlet CPU GPU Mem NVMe
NIC Other Flags", the hottest reading of each type; stderr gets the progress, the flagged sensors, the no-data
list and the result. Every sensor, one row each, is in the files (-o).
When either is above zero, the line before it counts the unreachable targets (no ssh connection) and the
unavailable ones (connected, no reading at all).
Result: the last line is "RESULT data=COMPLETE|PARTIAL|NONE hosts=r/t sensors=N flagged=F nodata=X unreachable=U"
(r = hosts with at least one reading, t = targets less the U unreachable); exit 0 = COMPLETE, 3 = PARTIAL (some host or source gave no data),
4 = NONE (no reading at all), 2 = bad input. Ctrl-C or TERM while sampling stops after the current sample and
writes what was read (exit 0, 3 or 4 as above).
EOF
}

die() { echo "ERROR: $*" >&2; echo "RESULT data=STOPPED ($*)" >&2; exit 2; }
log() { echo "# $*" >&2; }

# ---------- target expansion (pure bash, no ssh; as in fabric_ferret.sh) ----------

is_ip() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
ip2int() { local IFS=.; set -- $1; echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 )); }
int2ip() { echo "$(( $1 >> 24 & 255 )).$(( $1 >> 16 & 255 )).$(( $1 >> 8 & 255 )).$(( $1 & 255 ))"; }

# CIDR -> "network broadcast" as integers
cidr_bounds() {
    local ip=${1%/*} len=${1#*/}
    [[ $1 == */* ]] && is_ip "$ip" && [[ $len =~ ^[0-9]{1,2}$ ]] && (( 10#$len <= 32 )) || return 1
    local mask=$(( (0xFFFFFFFF << (32 - 10#$len)) & 0xFFFFFFFF ))
    local net=$(( $(ip2int "$ip") & mask ))
    echo "$net $(( net | (~mask & 0xFFFFFFFF) ))"
}

declare -a TARGETS=()
INPUT_RANGES=0   # 1 once FF_HOSTS has a CIDR or range: unanswered addresses are then normal
declare -A _SEEN=()
_emit() {
    [[ -n ${_SEEN[$1]+x} ]] && return
    _SEEN[$1]=1; TARGETS+=("$1")
    (( ${#TARGETS[@]} <= FF_MAX_TARGETS )) || die "$EXPANDING expands past FF_MAX_TARGETS=$FF_MAX_TARGETS; narrow it or raise the cap"
}
_need() {  # refuse a range before looping over it
    (( ${#TARGETS[@]} + $1 <= FF_MAX_TARGETS )) || die "'$2' adds $1 targets, past FF_MAX_TARGETS=$FF_MAX_TARGETS"
}

expand_entry() {
    local e=$1 b lo hi n
    [[ $e == *:* ]] && die "IPv6 is not supported: '$e'"
    if [[ $e == */* ]]; then
        b=$(cidr_bounds "$e") || die "bad CIDR: '$e'"
        lo=${b% *}; hi=${b#* }
        (( hi - lo >= 2 )) && { lo=$(( lo + 1 )); hi=$(( hi - 1 )); }
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^([0-9.]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}  # is_ip resets BASH_REMATCH
        is_ip "$from" && is_ip "$to" || die "bad IP range: '$e'"
        lo=$(ip2int "$from"); hi=$(ip2int "$to")
        (( lo <= hi )) || die "range runs backwards: '$e'"
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?$ ]]; then
        local -a lo4 hi4; local IFS=. o i count=1 a b c d
        local -a oct=($e)
        for i in 0 1 2 3; do
            o=${oct[$i]}
            lo4[$i]=$(( 10#${o%-*} )); hi4[$i]=$(( 10#${o#*-} ))
            (( lo4[i] <= hi4[i] && hi4[i] <= 255 )) || die "bad octet '$o' in '$e'"
            count=$(( count * (hi4[i] - lo4[i] + 1) ))
        done
        unset IFS
        (( count > 1 )) && INPUT_RANGES=1
        _need $count "$e"
        for (( a = lo4[0]; a <= hi4[0]; a++ )); do for (( b = lo4[1]; b <= hi4[1]; b++ )); do
        for (( c = lo4[2]; c <= hi4[2]; c++ )); do for (( d = lo4[3]; d <= hi4[3]; d++ )); do
            _emit "$a.$b.$c.$d"
        done; done; done; done
    elif [[ $e =~ ^[0-9.-]+$ ]]; then
        die "not a valid IP, range or CIDR: '$e'"
    elif [[ $e =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _emit "$e"
    else
        die "not a hostname, IP, range or CIDR: '$e'"
    fi
}

# split on commas and whitespace, no globbing
_words() { local IFS=$', \t\n'; set -f; WORDS=($1); set +f; }

# expand_targets value [setting name, FF_HOSTS]: fills TARGETS and INPUT_RANGES
expand_targets() {
    local w line
    EXPANDING=${2:-FF_HOSTS}; TARGETS=(); _SEEN=(); INPUT_RANGES=0
    [[ -n $1 ]] || die "$EXPANDING is empty"
    _words "$1"
    local -a top=("${WORDS[@]}")
    for w in "${top[@]}"; do
        if [[ $w == @* ]]; then
            [[ -r ${w#@} ]] || die "cannot read host file '${w#@}'"
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%%#*}
                _words "$line"
                for e in "${WORDS[@]}"; do
                    [[ $e == @* ]] && die "nested @file not supported: '$e' in ${w#@}"
                    expand_entry "$e"
                done
            done < "${w#@}"
        else
            expand_entry "$w"
        fi
    done
    (( ${#TARGETS[@]} > 0 )) || die "$EXPANDING expanded to zero targets"
}

# ---------- the reader each host runs ----------

# Temperatures, read only: every hwmon sensor (kernel sysfs; the data lm-sensors reads, no package needed) as
# "@@HWMON host chip dev sensor milli_c high crit" (dev: the NIC's netdev, else the device; thresholds in milli-C
# or -), "@@HWMON host - - none - - -" when there is none. $1 = ipmi adds the BMC's readings (ipmitool sensor,
# timeout $2) as "@@IPMI host sensor c status high crit", or "@@IPMI host none <why>". FF_SYSFS is a test hook.
# The hwmon part is fabric_ferret.sh's, line for line (a harness check keeps them equal); here ipmitool alone
# gets sudo -n, so a host that refuses sudo still gives its hwmon readings.
read -r -d '' TEMP_SCRIPT <<'EOF'
h=$(hostname -s); sys=${FF_SYSFS:-/sys}; n=0
num() { case $1 in ''|*[!0-9-]*) echo -; ;; *) echo "$1" ;; esac; }
for d in "$sys"/class/hwmon/hwmon*; do
    [ -d "$d" ] || continue
    chip=-; [ -r "$d/name" ] && chip=$(cat "$d/name" 2>&1); chip=$(printf '%s' "${chip:--}" | tr -c 'A-Za-z0-9_.:-' '_')
    dev=-; l=$(readlink "$d/device" 2>&1) && dev=${l##*/}
    for x in "$d"/device/net/*; do [ -e "$x" ] && dev=${x##*/}; break; done
    for t in "$d"/temp*_input; do
        [ -r "$t" ] || continue
        b=${t%_input}; v=$(num "$(cat "$t" 2>&1)"); [ "$v" = - ] && continue
        lb=${b##*/}; [ -r "${b}_label" ] && lb=$(cat "${b}_label" 2>&1)
        hi=-; [ -r "${b}_max" ] && hi=$(num "$(cat "${b}_max" 2>&1)")
        cr=-; [ -r "${b}_crit" ] && cr=$(num "$(cat "${b}_crit" 2>&1)")
        echo "@@HWMON $h $chip $dev $(printf '%s' "$lb" | tr -c 'A-Za-z0-9_.:-' '_') $v $hi $cr"; n=$(( n + 1 ))
    done
done
[ "$n" -gt 0 ] || echo "@@HWMON $h - - none - - -"
# NVIDIA GPUs (not in hwmon), read only: nvidia-smi -q -d TEMPERATURE as "@@GPU host gpu<i> core|memory c high crit"
# (high = Max Operating, crit = Shutdown; newer drivers give these as T.Limit margins instead, turned absolute:
# margin = degrees left to T.Limit, so high = current + margin - max-op offset, crit = current + margin - shutdown
# offset), "@@GPU host none <why>" if it fails
if [ -n "$(command -v nvidia-smi)" ]; then
    if [ -n "$(command -v timeout)" ]; then g=$(timeout "${2:-60}" nvidia-smi -q -d TEMPERATURE 2>&1); else g=$(nvidia-smi -q -d TEMPERATURE 2>&1); fi; grc=$?
    r=$(printf '%s\n' "$g" | awk -v h="$h" 'function v(s) { sub(/^[^:]*: */, "", s); sub(/ *C *$/, "", s); return s ~ /^-?[0-9.]+$/ ? s : "-" }
        function out() { if (g < 0) return
            if (gh == "-" && gc != "-" && tm != "-" && to != "-") gh = gc + tm - to
            if (gx == "-" && gc != "-" && tm != "-" && ts != "-") gx = gc + tm - ts
            if (gc != "-") print "@@GPU", h, "gpu" g, "core", gc, gh, gx; if (mc != "-") print "@@GPU", h, "gpu" g, "memory", mc, mh, "-" }
        /^GPU [0-9A-Fa-f]+:/ { out(); g++; gc = gh = gx = mc = mh = tm = to = ts = "-"; next }
        /GPU T\.Limit Temp/ { tm = v($0); next } /GPU Max Operating T\.Limit Temp/ { to = v($0); next } /GPU Shutdown T\.Limit Temp/ { ts = v($0); next }
        /T\.Limit/ { next }
        /GPU Current Temp/ { gc = v($0) } /GPU Max Operating Temp/ { gh = v($0) } /GPU Shutdown Temp/ { gx = v($0) }
        /Memory Current Temp/ { mc = v($0) } /Memory Max Operating Temp/ { mh = v($0) }
        BEGIN { g = -1 } END { out() }')
    if [ -n "$r" ]; then echo "$r"
    else echo "@@GPU $h none rc=${grc}_$(printf '%s' "$g" | head -n 1 | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"; fi
fi
[ "$1" = ipmi ] || exit 0
if [ -z "$(command -v ipmitool)" ]; then echo "@@IPMI $h none ipmitool_not_installed"; exit 0; fi
# not root: sudo -S with the login's password when the -t file gave one (TC_PW, read from stdin ahead of this
# script, never argv), else sudo -n. $0 of the inner sh picks the mode.
s=; [ "$(id -u)" = 0 ] || { s=n; [ -n "${TC_PW+x}" ] && s=S; }; export TC_PW
c='case $0 in S) printf "%s\n" "$TC_PW" | sudo -S -p "" ipmitool sensor ;; n) sudo -n ipmitool sensor ;; *) ipmitool sensor ;; esac'
if [ -n "$(command -v timeout)" ]; then out=$(timeout "${2:-60}" sh -c "$c" "${s:--}" 2>&1); else out=$(sh -c "$c" "${s:--}" 2>&1); fi; rc=$?
# ipmitool sensor: name | value | units | status | lnr | lc | lnc | unc | uc | unr (unc = high, uc = crit)
r=$(printf '%s\n' "$out" | awk -F'|' -v h="$h" '{for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i)}
    $3 == "degrees C" && $2 ~ /^-?[0-9.]+$/ {nm = $1; gsub(/[^A-Za-z0-9_.:-]/, "_", nm)
        print "@@IPMI", h, nm, $2, ($4 == "" ? "-" : $4), ($8 ~ /^-?[0-9.]+$/ ? $8 : "-"), ($9 ~ /^-?[0-9.]+$/ ? $9 : "-")}')
if [ -n "$r" ]; then echo "$r"
elif [ "$rc" = 124 ]; then echo "@@IPMI $h none ipmitool_timed_out_after_${2:-60}s"
elif [ -n "$s" ] && printf '%s' "$out" | grep -q '^sudo:'; then echo "@@IPMI $h none sudo_refused_$(printf '%s' "$out" | grep '^sudo:' | head -n 1 | tr -d '\n' | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"
else echo "@@IPMI $h none rc=${rc}_$(printf '%s' "$out" | head -n 1 | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"; fi
EOF

# ---------- collection ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
wait_all() { while [[ -n $(jobs -rp) ]]; do wait; done; }   # a trapped Ctrl-C ends a bare wait early
tmo() { if [[ -n $TO ]]; then "$TO" "$HOST_LIMIT" "$@"; else "$@"; fi; }
clean() { printf '%s' "${1//$'\r'/}" | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80; }   # ssh ends its errors with \r\n

# sample n: TEMP_SCRIPT on every target at once, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (sensor none = no data, why in status).
# A target with no answer at all gets a none row per source, the reason from ssh's exit code and last error line.
# rssh i: ssh to target i as its login, with its password from the environment when it has one (sshpass -e, else
# SSH_ASKPASS), never on a command line. Runs in its own background subshell, so the exports stay there.
rssh() {
    local i=$1; shift
    local -a o=("${SSH_OPTS[@]}" -l "${T_LOGIN[$i]}")
    if [[ -z ${T_PW[$i]+x} ]]; then tmo ssh "${o[@]}" -o BatchMode=yes "${TARGETS[$i]}" "$@"; return; fi
    o+=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
    if [[ -n $SSHPASS_CMD ]]; then export SSHPASS=${T_PW[$i]}; tmo "$SSHPASS_CMD" -e ssh "${o[@]}" "${TARGETS[$i]}" "$@"
    else export THERMCAP_PW=${T_PW[$i]} SSH_ASKPASS=$WORK/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none}
        tmo ssh "${o[@]}" "${TARGETS[$i]}" "$@"; fi
}

# rbmc j: the BMC's sensors out of band from here (ipmitool lanplus), the password in IPMI_PASSWORD (-E)
rbmc() {
    local j=$1
    export IPMI_PASSWORD=${B_PW[$j]}
    if [[ -n $TO ]]; then "$TO" "$FF_IPMI_TIMEOUT" ipmitool -I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}" -E sensor <<<""
    else ipmitool -I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}" -E sensor <<<""; fi
}

# ipmitool sensor output -> temps rows for one BMC (as the reader's @@IPMI lines), or one none row with the reason
BMC_AWK='BEGIN { FS = "|" }
{ for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i) }
NR == 1 { first = $0 }
$3 == "degrees C" && $2 ~ /^-?[0-9.]+$/ { nm = $1; gsub(/[^A-Za-z0-9_.:-]/, "_", nm); n++
    print t, h, "ipmi", "bmc", "lanplus", nm, sprintf("%.1f", $2), ($8 ~ /^-?[0-9.]+$/ ? $8 : "-"), ($9 ~ /^-?[0-9.]+$/ ? $9 : "-"), ($4 == "" ? "-" : $4) }
END { if (!n) { w = (rc == 124 ? "ipmitool_timed_out_after_" to "s" : "rc=" rc "_" first); gsub(/[^A-Za-z0-9_.:=-]/, "_", w)
          print t, h, "ipmi", "bmc", "lanplus", "none", "-", "-", "-", substr(w, 1, 120) } }'

sample() {
    local n=$1 lab=s$1 i o rc why host j
    echo "$lab $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/samples"
    for i in "${!TARGETS[@]}"; do
        throttle
        # a password login's password rides ahead of the reader on stdin (printf is a builtin: no argv, no temp file);
        # bash -s reads the script a line at a time, so the first line's read takes the second line
        { { [[ -n ${T_PW[$i]+x} ]] && printf 'IFS= read -r TC_PW\n%s\n' "${T_PW[$i]}"; printf '%s\n' "$TEMP_SCRIPT"; } \
              | rssh "$i" bash -s -- "$MODE" "$FF_IPMI_TIMEOUT" > "$WORK/o.$n.$i" 2> "$WORK/e.$n.$i"
          echo "${PIPESTATUS[1]}" > "$WORK/rc.$n.$i"; } &
    done
    for j in "${!BMCS[@]}"; do
        [[ -n $LOCAL_IPMITOOL ]] || break
        throttle
        { rbmc "$j" > "$WORK/b.$n.$j" 2>&1; echo $? > "$WORK/brc.$n.$j"; } &
    done
    wait_all
    for j in "${!BMCS[@]}"; do
        echo "$n ${BMCS[$j]} ${BMCS[$j]} bmc ${B_LOGIN[$j]} $( [[ -n ${B_PW[$j]} ]] && echo password || echo none)" >> "$WORK/hosts"
        if [[ -z $LOCAL_IPMITOOL ]]; then
            echo "$lab ${BMCS[$j]} ipmi bmc lanplus none - - - ipmitool_not_installed_here"; continue
        fi
        awk -v t="$lab" -v h="${BMCS[$j]}" -v rc="$(cat "$WORK/brc.$n.$j" 2>&1)" -v to="$FF_IPMI_TIMEOUT" "$BMC_AWK" "$WORK/b.$n.$j"
    done >> "$WORK/temps.txt"
    for i in "${!TARGETS[@]}"; do
        o=$WORK/o.$n.$i; rc=$(cat "$WORK/rc.$n.$i" 2>&1)
        host=$(awk '$1 ~ /^@@(HWMON|IPMI)$/ {print $2; exit}' "$o")
        if [[ -n $host ]]; then : > "$WORK/answered.$i"; else host=${TARGETS[$i]}; fi
        # a target that took no connection: set aside, silent unless -v (see unreachable_targets)
        if [[ $rc == 255 ]] && grep -qE "$NO_CONNECT_RE" "$WORK/e.$n.$i"; then
            echo "$n ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")")" >> "$WORK/unreach.$i"; continue
        fi
        echo "$n ${TARGETS[$i]} $host host ${T_LOGIN[$i]} $( [[ -n ${T_PW[$i]+x} ]] && echo password || echo key)" >> "$WORK/hosts"
        case $rc in
            0) why=no_output ;;
            124) why=ssh_cut_off_after_${HOST_LIMIT}s ;;
            255) why=ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")") ;;
            *) why=remote_rc=${rc}_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")") ;;
        esac
        awk -v t="$lab" -v host="$host" -v why="$why" -v ipmi="$([[ $MODE == ipmi ]] && echo 1 || echo 0)" '
            function c(m) { return m == "-" ? "-" : sprintf("%.1f", m / 1000) }
            $1 == "@@HWMON" { hw = 1; print t, $2, "hwmon", $3, $4, $5, ($5 == "none" ? "-" : c($6)), c($7), c($8), ($5 == "none" ? "no_hwmon_temperature_sensors" : "-") }
            $1 == "@@GPU" && $3 == "none" { print t, $2, "gpu", "nvidia", "-", "none", "-", "-", "-", $4 }
            $1 == "@@GPU" && $3 != "none" { print t, $2, "gpu", "nvidia", $3, $4, sprintf("%.1f", $5), $6, $7, "-" }
            $1 == "@@IPMI" { im = 1 }
            $1 == "@@IPMI" && $3 == "none" { print t, $2, "ipmi", "bmc", "-", "none", "-", "-", "-", $4 }
            $1 == "@@IPMI" && $3 != "none" { print t, $2, "ipmi", "bmc", "-", $3, $4, $6, $7, $5 }
            END { if (!hw) print t, host, "hwmon", "-", "-", "none", "-", "-", "-", why
                  if (ipmi && !im) print t, host, "ipmi", "bmc", "-", "none", "-", "-", "-", why }' "$o" >> "$WORK/temps.txt"
    done
}

# load_target_file file: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped). type host: an ssh
# target (IP, name, CIDR or range, as FF_HOSTS); bmc: one BMC address read out of band. No login = the current
# user; no pw = key login (host) or an empty password (bmc). The pw is everything after the third comma, verbatim.
# Errors name the line number, never its text (it may hold a password).
load_target_file() {
    local f=$1 line ln=0 ty h lg pw rest n0 k me
    [[ -r $f && -f $f ]] || die "-t: cannot read '$f'"
    me=$(id -un)
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *,* ]] || line="host,$line"   # a bare line is a host with the defaults: a plain host list works
        [[ $line =~ ^[^,]*,[[:space:]]*(#|,*[[:space:]]*$) ]] && continue   # "host,# ...", "host," : commented out or empty
        ty=${line%%,*}; rest=${line#*,}
        h=${rest%%,*}; [[ $rest == *,* ]] && rest=${rest#*,} || rest=
        lg=${rest%%,*}; [[ $rest == *,* ]] && pw=${rest#*,} || pw=
        ty=${ty//[[:space:]]/}; h=${h//[[:space:]]/}; lg=${lg//[[:space:]]/}; lg=${lg:-$me}
        [[ $lg =~ ^[A-Za-z0-9._@-]+$ ]] || die "-t $f line $ln: bad login (letters, digits . _ @ - only)"
        [[ -n $pw ]] && HAVE_PW=1
        case $ty in
            host)
                [[ -n $h ]] || die "-t $f line $ln: no host"
                n0=${#TARGETS[@]}; EXPANDING="-t $f line $ln"
                if [[ -n ${_SEEN[$h]+x} ]]; then   # one host already listed (FF_HOSTS, a range): this line's login/pw win
                    for k in "${!TARGETS[@]}"; do [[ ${TARGETS[$k]} == "$h" ]] && break; done
                    T_LOGIN[$k]=$lg; unset 'T_PW[k]'; [[ -n $pw ]] && T_PW[$k]=$pw; continue
                fi
                expand_entry "$h"
                for (( k = n0; k < ${#TARGETS[@]}; k++ )); do T_LOGIN[$k]=$lg; [[ -n $pw ]] && T_PW[$k]=$pw; done ;;
            bmc)
                is_ip "$h" || [[ $h =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || die "-t $f line $ln: a bmc line takes one IP or hostname (no CIDR or range)"
                BMCS+=("$h"); B_LOGIN+=("$lg"); B_PW+=("$pw") ;;
            *) die "-t $f line $ln: type must be host or bmc" ;;
        esac
    done < "$f"
    if (( HAVE_PW )); then
        local p; p=$(ls -ln "$f" | awk '{print $1}')
        [[ ${p:4:6} == ------ ]] || log "WARNING: $f holds passwords and is readable by group or others ($p); chmod 600 it"
    fi
}

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

# temps_summary.txt, one row per sensor over the samples: "Host Source Type Chip Dev Sensor First_C Max_C
# Last_C High_C Crit_C Flag". Type cpu|nvme|nic|bmc|other. Flag (worst first): crit (at or above crit, or the BMC says
# cr/nr), high (at or above high, or BMC nc), near (within FF_TEMP_MARGIN of high), then +rise (max - first over
# FF_TEMP_RISE); "-" when none. A threshold of 0 counts as unset. A host/source with no reading at all gets one row,
# Sensor none, Flag nodata:<why>. (fabric_ferret.sh's TEMP_SUM_AWK, unchanged; a harness check keeps them equal.)
TEMP_SUM_AWK='
NR == 1 { next }
$6 == "none" { nd[$2 SUBSEP $3] = $10; next }
{ k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6; v = $7 + 0; got[$2 SUBSEP $3] = 1
  if (!(k in mx)) { fi[k] = v; mx[k] = v; ord[++n] = k } else if (v > mx[k]) mx[k] = v
  la[k] = v; if ($8 != "-" && $8 + 0 > 0) hi[k] = $8 + 0; if ($9 != "-" && $9 + 0 > 0) cr[k] = $9 + 0; if ($3 == "ipmi") { if ($10 ~ /^(cr|nr)/) bc[k] = 2; else if ($10 ~ /^nc/ && bc[k] < 1) bc[k] = 1 } }
function ty(src, chip, dev) { if (src == "ipmi") return "bmc"; if (chip ~ /^(coretemp|k10temp|zenpower|cpu_thermal)$/) return "cpu"
    if (chip ~ /^nvme/) return "nvme"; if (chip ~ /^(mlx5|ice|bnxt|i40e|ixgbe|igb|tg3|qede|nfp)/ || dev ~ /^(en|eth|ib|bond)/) return "nic"; return "other" }
END { print "Host Source Type Chip Dev Sensor First_C Max_C Last_C High_C Crit_C Flag"
    for (i = 1; i <= n; i++) { k = ord[i]; split(k, p, SUBSEP); f = "-"
        if (bc[k] == 2 || ((k in cr) && mx[k] >= cr[k])) f = "crit"
        else if (bc[k] == 1 || ((k in hi) && mx[k] >= hi[k])) f = "high"
        else if ((k in hi) && mx[k] >= hi[k] - margin) f = "near"
        if (mx[k] - fi[k] > rise) f = (f == "-" ? "" : f "+") "rise"
        printf "%s %s %s %s %s %s %.1f %.1f %.1f %s %s %s\n", p[1], p[2], ty(p[2], p[3], p[4]), p[3], p[4], p[5], fi[k], mx[k], la[k],
               ((k in hi) ? hi[k] : "-"), ((k in cr) ? cr[k] : "-"), f }
    for (x in nd) if (!(x in got)) { split(x, p, SUBSEP); print p[1], p[2], "-", "-", "-", "none", "-", "-", "-", "-", "-", "nodata:" nd[x] } }'

# ---------- output ----------

# Type by what a sensor measures, whatever read it: GPUs (nvidia-smi, amdgpu) are gpu; a BMC sensor is typed by its
# name (inlet/ambient, gpu/hbm/nvlink/hgx, nvme/ssd/m.2/drive, dimm/mem, nic/aoc/ocp/cx/port, cpu/proc/soc, else
# other); hwmon drivetemp is nvme, jc42/spd5118 mem. Appends Min_C (the lowest sample) as column 13. Reads temps.txt
# then temps_summary.txt (fabric_ferret's TEMP_SUM_AWK stays unchanged).
TYPE_AWK='
FILENAME == ARGV[1] { if (FNR > 1 && $6 != "none") { k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6; v = $7 + 0; if (!(k in mn) || v < mn[k]) mn[k] = v } next }
FNR == 1 { print $0, "Min_C"; next }
$6 == "none" { print $0, "-"; next }
{ s = tolower($6)
  if ($2 == "gpu") $3 = "gpu"
  else if ($2 == "ipmi") $3 = s ~ /inlet|ambient/ ? "inlet" : s ~ /gpu|hbm|nvlink|nvsw|hgx/ ? "gpu" : s ~ /nvme|ssd|m\.?2|drive|disk/ ? "nvme" : s ~ /dimm|mem/ ? "mem" : s ~ /nic|aoc|ocp|cx[0-9]|lom|port/ ? "nic" : s ~ /cpu|proc|soc/ ? "cpu" : "other"
  else if ($4 ~ /^(amdgpu|nouveau)/) $3 = "gpu"
  else if ($4 ~ /^drivetemp/) $3 = "nvme"
  else if ($4 ~ /^(jc42|spd5118)/) $3 = "mem"
  print $0, sprintf("%.1f", mn[$1 SUBSEP $2 SUBSEP $4 SUBSEP $5 SUBSEP $6]) }'

# per host the hottest reading of each type and its flags: "Host Inlet CPU GPU Mem NVMe NIC Other Flags"
HOST_MAX_AWK='NR > 1 && $6 != "none" {if (!(($1, $3) in m) || $8 > m[$1, $3]) m[$1, $3] = $8; hs[$1] = 1; if ($12 != "-" && index("," fl[$1] ",", "," $3 ":" $12 ",") == 0) fl[$1] = fl[$1] (fl[$1] == "" ? "" : ",") $3 ":" $12}
    END {split("inlet cpu gpu mem nvme nic other", ty, " ")
         for (x in hs) { l = x; for (i = 1; i <= 7; i++) l = l " " (((x, ty[i]) in m) ? m[x, ty[i]] : "-"); print l, (x in fl ? fl[x] : "-") } }'
HOST_MAX_HDR="Host Inlet CPU GPU Mem NVMe NIC Other Flags"

# stdout: one row per host and source (hwmon, which takes nvidia-smi's GPUs too, and ipmi), the hottest reading
# of each type and the flags
SRC_AWK='NR > 1 && $6 != "none" { k = $1 " " ($2 == "gpu" ? "hwmon" : $2); if (!(k in n)) ord[++nk] = k; n[k]++
    if (!((k, $3) in m) || $8 > m[k, $3]) m[k, $3] = $8
    if ($12 != "-" && index("," fl[k] ",", "," $3 ":" $12 ",") == 0) fl[k] = fl[k] (fl[k] == "" ? "" : ",") $3 ":" $12 }
    END { split("inlet cpu gpu mem nvme nic other", ty, " "); print "Host Source Sensors Inlet CPU GPU Mem NVMe NIC Other Flags"
          for (i = 1; i <= nk; i++) { k = ord[i]; l = k " " n[k]; for (j = 1; j <= 7; j++) l = l " " (((k, ty[j]) in m) ? m[k, ty[j]] : "-"); print l, (k in fl ? fl[k] : "-") } }'

# the sensor rows as shown: one sample "... Sensor Temp High Crit Flag", several "... Sensor First Min Max Last High
# Crit Flag" (no-data rows left out; the flag is always the last column)
VIEW_AWK='function f(x) { return x == "-" ? x : sprintf("%.1f", x) }
NR == 1 { print "Host Source Type Chip Dev Sensor", (ns > 1 ? "First Min Max Last" : "Temp"), "High Crit Flag"; next }
$12 ~ /^nodata/ { next }
ns > 1 { print $1, $2, $3, $4, $5, $6, f($7), f($13), f($8), f($9), f($10), f($11), $12; next }
{ print $1, $2, $3, $4, $5, $6, f($8), f($10), f($11), $12 }'

# the 2 a.m. view, on stderr: counts, the per-host table, flagged sensors, every no-data host and source
print_summary() {
    local ts=$WORK/temps_summary.txt
    echo ""
    local fk=10 mk=7; (( NSAMP > 1 )) && { fk=13; mk=9; }   # flag and max columns of the view
    echo "Temperatures, $( (( NSAMP > 1 )) && echo "$NSAMP samples" || echo "one reading") (hwmon, GPUs via nvidia-smi$( (( FF_IPMI )) && echo ", BMC via ipmitool"); flags: crit, high, near = within ${FF_TEMP_MARGIN}C of high$( (( NSAMP > 1 )) && echo ", rise = up more than ${FF_TEMP_RISE}C over the samples")):"
    awk 'NR > 1 && $6 != "none" {n++; if (!($1 in h)) {h[$1] = 1; nh++}; if ($12 != "-") {f++; if (!($1 in fh)) {fh[$1] = 1; nf++}}}
         END {printf "  %d sensors on %d hosts; %d flagged on %d hosts\n", n, nh, f, nf}' "$ts"
    if awk 'NR > 1 && $NF != "-" {f = 1} END {exit !f}' "$WORK/view"; then
        echo "  Flagged sensors:"
        { head -n 1 "$WORK/view"; awk 'NR > 1 && $NF != "-"' "$WORK/view" | sort -k${fk},${fk} -k${mk},${mk}nr; } | column -t | sed 's/^/    /'
    fi
    awk 'NR > 1 && $12 ~ /^nodata/ {printf "  NO TEMPERATURE DATA: %s %s (%s)\n", $1, $2, substr($12, 8)}' "$ts" | sort
    echo ""
}

# one JSON object per line: run, host (one per target), sample, reading, sensor (the summary), nodata, result.
# Strings are already [A-Za-z0-9_.:=-] (the reader and clean() map the rest to _); q() escapes anyway.
JSONL_AWK='
function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
function nm(x) { return (x == "-" || x == "") ? "null" : sprintf("%.1f", x) }
FILENAME == ARGV[1] { st[$1] = $2; sord[++ns] = $1; next }
FILENAME == ARGV[2] { k = $4 " " $2; if (!(k in tg)) { tord[++nx] = k; tt[k] = $4; tn[k] = $2; tl[k] = $5; ta[k] = $6 }
    if (!(k in tg) || tg[k] == $2) tg[k] = $3; next }
FILENAME == ARGV[3] { if (FNR == 1) {
        printf "{\"type\":\"run\",\"tool\":\"thermals_capture\",\"version\":%s,\"label\":%s,\"start\":%s,\"end\":%s,\"samples\":%d,\"interval_s\":%s,\"duration_s\":%s,\"ipmi\":%s,\"ipmi_timeout_s\":%s,\"temp_margin_c\":%s,\"temp_rise_c\":%s,\"ssh_user\":%s,\"targets\":%d,\"unreachable\":%d}\n", q(ver), q(label), q(start), q(end), ns, (iv == "" ? "null" : iv), (du == "" ? "null" : du), ipmi, ito, margin, rise, q(user), nt, unreach
        for (i = 1; i <= nx; i++) { k = tord[i]
            printf "{\"type\":\"host\",\"target\":%s,\"host\":%s,\"target_type\":%s,\"login\":%s,\"auth\":%s}\n", q(tn[k]), q(tg[k]), q(tt[k]), q(tl[k]), q(ta[k]) }
        for (i = 1; i <= ns; i++) printf "{\"type\":\"sample\",\"sample\":%s,\"time\":%s}\n", q(sord[i]), q(st[sord[i]])
        next }
    if ($6 == "none") next
    printf "{\"type\":\"reading\",\"sample\":%s,\"time\":%s,\"host\":%s,\"source\":%s,\"chip\":%s,\"dev\":%s,\"sensor\":%s,\"temp_c\":%s,\"high_c\":%s,\"crit_c\":%s,\"status\":%s}\n", q($1), q(st[$1]), q($2), q($3), q($4), q($5), q($6), nm($7), nm($8), nm($9), q($10)
    next }
FNR == 1 { next }
$12 ~ /^nodata/ { nd++; printf "{\"type\":\"nodata\",\"host\":%s,\"source\":%s,\"why\":%s}\n", q($1), q($2), q(substr($12, 8)); next }
{ ns2++; if ($12 != "-") fl++
  printf "{\"type\":\"sensor\",\"host\":%s,\"source\":%s,\"kind\":%s,\"chip\":%s,\"dev\":%s,\"sensor\":%s,\"first_c\":%s,\"min_c\":%s,\"max_c\":%s,\"last_c\":%s,\"high_c\":%s,\"crit_c\":%s,\"flag\":%s}\n", q($1), q($2), q($3), q($4), q($5), q($6), nm($7), nm($13), nm($8), nm($9), nm($10), nm($11), ($12 == "-" ? "null" : q($12)) }
END { printf "{\"type\":\"result\",\"data\":%s,\"hosts_with_data\":%d,\"targets\":%d,\"sensors\":%d,\"flagged\":%d,\"nodata\":%d,\"unreachable\":%d}\n", q(res), hwd, nt, ns2, fl, nd, unreach }'

# a self-contained page (no script, no network): the same content as the stderr summary plus every sensor
HTML_AWK='
function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
function fc(f) { return f ~ /^crit/ ? "crit" : f ~ /^high/ ? "high" : f ~ /^near/ ? "near" : f ~ /rise/ ? "rise" : "" }
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "<tr>"; for (i = 1; i <= NF; i++) hdr = hdr "<th" (i >= 7 && i < NF ? " class=\"n\"" : "") ">" $i "</th>"; hdr = hdr "</tr>"; next }
    ns++; all[ns] = $0; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FNR == 1 { next }
$12 ~ /^nodata/ { nd[++nn] = "<li><b>" e($1) "</b> " e($2) ": " e(substr($12, 8)) "</li>"; next }
function row(l,   p, i, n, s, c) { n = split(l, p, " "); c = fc(p[n]); s = "<tr" (c != "" ? " class=\"" c "\"" : "") ">"
    for (i = 1; i <= n; i++) s = s "<td" (i >= 7 && i < n ? " class=\"n\"" : "") ">" e(p[i]) "</td>"; return s "</tr>" }
END {
    print "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    print "<title>Thermals " e(label) "</title><style>"
    print ":root{--bg:#fbfbfa;--fg:#1d1f21;--mut:#5f6368;--line:#dcdcd8;--card:#fff;--crit:#b3261e;--critbg:#fde7e5;--high:#b45309;--highbg:#fdf0e1;--near:#8a6d00;--nearbg:#fbf6dc;--rise:#5b4bb7;--risebg:#eeebfb;--ok:#1e7d3c}"
    print "@media (prefers-color-scheme: dark){:root:not([data-theme=light]){--bg:#17181a;--fg:#e6e6e3;--mut:#a0a3a8;--line:#33363a;--card:#1f2124;--crit:#ff8a80;--critbg:#3d1c1a;--high:#ffb366;--highbg:#3a2a16;--near:#e6cf5c;--nearbg:#332e14;--rise:#b3a6ff;--risebg:#2a2640;--ok:#7bd88f}}"
    print "body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}main{max-width:1200px;margin:0 auto;padding:16px}"
    print "h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 8px}.mut{color:var(--mut)}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:12px 0}"
    print ".wrap{overflow-x:auto}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:4px 8px;border-bottom:1px solid var(--line);white-space:nowrap}td.n,th.n{text-align:right}"
    print "tr.crit td{background:var(--critbg);color:var(--crit)}tr.high td{background:var(--highbg);color:var(--high)}tr.near td{background:var(--nearbg);color:var(--near)}tr.rise td{background:var(--risebg);color:var(--rise)}"
    print ".nodata{border-color:var(--crit)}.nodata h2{color:var(--crit);margin-top:0}.res{font-weight:600}.res.COMPLETE{color:var(--ok)}.res.PARTIAL,.res.NONE{color:var(--crit)}</style></head><body><main>"
    printf "<h1>Thermals: %s</h1><div class=\"mut\">%s to %s UTC &middot; %s &middot; hwmon + nvidia-smi%s &middot; thermals_capture %s</div>\n", e(label), e(start), e(end), (nsamp > 1 ? nsamp " samples" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), e(ver)
    printf "<div class=\"card\"><span class=\"res %s\">%s</span> &middot; %d of %d hosts gave readings &middot; %d sensors &middot; %d flagged &middot; %d no-data</div>\n", res, res, hwd, nt, ns, nf, nn
    if (nn) { print "<div class=\"card nodata\"><h2>No temperature data (never read as cool)</h2><ul>"; for (i = 1; i <= nn; i++) print nd[i]; print "</ul></div>" }
    if (nh) { print "<h2>Hottest reading per host and type (&deg;C)</h2><div class=\"wrap\"><table><tr><th>Host</th><th class=\"n\">Inlet</th><th class=\"n\">CPU</th><th class=\"n\">GPU</th><th class=\"n\">Mem</th><th class=\"n\">NVMe</th><th class=\"n\">NIC</th><th class=\"n\">Other</th><th>Flags</th></tr>"
        for (i = 1; i <= nh; i++) { split(hm[i], p, " ")
            w = p[9] ~ /crit/ ? "crit" : p[9] ~ /high/ ? "high" : p[9] ~ /near/ ? "near" : p[9] ~ /rise/ ? "rise" : ""
            s = "<tr" (w != "" ? " class=\"" w "\"" : "") "><td>" e(p[1]) "</td>"; for (j = 2; j <= 8; j++) s = s "<td class=\"n\">" p[j] "</td>"
            print s "<td>" e(p[9]) "</td></tr>" }
        print "</table></div>" }
    if (nf) { print "<h2>Flagged sensors</h2><div class=\"wrap\"><table>" hdr; for (i = 1; i <= nf; i++) print row(fr[i]); print "</table></div>" }
    if (ns) { print "<h2>Every sensor</h2><div class=\"wrap\"><table>" hdr; for (i = 1; i <= ns; i++) print row(all[i]); print "</table></div>" }
    print "<p class=\"mut\">Flags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "&deg;C of high; rise = up more than " rise "&deg;C over the samples.</p></main></body></html>" }'

# the same summary as Markdown (GitHub tables): result, no-data list, per-host maxima, flagged sensors, every sensor
MD_AWK='
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "|"; al = "|"; for (i = 1; i <= NF; i++) { hdr = hdr " " $i " |"; al = al (i >= 7 && i < NF ? "--:|" : "---|") } hdr = hdr "\n" al; next }
    ns++; all[ns] = $0; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FNR == 1 { next }
$12 ~ /^nodata/ { nd[++nn] = "- **" $1 "** " $2 ": " substr($12, 8); next }
function row(l,   p, i, n, s) { n = split(l, p, " "); s = "|"; for (i = 1; i <= n; i++) s = s " " (i == n && p[i] != "-" ? "**" p[i] "**" : p[i]) " |"; return s }
END {
    printf "# Thermals: %s\n\n%s to %s UTC · %s · hwmon + nvidia-smi%s · thermals_capture %s\n\n", label, start, end, (nsamp > 1 ? nsamp " samples" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), ver
    printf "**%s** · %d of %d hosts gave readings · %d sensors · %d flagged · %d no-data\n", res, hwd, nt, ns, nf, nn
    if (nn) { print "\n## No temperature data (never read as cool)\n"; for (i = 1; i <= nn; i++) print nd[i] }
    if (nh) { print "\n## Hottest reading per host and type (°C)\n\n| Host | Inlet | CPU | GPU | Mem | NVMe | NIC | Other | Flags |\n|---|--:|--:|--:|--:|--:|--:|--:|---|"
        for (i = 1; i <= nh; i++) { split(hm[i], p, " "); s = "| " p[1] " |"; for (j = 2; j <= 8; j++) s = s " " p[j] " |"; print s " " (p[9] == "-" ? "-" : "**" p[9] "**") " |" } }
    if (nf) { print "\n## Flagged sensors\n\n" hdr; for (i = 1; i <= nf; i++) print row(fr[i]) }
    if (ns) { print "\n## Every sensor\n\n" hdr; for (i = 1; i <= ns; i++) print row(all[i]) }
    print "\nFlags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "°C of high; rise = up more than " rise "°C over the samples." }'

# ---------- main ----------

cleanup() {
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

main() {
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) || die "needs bash 4.3+"
    [[ $1 == --help ]] && { usage; exit 0; }
    : "${FF_SSH_USER:=root}" "${FF_SSH_PARALLEL:=64}" "${FF_MAX_TARGETS:=4096}" "${FF_OUT_DIR:=.}"
    : "${FF_IPMI:=1}" "${FF_IPMI_TIMEOUT:=60}" "${FF_TEMP_MARGIN:=5}" "${FF_TEMP_RISE:=10}"
    [[ $FF_IPMI == 0 || $FF_IPMI == 1 ]] || die "FF_IPMI must be 0 or 1, got '$FF_IPMI'"
    local v; for v in FF_TEMP_MARGIN FF_TEMP_RISE; do [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number, got '${!v}'"; done
    for v in FF_IPMI_TIMEOUT FF_SSH_PARALLEL FF_MAX_TARGETS; do
        [[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v must be a positive integer, got '${!v}'"
    done
    local list=0; [[ $1 == --list ]] && { list=1; shift; }

    local opt fmt=jsonl iv= du= verbose=0 tfile=
    while getopts ":o:i:d:t:vh" opt; do
        case $opt in
            o) fmt=$OPTARG ;;
            t) tfile=$OPTARG ;;
            v) verbose=1 ;;
            i) iv=$OPTARG ;;
            d) du=$OPTARG ;;
            h) usage; exit 0 ;;
            :) die "-$OPTARG needs a value (--help)" ;;
            \?) die "unknown option -$OPTARG (--help)" ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    (( $# == 0 )) || die "unexpected argument '$1' (targets go in FF_HOSTS or -t <file>; --help)"
    [[ -n $FF_HOSTS || -n $tfile ]] || die "no targets: set FF_HOSTS or give -t <file> (--help)"
    [[ -n $FF_HOSTS && -n $tfile ]] && die "use FF_HOSTS or -t <file>, not both (unset FF_HOSTS to use the file)"
    # targets: FF_HOSTS (FF_SSH_USER, key ssh, sudo -n), or the -t file's host and bmc lines
    declare -ga T_LOGIN=() T_PW=() BMCS=() B_LOGIN=() B_PW=(); HAVE_PW=0
    TARGETS=(); _SEEN=(); INPUT_RANGES=0
    if [[ -n $FF_HOSTS ]]; then expand_targets "$FF_HOSTS"; for v in "${!TARGETS[@]}"; do T_LOGIN[$v]=$FF_SSH_USER; done; fi
    [[ -n $tfile ]] && load_target_file "$tfile"
    (( ${#TARGETS[@]} + ${#BMCS[@]} > 0 )) || die "no targets in -t $tfile"
    if (( list )); then (( ${#TARGETS[@]} )) && printf '%s\n' "${TARGETS[@]}"; (( ${#BMCS[@]} )) && printf '%s (bmc)\n' "${BMCS[@]}"; exit 0; fi
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
    [[ -d $FF_OUT_DIR && -w $FF_OUT_DIR ]] || die "FF_OUT_DIR '$FF_OUT_DIR' is not a writable directory"
    [[ -n $(command -v ssh) ]] || die "ssh not found"

    LOCAL_IPMITOOL=; (( ${#BMCS[@]} )) && { LOCAL_IPMITOOL=$(command -v ipmitool); [[ -n $LOCAL_IPMITOOL ]] || log "ipmitool is not installed here: the bmc lines will have no data"; }
    # a password ssh login: sshpass -e if installed, else SSH_ASKPASS, which works unattended from OpenSSH 8.4
    SSHPASS_CMD=; local ver
    if (( ${#T_PW[@]} )); then
        SSHPASS_CMD=$(command -v sshpass)
        if [[ -z $SSHPASS_CMD ]]; then
            ver=$(ssh -V 2>&1); ver=${ver#*OpenSSH_}; ver=${ver%%[!0-9.]*}
            [[ $ver =~ ^([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] > 8 || (BASH_REMATCH[1] == 8 && BASH_REMATCH[2] >= 4) )) \
                || die "password logins in -t need sshpass or OpenSSH 8.4+ here (ssh -V: ${ver:-unknown})"
        fi
    fi
    MODE=-; (( FF_IPMI )) && MODE=ipmi
    # a host's whole read is cut off 30 s after the ipmitool timeout (a hung sysfs read or ssh), where timeout exists
    HOST_LIMIT=$(( FF_IPMI_TIMEOUT + 30 )); TO=$(command -v timeout || command -v gtimeout)
    [[ -n $TO ]] || log "no timeout command here: a hung host would stall the capture"

    WORK=$(mktemp -d "${TMPDIR:-/tmp}/thermals.XXXXXX") || die "mktemp failed"
    SOCKET_DIR=$(mktemp -d /tmp/tc_ssh.XXXXXX) || die "mktemp failed"
    trap cleanup EXIT
    # BatchMode and -l are per target (rssh); ssh keeps the first value it sees for an option
    SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=5m -o "ControlPath=$SOCKET_DIR/%C"
              -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15)
    printf '#!/bin/sh\nprintf "%%s\\n" "$THERMCAP_PW"\n' > "$WORK/askpass"; chmod 700 "$WORK/askpass"
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
    local nt=$(( ${#TARGETS[@]} - ${#UNREACH[@]} + ${#BMCS[@]} ))

    # nodata rows come out in awk's hash order (differs between awks): sort them so the output is the same
    awk -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" "$TEMP_SUM_AWK" "$WORK/temps.txt" > "$WORK/temps_summary.raw"
    { awk '$12 !~ /^nodata/' "$WORK/temps_summary.raw"; awk '$12 ~ /^nodata/' "$WORK/temps_summary.raw" | sort -k1,1 -k2,2; } > "$WORK/temps_summary.sorted"
    awk "$TYPE_AWK" "$WORK/temps.txt" "$WORK/temps_summary.sorted" > "$WORK/temps_summary.txt"
    awk -v ns="$NSAMP" "$VIEW_AWK" "$WORK/temps_summary.txt" > "$WORK/view"
    awk "$HOST_MAX_AWK" "$WORK/temps_summary.txt" | sort -k1,1 > "$WORK/hostmax"
    local sensors flagged nodata hwd res rc
    read -r sensors flagged nodata hwd < <(awk 'NR > 1 && $6 != "none" {s++; if ($12 != "-") f++; if (!($1 in h)) {h[$1] = 1; hw++}} NR > 1 && $12 ~ /^nodata/ {d++}
        END {print s + 0, f + 0, d + 0, hw + 0}' "$WORK/temps_summary.txt")
    if (( sensors == 0 )); then res=NONE rc=4; elif (( nodata > 0 )); then res=PARTIAL rc=3; else res=COMPLETE rc=0; fi
    print_summary >&2
    # stdout: one row per host and source (the summary and the closing counts stay on stderr)
    if awk 'NR > 1 {f = 1} END {exit !f}' "$WORK/view"; then
        awk "$SRC_AWK" "$WORK/temps_summary.txt" | { read -r hdr; echo "$hdr"; sort -k1,1 -k2,2; } | column -t
    fi
    (( nt == 0 )) && echo "NO TEMPERATURE DATA: none of the ${#TARGETS[@]} targets took an ssh connection$( (( verbose )) || echo " (-v lists them)")" >&2
    if (( verbose && ${#UNREACH[@]} )); then
        echo "Unreachable: ${#UNREACH[@]} target(s) took no ssh connection in any sample (left out of every count and file):" >&2
        for i in "${UNREACH[@]}"; do echo "  ${TARGETS[$i]} $(awk 'NF {l = $2} END {print l}' "$WORK/unreach.$i")"; done | sort -V >&2
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
            html) awk "${common[@]}" "$HTML_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" > "$f.tmp" ;;
            md) awk "${common[@]}" "$MD_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" > "$f.tmp" ;;
        esac && mv "$f.tmp" "$f" || die "could not write $f"
        out+=("$f")
    done
    for f in "${out[@]}"; do log "Wrote $f"; done
    log "To copy here from a jump host: scp '$(hostname -f 2>&1):$(cd "$(dirname "${out[0]}")" && pwd)/${base##*/}.*' ."
    # the closing count: unreachable (no ssh connection) and unavailable (reachable, no reading at all)
    if (( ${#UNREACH[@]} || nt - hwd )); then
        echo "Unreachable: ${#UNREACH[@]} (no ssh connection$( (( ${#UNREACH[@]} && ! verbose )) && echo "; -v lists them")), unavailable: $(( nt - hwd )) (connected, no readings)" >&2
    fi
    echo "RESULT data=$res hosts=$hwd/$nt sensors=$sensors flagged=$flagged nodata=$nodata unreachable=${#UNREACH[@]}" >&2
    exit $rc
}

# run when executed or fed on stdin (ssh jump 'bash -s' < script: BASH_SOURCE is empty); not when sourced
if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
