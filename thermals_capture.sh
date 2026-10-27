#!/usr/bin/env bash
# Built by ./build from src/ (README, Source): edit src/, never this file.
# thermals_capture: every hwmon temperature and the BMC's (ipmitool) on a set of hosts, read only, over ssh.
# One snapshot by default, or a sample every -i seconds for -d seconds. Output: any of .jsonl, .html, .md.
# Standalone companion to fabric_ferret.sh: same host syntax and FF_ settings, same reader and flags.
# bash 4.3+ (declare -A, wait -n, namerefs): checked first, in bash 3 syntax, before anything else runs
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } || {
    echo "thermals_capture.sh: needs bash 4.3+ (this is bash $BASH_VERSION)" >&2; echo "RESULT data=STOPPED (needs bash 4.3+)" >&2; exit 2; }

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
  -t FILE          targets, one per line: <type>,<host>,<login>,<pw> (# comments). A line with no comma is a
                   backend with the defaults, so a plain host list works; a line whose host field is empty or
                   starts with # is skipped.
                     backend, client (host = backend)  an ssh target: IP, hostname, CIDR or range (as
                           FF_HOSTS); hwmon + in-band ipmitool
                     bmc   one BMC address (no CIDR or range), read from here: ipmitool -I lanplus sensor
                     *     backend and client, never bmc (credential rows only)
                   A host of * or a glob (* ? [...], any case) is a credential row: it adds no targets and needs
                   a login or pw. Each target takes the most specific row with a login or pw: one host > CIDR
                   or range > glob > <type>,* > *,*. That row is its credential, no fallback; two rows at one
                   level that differ: the first, warned; a row matching nothing: warned.
                   No login: FF_SSH_USER. No pw: key (passwordless) ssh; for a bmc, an empty password.
                   The pw is everything after the third comma. A password reaches ssh (SSH_ASKPASS: OpenSSH 8.4+,
                   or setsid, here) and ipmitool (-f) only through a one-use fifo in a private temp dir: never an
                   environment variable or a command line, never written out. chmod 600 the file (warned otherwise).
                   A non-root host login with a pw runs ipmitool with sudo -S and that pw (sent on the ssh
                   stdin stream, not argv); without a pw, the first passwordless escalator (FF_SSH_USER below).
                   -t or FF_HOSTS, not both.
  -o LIST         output files, comma separated, any of jsonl (default), html, md:
                   thermcap_<UTC>.jsonl|.html|.md in FF_OUT_DIR (jsonl: every reading; html: an overview, then a
                   page per type with its OS and BMC tables, one row per host, sortable; md: the same layout)
  -d SECONDS       0 (default): one point-in-time reading. Above 0: read now and again SECONDS later, giving
                   each sensor's first, min, max and last (and the rise flag)
  -i SECONDS       with -d, read every SECONDS instead (the first at 0, the last at or before -d)
  -v               list on stderr the unreachable targets: those that took no ssh connection (timed out, refused,
                   no route, name not found) in any sample. They are always left out of the counts, the jsonl
                   and the md, silently without -v (RESULT unreachable=N counts them; the html lists them under
                   Not read). A target that connects but fails
                   (auth refused, cut off, no hwmon…) is always reported as no data.
  -h, --help       this text

Settings (the same names as fabric_ferret.sh; default)
  FF_HOSTS         ssh targets, backends (key ssh as FF_SSH_USER), comma or space separated, any mix of: 10.1.0.5,node07 | 10.1.0.0/24 |
                   10.1.0.10-10.1.1.20 | 10.1.0.10-40 | 10.1.0-1.10-40 | @hosts.txt (# comments)
  FF_SSH_USER      ssh user, and -t's default login (the current user). A non-root login reads hwmon as itself
                   and runs ipmitool through the first passwordless escalator: on each host, once per run,
                   `<escalator> true` (5 s timeout) for dzdo -n, pbrun, sesu, pmrun, doas -n, ksu -e, sudo -n, in
                   that order; none = no BMC data from that host (its reason says so)
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
nc), near (within FF_TEMP_MARGIN of high), then +rise. A threshold of 0 counts as unset. A sensor with a crit
but no high gets high = 95% of crit. A host or source that
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
_TRACK=0; declare -a _COVER=()   # hostfile.sh: under _TRACK=1, every target an entry names, listed before or not
_emit() {
    (( _TRACK )) && _COVER+=("$1")
    [[ -n ${_SEEN[$1]+x} ]] && return
    _SEEN[$1]=1; TARGETS+=("$1")
    (( ${#TARGETS[@]} <= FF_MAX_TARGETS )) || die "$EXPANDING expands past FF_MAX_TARGETS=$FF_MAX_TARGETS; narrow it or raise the cap"
}
_need() {  # refuse a range before looping over it
    (( ${#TARGETS[@]} + $1 <= FF_MAX_TARGETS )) || die "$EXPANDING: '$2' adds $1 targets, past FF_MAX_TARGETS=$FF_MAX_TARGETS"
}

expand_entry() {
    local e=$1 b lo hi n
    [[ $e == *:* ]] && die "$EXPANDING: IPv6 is not supported: '$e'"
    if [[ $e == */* ]]; then
        b=$(cidr_bounds "$e") || die "$EXPANDING: bad CIDR: '$e'"
        lo=${b% *}; hi=${b#* }
        (( hi - lo >= 2 )) && { lo=$(( lo + 1 )); hi=$(( hi - 1 )); }
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^([0-9.]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}  # is_ip resets BASH_REMATCH
        is_ip "$from" && is_ip "$to" || die "$EXPANDING: bad IP range: '$e'"
        lo=$(ip2int "$from"); hi=$(ip2int "$to")
        (( lo <= hi )) || die "$EXPANDING: range runs backwards: '$e'"
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?$ ]]; then
        local -a lo4 hi4; local IFS=. o i count=1 a b c d
        local -a oct=($e)
        for i in 0 1 2 3; do
            o=${oct[$i]}
            lo4[$i]=$(( 10#${o%-*} )); hi4[$i]=$(( 10#${o#*-} ))
            (( lo4[i] <= hi4[i] && hi4[i] <= 255 )) || die "$EXPANDING: bad octet '$o' in '$e'"
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
        die "$EXPANDING: not a valid IP, range or CIDR: '$e'"
    elif [[ $e =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _emit "$e"
    else
        die "$EXPANDING: not a hostname, IP, range or CIDR: '$e'"
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
            [[ -r ${w#@} ]] || die "$EXPANDING: cannot read host file '${w#@}'"
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%%#*}
                _words "$line"
                for e in "${WORDS[@]}"; do
                    [[ $e == @* ]] && die "$EXPANDING: nested @file not supported: '$e' in ${w#@}"
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
# nvidia-smi: PATH, the usual install dirs, then the GPU operator's driver root (with its own libraries). A loaded
# driver (/proc/driver/nvidia/gpus) with no nvidia-smi anywhere is a no-data row, never silence.
nv=$(command -v nvidia-smi); nvl=
for p in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /usr/local/nvidia/bin/nvidia-smi /run/nvidia/driver/usr/bin/nvidia-smi; do
    [ -n "$nv" ] && break; [ -x "$p" ] && nv=$p
done
case $nv in /run/nvidia/driver/*) nvl=/run/nvidia/driver/usr/lib64:/run/nvidia/driver/usr/lib/x86_64-linux-gnu:/run/nvidia/driver/usr/lib/aarch64-linux-gnu ;; esac
gp=${FF_PROCFS:-/proc}/driver/nvidia/gpus   # FF_PROCFS: test hook, as FF_SYSFS
if [ -z "$nv" ] && [ -d "$gp" ] && [ -n "$(ls "$gp" 2>&1)" ]; then echo "@@GPU $h none nvidia_driver_loaded_but_no_nvidia-smi_found"
elif [ -z "$nv" ]; then   # no driver either: NVIDIA (vendor 0x10de) display or 3D controllers (class 0x03xxxx) on the PCI bus
    ng=0; for p in "$sys"/bus/pci/devices/*; do
        [ -r "$p/vendor" ] && [ "$(cat "$p/vendor" 2>&1)" = 0x10de ] || continue
        case $(cat "$p/class" 2>&1) in 0x0300*|0x0302*) ng=$(( ng + 1 )) ;; esac
    done
    [ "$ng" -gt 0 ] && echo "@@GPU $h none ${ng}_nvidia_gpus_on_pci_but_no_nvidia-smi_or_driver_here"
fi
if [ -n "$nv" ]; then
    if [ -n "$(command -v timeout)" ]; then g=$(LD_LIBRARY_PATH=$nvl timeout "${2:-60}" "$nv" -q -d TEMPERATURE 2>&1); else g=$(LD_LIBRARY_PATH=$nvl "$nv" -q -d TEMPERATURE 2>&1); fi; grc=$?
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
# script: a shell variable, never exported, never argv); else the first passwordless escalator that runs `true`
# within 5 s, tried in this order: dzdo -n, pbrun, sesu, pmrun, doas -n, ksu -e, sudo -n. $3, when given, is the
# escalator an earlier sample found ("_" for spaces, or none): no probe then. Reported as "@@ESC host escalator".
# Every probe and ipmitool reads an empty stdin, never the rest of this script.
s=; [ "$(id -u)" = 0 ] || { s=n; [ -n "${TC_PW+x}" ] && s=S; }
ito=${2:-60}; esc=$(printf '%s' "${3:-}" | tr _ ' ')
tmo() { t=$1; shift; if [ -n "$(command -v timeout)" ]; then timeout "$t" "$@"; else "$@"; fi; }
if [ "$s" = n ]; then
    if [ -z "$esc" ]; then
        esc=none
        for e in "dzdo -n" pbrun sesu pmrun "doas -n" "ksu -e" "sudo -n"; do
            [ -n "$(command -v "${e%% *}")" ] || continue
            if pr=$(tmo 5 $e true 2>&1 <<<""); then esc=$e; break; fi
        done
    fi
    echo "@@ESC $h $(printf '%s' "$esc" | tr ' ' _)"
fi
case $s in
    S) out=$(printf '%s\n' "$TC_PW" | tmo "$ito" sudo -S -p "" ipmitool sensor 2>&1); rc=$? ;;
    n) if [ "$esc" = none ]; then echo "@@IPMI $h none no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo"; exit 0; fi
       out=$(tmo "$ito" $esc ipmitool sensor 2>&1 <<<""); rc=$? ;;
    *) out=$(tmo "$ito" ipmitool sensor 2>&1 <<<""); rc=$? ;;
esac
# ipmitool sensor: name | value | units | status | lnr | lc | lnc | unc | uc | unr (unc = high, uc = crit)
r=$(printf '%s\n' "$out" | awk -F'|' -v h="$h" '{for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i)}
    $3 == "degrees C" && $2 ~ /^-?[0-9.]+$/ {nm = $1; gsub(/[^A-Za-z0-9_.:-]/, "_", nm)
        print "@@IPMI", h, nm, $2, ($4 == "" ? "-" : $4), ($8 ~ /^-?[0-9.]+$/ ? $8 : "-"), ($9 ~ /^-?[0-9.]+$/ ? $9 : "-")}')
if [ -n "$r" ]; then echo "$r"
elif [ "$rc" = 124 ]; then echo "@@IPMI $h none ipmitool_timed_out_after_${2:-60}s"
elif [ -n "$s" ] && printf '%s' "$out" | grep -q '^sudo:'; then echo "@@IPMI $h none sudo_refused_$(printf '%s' "$out" | grep '^sudo:' | head -n 1 | tr -d '\n' | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"
else echo "@@IPMI $h none rc=${rc}_$(printf '%s' "$out" | head -n 1 | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"; fi
EOF

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
pwfifo() { local f=$AUTH/$1.fifo; rm -f "$f" "$f.used"; mkfifo -m 600 "$f" || { echo "no password fifo: mkfifo $f failed" >&2; return 1; }; exec 4<>"$f"; printf '%s\n' "$2" >&4; PWFIFO=$f; }
# pw_transport: a password login's ssh takes SSH_ASKPASS unattended from OpenSSH 8.4 (SSH_ASKPASS_REQUIRE), before that
# only under setsid (no tty). Sets SETSID (the setsid path, or empty); dies when this machine has neither.
pw_transport() {
    local ver; SETSID=
    ver=$(ssh -V 2>&1); ver=${ver#*OpenSSH_}; ver=${ver%%[!0-9.]*}
    if ! [[ $ver =~ ^([0-9]+)\.([0-9]+) ]] || ! (( BASH_REMATCH[1] > 8 || (BASH_REMATCH[1] == 8 && BASH_REMATCH[2] >= 4) )); then
        SETSID=$(command -v setsid) || die "password logins in -t need OpenSSH 8.4+ or setsid here (ssh -V: ${ver:-unknown})"
    fi
}

# ---------- collection ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
wait_all() { while [[ -n $(jobs -rp) ]]; do wait; done; }   # a trapped Ctrl-C ends a bare wait early
tmo() { if [[ -n $TO ]]; then "$TO" "$HOST_LIMIT" "$@"; else "$@"; fi; }
clean() { printf '%s' "${1//$'\r'/}" | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80; }   # ssh ends its errors with \r\n

# sample n: TEMP_SCRIPT on every target at once, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (sensor none = no data, why in status).
# A target with no answer at all gets a none row per source, the reason from ssh's exit code and last error line.
# (write_askpass and pwfifo: src/sh/auth.sh, shared with fabric_ferret.sh)
# rssh i: ssh to target i as its login; a password login reads its password through the askpass helper from a fifo,
# never from an environment variable or a command line. Runs in its own background subshell.
rssh() {
    local i=$1 rc; shift
    local -a o=("${SSH_OPTS[@]}" -l "${T_LOGIN[$i]}")
    if [[ -z ${T_PW[$i]+x} ]]; then tmo ssh "${o[@]}" -o BatchMode=yes "${TARGETS[$i]}" "$@"; return; fi
    o+=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
    pwfifo "t$i.$BASHPID" "${T_PW[$i]}" || return 255
    THERMCAP_PW_FIFO=$PWFIFO SSH_ASKPASS=$AUTH/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none} \
        tmo $SETSID ssh "${o[@]}" "${TARGETS[$i]}" "$@"; rc=$?
    exec 4>&-; rm -f "$PWFIFO" "$PWFIFO.used"; return $rc
}

# rbmc j: the BMC's sensors out of band from here (ipmitool lanplus); a password through -f from a one-use fifo, an
# empty one as -E with IPMI_PASSWORD empty (no secret in it)
rbmc() {
    local j=$1 rc; local -a a=(-I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}")
    if [[ -n ${B_PW[$j]} ]]; then pwfifo "b$j.$BASHPID" "${B_PW[$j]}" || return 1; a+=(-f "$PWFIFO"); else a+=(-E); export IPMI_PASSWORD=; fi
    if [[ -n $TO ]]; then "$TO" "$FF_IPMI_TIMEOUT" ipmitool "${a[@]}" sensor <<<""; else ipmitool "${a[@]}" sensor <<<""; fi; rc=$?
    [[ -n ${B_PW[$j]} ]] && { exec 4>&-; rm -f "$PWFIFO"; }; return $rc
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
        # the escalator an earlier sample found on this host (esc.<i>) skips the probe: one probe per host per run
        { { [[ -n ${T_PW[$i]+x} ]] && printf 'IFS= read -r TC_PW\n%s\n' "${T_PW[$i]}"; printf '%s\n' "$TEMP_SCRIPT"; } \
              | rssh "$i" bash -s -- "$MODE" "$FF_IPMI_TIMEOUT" "$( [[ -r $WORK/esc.$i ]] && cat "$WORK/esc.$i")" > "$WORK/o.$n.$i" 2> "$WORK/e.$n.$i"
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
        [[ -e $WORK/esc.$i ]] || awk '$1 == "@@ESC" {print $3; exit}' "$o" > "$WORK/esc.$i.new"
        [[ -s $WORK/esc.$i.new ]] && mv -f "$WORK/esc.$i.new" "$WORK/esc.$i"; rm -f "$WORK/esc.$i.new"
        # a target that took no connection: set aside, silent unless -v (see unreachable_targets)
        if [[ $rc == 255 ]] && grep -qE "$NO_CONNECT_RE" "$WORK/e.$n.$i"; then
            echo "$n ssh_failed_$(clean "$(awk 'NF {l = $0} END {print l}' "$WORK/e.$n.$i")")" >> "$WORK/unreach.$i"; continue
        fi
        echo "$n ${TARGETS[$i]} $host ${T_TYPE[$i]:-backend} ${T_LOGIN[$i]} $( [[ -n ${T_PW[$i]+x} ]] && echo password || echo key)" >> "$WORK/hosts"
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

# load_target_file file deflogin: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped). type backend
# (host = backend) or client: ssh targets (IP, name, CIDR or range, as FF_HOSTS); bmc: one BMC address read out of
# band. A host field * or a glob (* ? [...], any case) is a credential row: it adds no targets. Type * = backend
# and client, never bmc. Each target takes the most specific row that gives a login or pw: one host > CIDR/range >
# glob > <type>,* > *,* > the default (deflogin, key; a bmc: the current user, empty password). That row is the
# credential, with no fallback. The pw is everything after the third comma, verbatim. Errors and warnings name
# line numbers, never the text (it may hold a password). Sets TARGETS T_TYPE T_LOGIN T_PW T_LINE, BMCS B_LOGIN
# B_PW B_LINE (T_LINE/B_LINE: the line whose credential it took, or "default").
load_target_file() {
    local f=$1 def=$2 line ln=0 ty h lg pw rest k r t g n tier me
    local -a R_LN=() R_TY=() R_H=() R_LG=() R_PW=() R_TIER=() wild=()
    local -A tidx=() bidx=() warned=()
    [[ -r $f && -f $f ]] || die "-t: cannot read '$f'"
    [[ $def =~ ^[A-Za-z0-9._@-]+$ ]] || die "FF_SSH_USER: bad login (letters, digits . _ @ - only)"
    me=$(id -un); T_ROW=(); B_ROW=()
    # also set: HF_RANGES[backend|client] (1 once a row of that type has a CIDR or range: INPUT_RANGES per type, so a
    # backend range never makes a dead client look normal) and HF_WILD_LINES (the credential rows' line numbers)
    declare -gA HF_RANGES=([backend]=0 [client]=0); declare -ga HF_WILD_LINES=()
    # _offer T|B idx row: the row's credentials for that target if more specific than what it has; an equal one
    # that differs keeps the first, warned once per pair of lines
    _offer() {
        local -n rw=${1}_ROW; local o=${rw[$2]}
        if [[ -z $o ]] || (( R_TIER[$3] > R_TIER[o] )); then rw[$2]=$3
        elif (( R_TIER[$3] == R_TIER[o] && o != $3 )) && [[ ${R_LG[$3]} != "${R_LG[o]}" || ${R_PW[$3]} != "${R_PW[o]}" ]] && [[ -z ${warned[$o,$3]} ]]; then
            warned[$o,$3]=1; log "WARNING: -t $f lines ${R_LN[o]} and ${R_LN[$3]} give a target different credentials at the same specificity; line ${R_LN[o]}'s are used"
        fi
    }
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *,* ]] || line="backend,$line"   # a bare line is a backend with the defaults: a plain host list works
        [[ $line =~ ^[^,]*,[[:space:]]*(#|,*[[:space:]]*$) ]] && continue   # "host,# ...", "host," : commented out or empty
        ty=${line%%,*}; rest=${line#*,}
        h=${rest%%,*}; [[ $rest == *,* ]] && rest=${rest#*,} || rest=
        lg=${rest%%,*}; [[ $rest == *,* ]] && pw=${rest#*,} || pw=
        # trim the ends only: a space inside a type, host or login is bad input, refused below with its line number
        for k in ty h lg; do local -n v=$k; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; unset -n v; done
        ty=${ty,,}
        [[ -z $lg || $lg =~ ^[A-Za-z0-9._@-]+$ ]] || die "-t $f line $ln: bad login (letters, digits . _ @ - only)"
        [[ -n $pw ]] && HAVE_PW=1
        [[ $ty == host ]] && ty=backend
        [[ $ty =~ ^(backend|client|bmc|\*)$ ]] || die "-t $f line $ln: type must be backend, client, bmc (host = backend) or *"
        [[ -n $h ]] || die "-t $f line $ln: no host"
        r=${#R_LN[@]}; R_LN[r]=$ln; R_TY[r]=$ty; R_H[r]=$h; R_LG[r]=$lg; R_PW[r]=$pw
        if [[ $h == *[\*\?\[]* ]]; then   # a credential row: matched against the targets once all are read
            [[ $h =~ ^[][A-Za-z0-9.*?!^-]+$ ]] || die "-t $f line $ln: bad host pattern (letters, digits . - and * ? [...] only)"
            [[ -n $lg || -n $pw ]] || die "-t $f line $ln: a wildcard row adds no targets, so it needs a login or pw"
            if [[ $h != '*' ]]; then tier=3; elif [[ $ty != '*' ]]; then tier=2; else tier=1; fi
            R_TIER[r]=$tier; wild+=("$r"); HF_WILD_LINES+=("$ln"); continue
        fi
        [[ $ty == '*' ]] && die "-t $f line $ln: type * takes a host of * or a glob (it adds no targets)"
        if [[ $ty == bmc ]]; then
            is_ip "$h" || [[ $h =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || die "-t $f line $ln: a bmc line takes one IP or hostname, or a glob (no CIDR or range)"
            R_TIER[r]=5
            [[ -n ${bidx[$h]+x} ]] || { bidx[$h]=${#BMCS[@]}; BMCS+=("$h"); }
            [[ -n $lg || -n $pw ]] && _offer B "${bidx[$h]}" "$r"
            continue
        fi
        # an ssh target row, expanded onto the list; _COVER (expand.sh) names every target it covers, listed before or not
        R_TIER[r]=5; [[ $h == */* || ( $h =~ ^[0-9.-]+$ && $h == *-* ) ]] && R_TIER[r]=4
        local ir=$INPUT_RANGES n0=${#TARGETS[@]}
        EXPANDING="-t $f line $ln"; INPUT_RANGES=0; _TRACK=1; _COVER=()
        expand_entry "$h"; _TRACK=0
        (( HF_RANGES[$ty] |= INPUT_RANGES, INPUT_RANGES |= ir ))   # this row's range flag, kept per type too
        for (( k = n0; k < ${#TARGETS[@]}; k++ )); do tidx[${TARGETS[k]}]=$k; T_TYPE[k]=$ty; T_FROM[k]=$ln; done
        for t in "${_COVER[@]}"; do
            [[ ${T_TYPE[${tidx[$t]}]} == "$ty" ]] || die "-t $f line $ln: a target here is already listed as ${T_TYPE[${tidx[$t]}]} on line ${T_FROM[${tidx[$t]}]}"
            [[ -n $lg || -n $pw ]] && _offer T "${tidx[$t]}" "$r"
        done
    done < "$f"
    # credential rows (globs, <type>,*, *,*): * never reaches a bmc; a row that matches no target is warned
    for r in "${wild[@]}"; do
        n=0; g=${R_H[r],,}
        if [[ ${R_TY[r]} == bmc ]]; then
            for k in "${!BMCS[@]}"; do t=${BMCS[$k],,}; [[ $t == $g ]] && { n=$(( n + 1 )); _offer B "$k" "$r"; }; done
        else
            for k in "${!TARGETS[@]}"; do
                [[ ${R_TY[r]} == '*' || ${R_TY[r]} == "${T_TYPE[$k]}" ]] || continue
                t=${TARGETS[$k],,}; [[ $t == $g ]] && { n=$(( n + 1 )); _offer T "$k" "$r"; }
            done
        fi
        (( n )) || log "WARNING: -t $f line ${R_LN[r]} matches no target"
    done
    # the chosen row is THE credential: its login (else the default) and its pw (else key ssh / an empty BMC password)
    for k in "${!TARGETS[@]}"; do
        r=${T_ROW[$k]}
        if [[ -n $r ]]; then T_LOGIN[$k]=${R_LG[r]:-$def}; T_LINE[$k]=${R_LN[r]}; [[ -n ${R_PW[r]} ]] && T_PW[$k]=${R_PW[r]}
        else T_LOGIN[$k]=$def; T_LINE[$k]=default; fi
    done
    for k in "${!BMCS[@]}"; do
        r=${B_ROW[$k]}
        if [[ -n $r ]]; then B_LOGIN[$k]=${R_LG[r]:-$me}; B_PW[$k]=${R_PW[r]}; B_LINE[$k]=${R_LN[r]}
        else B_LOGIN[$k]=$me; B_PW[$k]=; B_LINE[$k]=default; fi
    done
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
# name, first match wins: inlet/ambient; VRM/PSU/board/FPGA/HMC/HSC/PLX/PEX/PCH/SAS other; nic/aoc/ocp/cx<n>/port
# (so an HGX ConnectX is a NIC); gpu/hbm/nvlink/nvsw; nvme/ssd/m.2/drive; dimm/mem; cpu/proc/soc; else other.
# hwmon drivetemp is nvme, jc42/spd5118 mem. Appends Min_C (the lowest sample) as column 13. Reads temps.txt
# then temps_summary.txt (fabric_ferret's TEMP_SUM_AWK stays unchanged).
TYPE_AWK='
FILENAME == ARGV[1] { if (FNR > 1 && $6 != "none") { k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6; v = $7 + 0; if (!(k in mn) || v < mn[k]) mn[k] = v } next }
FNR == 1 { print $0, "Min_C"; next }
$6 == "none" { print $0, "-"; next }
{ s = tolower($6)
  if ($2 == "gpu") $3 = "gpu"
  else if ($2 == "ipmi") $3 = s ~ /inlet|ambient/ ? "inlet" : s ~ /vrm|vr_|psu|board|fpga|hmc|hsc|plx|pex|pch|sas/ ? "other" : s ~ /nic|aoc|ocp|cx[0-9]|lom|port/ ? "nic" : s ~ /gpu|hbm|nvlink|nvsw/ ? "gpu" : s ~ /nvme|ssd|m\.?2|drive|disk/ ? "nvme" : s ~ /dimm|mem/ ? "mem" : s ~ /cpu|proc|soc/ ? "cpu" : "other"
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

# A self-contained page (no network): a left nav (after the cs plugin dashboards) with Overview, a page per type
# (its OS table, then its BMC / IPMI table) and Not read at the foot. A table is one row per host; columns are
# grouped by device, the same device on every host; cells the temperature (max with -d), flagged cells shaded.
# The tables are static HTML, so the page reads and
# prints without script; the inline script only switches panels and sorts a table on a header click.
read -r -d '' HTML_HEAD <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@TITLE@</title>
<style>
:root { --bg: #fbfbfa; --surface: #ffffff; --surface-2: #f2f1ed; --fg: #1d1f21; --fg-2: #52514e; --mut: #6b6a66;
  --line: #dcdcd8; --accent: #2a78d6; --crit: #b3261e; --critbg: #fde7e5; --high: #b45309; --highbg: #fdf0e1;
  --near: #8a6d00; --nearbg: #fbf6dc; --rise: #5b4bb7; --risebg: #eeebfb; --ok: #1e7d3c;
  --head: #dce9f9; --head-ink: #173b66; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #17181a; --surface: #1f2124;
  --surface-2: #26282c; --fg: #e6e6e3; --fg-2: #c3c2bd; --mut: #a0a3a8; --line: #33363a; --accent: #6aa6ef;
  --crit: #ff8a80; --critbg: #3d1c1a; --high: #ffb366; --highbg: #3a2a16; --near: #e6cf5c; --nearbg: #332e14;
  --rise: #b3a6ff; --risebg: #2a2640; --ok: #7bd88f; --head: #1d3350; --head-ink: #cfe2fb; } }
:root[data-theme="dark"] { --bg: #17181a; --surface: #1f2124; --surface-2: #26282c; --fg: #e6e6e3; --fg-2: #c3c2bd;
  --mut: #a0a3a8; --line: #33363a; --accent: #6aa6ef; --crit: #ff8a80; --critbg: #3d1c1a; --high: #ffb366;
  --highbg: #3a2a16; --near: #e6cf5c; --nearbg: #332e14; --rise: #b3a6ff; --risebg: #2a2640; --ok: #7bd88f;
  --head: #1d3350; --head-ink: #cfe2fb; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { padding: 14px 16px; border-bottom: 1px solid var(--line); background: var(--surface); }
h1 { font-size: 18px; margin: 0 0 2px; } h2 { font-size: 16px; margin: 4px 0 10px; } h3 { font-size: 14px; margin: 18px 0 8px; }
.mut { color: var(--mut); }
a { color: var(--accent); }
.body { display: flex; align-items: flex-start; }
#nav { position: sticky; top: 0; flex: 0 0 200px; padding: 14px 10px; display: flex; flex-direction: column; gap: 2px;
  height: 100vh; overflow-y: auto; scrollbar-width: thin; }
#nav button { font: inherit; text-align: left; cursor: pointer; background: transparent; border: 0; border-radius: 6px;
  color: var(--fg-2); padding: 6px 10px; display: flex; justify-content: space-between; gap: 8px; align-items: center; }
#nav button:hover { background: var(--surface-2); color: var(--fg); }
#nav button[aria-selected="true"] { background: var(--surface); color: var(--fg); font-weight: 600; box-shadow: inset 2px 0 0 var(--accent); }
#nav .count { color: var(--mut); font-size: 12px; font-variant-numeric: tabular-nums; font-weight: 400; }
#nav .navgroup { color: var(--mut); font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; padding: 14px 10px 4px; }
/* Not read sits at the foot of the nav, as the cs dashboards pin their gear */
#nav-footer { margin-top: auto; padding-top: 10px; border-top: 1px solid var(--line); }
#nav-footer button { width: 100%; }
#nav button.warn .count { color: var(--high); font-weight: 600; }
main { flex: 1 1 auto; min-width: 0; padding: 14px 16px 32px; }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px; margin: 0 0 12px; }
.res { font-weight: 600; } .res.COMPLETE { color: var(--ok); } .res.PARTIAL, .res.NONE { color: var(--crit); }
.nodata { border-color: var(--crit); } .nodata h3 { color: var(--crit); margin-top: 0; }
/* a table scrolls inside its own box, no taller than the window, so its sideways scrollbar is always on screen;
   the scrollbars are styled, so they show even where the system hides them until you scroll */
.wrap { overflow: auto; max-height: calc(100vh - 150px); border: 1px solid var(--line); border-radius: 8px;
  background: var(--surface); scrollbar-width: auto; scrollbar-color: var(--mut) var(--surface-2); }
.wrap::-webkit-scrollbar { width: 12px; height: 12px; }
.wrap::-webkit-scrollbar-track { background: var(--surface-2); }
.wrap::-webkit-scrollbar-thumb { background: var(--mut); border-radius: 6px; border: 3px solid var(--surface-2); }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 4px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
thead { position: sticky; top: 0; z-index: 2; }
th { background: var(--head); color: var(--head-ink); font-weight: 600; }
th.grp { text-align: left; border-left: 2px solid var(--surface); }
th .chip { font-weight: 400; opacity: 0.75; font-size: 12px; margin-left: 6px; }
th.gs, td.gs { border-left: 2px solid var(--line); }
td.crit { background: var(--critbg); color: var(--crit); font-weight: 600; } td.high { background: var(--highbg); color: var(--high); font-weight: 600; }
td.near { background: var(--nearbg); color: var(--near); } td.rise { background: var(--risebg); color: var(--rise); }
th.n, td.n { text-align: right; }
table.sortable th { cursor: pointer; user-select: none; }
table.sortable th[aria-sort="ascending"]::after { content: " \25B2"; font-size: 10px; }
table.sortable th[aria-sort="descending"]::after { content: " \25BC"; font-size: 10px; }
td.host, th.host { position: sticky; left: 0; background: var(--surface); z-index: 1; }
th.host { background: var(--head); z-index: 2; }
th .dev { display: block; font-weight: 400; color: var(--mut); font-size: 12px; }
tr.crit td { background: var(--critbg); color: var(--crit); } tr.high td { background: var(--highbg); color: var(--high); }
tr.near td { background: var(--nearbg); color: var(--near); } tr.rise td { background: var(--risebg); color: var(--rise); }
@media (max-width: 860px) {
  .body { flex-direction: column; align-items: stretch; }
  main { width: 100%; min-width: 0; }
  #nav { position: static; flex: 1 1 auto; width: 100%; flex-direction: row; flex-wrap: wrap; max-height: none; }
  #nav .navgroup { width: 100%; padding: 6px 10px 2px; }
  #nav { height: auto; }
  #nav-footer { margin-top: 0; width: 100%; }
}
@media print { #nav { display: none; } section.panel[hidden] { display: block !important; } }
</style>
</head>
<body>
EOF
read -r -d '' HTML_TAIL <<'EOF'
<script>
(function () {
  "use strict";
  var nav = document.getElementById("nav");
  var panels = Array.prototype.slice.call(document.querySelectorAll("section.panel"));
  // each visible table box ends at the bottom of the window, so its sideways scrollbar is on screen
  // and the nav ends there too, so Not read at its foot is on screen (wide layout only; narrow, the nav wraps)
  function fitnav() {
    if (window.innerWidth <= 860) { nav.style.height = ""; return; }
    nav.style.height = (window.innerHeight - Math.max(0, nav.getBoundingClientRect().top)) + "px";
  }
  function fit() {
    Array.prototype.forEach.call(document.querySelectorAll("section.panel:not([hidden]) .wrap"), function (w) {
      var top = w.getBoundingClientRect().top + window.scrollY;
      w.style.maxHeight = Math.max(160, window.innerHeight - top - 12) + "px";
    });
    fitnav();
  }
  window.addEventListener("resize", fit);
  window.addEventListener("scroll", fitnav, { passive: true });
  // a panel's element id is "p-" + its name, so the #name in the URL never makes the browser jump to it
  function show(id) {
    panels.forEach(function (p) { p.hidden = p.id !== "p-" + id; });
    fit();
    Array.prototype.forEach.call(nav.querySelectorAll("button[data-panel]"), function (b) {
      b.setAttribute("aria-selected", b.getAttribute("data-panel") === id ? "true" : "false");
    });
    try { history.replaceState(null, "", "#" + id); } catch (e) { /* file:// in some browsers */ }
  }
  document.addEventListener("click", function (ev) {   // nav buttons, and links such as the Overview's "see Not read"
    var b = ev.target.closest("[data-panel]");
    if (!b) return;
    ev.preventDefault(); show(b.getAttribute("data-panel")); window.scrollTo(0, 0);
  });
  // sort on a header click: numbers by data-v (no reading always last), text naturally (host-2 before host-10)
  function val(row, i, num) {
    var c = row.children[i];
    if (!c) return null;
    if (num) { var v = c.getAttribute("data-v"); return v === null || v === "" ? null : parseFloat(v); }
    return c.textContent;
  }
  // the sortable headers carry data-col, their column index (a device group header above them doesn't sort)
  Array.prototype.forEach.call(document.querySelectorAll("table.sortable"), function (t) {
    var ths = t.tHead.querySelectorAll("th[data-col]");
    Array.prototype.forEach.call(ths, function (th) {
      var i = parseInt(th.getAttribute("data-col"), 10);
      th.addEventListener("click", function () {
        var dir = th.getAttribute("aria-sort") === "ascending" ? -1 : 1, num = th.classList.contains("n");
        if (num && !th.hasAttribute("aria-sort")) dir = -1;   // first click on a number: hottest first
        Array.prototype.forEach.call(ths, function (h) { h.removeAttribute("aria-sort"); });
        th.setAttribute("aria-sort", dir === 1 ? "ascending" : "descending");
        var body = t.tBodies[0], rows = Array.prototype.slice.call(body.rows);
        rows.sort(function (a, b) {
          var x = val(a, i, num), y = val(b, i, num);
          if (x === null && y === null) return 0;
          if (x === null) return 1;
          if (y === null) return -1;
          if (num) return dir * (x - y);
          return dir * x.localeCompare(y, undefined, { numeric: true });
        });
        rows.forEach(function (r) { body.appendChild(r); });
      });
    });
  });
  var want = location.hash.slice(1);
  show(want && document.getElementById("p-" + want) ? want : "overview");
})();
</script>
</body>
</html>
EOF

# The page body: header, nav and panels. Inputs: hostmax, view, temps_summary.txt, pivot ("group type chip dev sensor
# host value high crit flag", sorted), hosts (sorted). Strings are already [A-Za-z0-9_.:=-]; e() escapes anyway.
# A type table has a row of device groups over the sensors when any column has a device (gs[j] = 1 where a group
# starts); a sensor's crit goes under its name when every host has the same one, else into each cell.
HTML_AWK='
function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function fc(f) { return f ~ /^crit/ ? "crit" : f ~ /^high/ ? "high" : f ~ /^near/ ? "near" : f ~ /rise/ ? "rise" : "" }
function f1(x) { return x == "-" ? x : sprintf("%.1f", x) }
function num(x) { return x == "-" ? "" : x }
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "<thead><tr>"; for (i = 1; i <= NF; i++) hdr = hdr "<th data-col=\"" (i - 1) "\"" (i >= 7 && i < NF ? " class=\"n\"" : "") ">" $i "</th>"; hdr = hdr "</tr></thead>"; next }
    ns++; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FILENAME == ARGV[3] { if (FNR > 1 && $12 ~ /^nodata/) nd[++nn] = "<tr><td class=\"host\">" e($1) "</td><td>" e($2) "</td><td>" e(substr($12, 8)) "</td></tr>"; next }
FILENAME == ARGV[4] { p = $1 "-" $2; if (!(p in pc)) { pord[++np] = p; pg[p] = $1; pt[p] = $2 }
    c = $3 ":" $5 "@" $4
    if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cchip[p, nc[p]] = $3; cd[p, nc[p]] = $4; cs[p, nc[p]] = sname($1, $5); cr[p, c] = f1($9) }
    else if (cr[p, c] != f1($9)) crmix[p, c] = 1
    cell[p, c, $6] = f1($7); ccr[p, c, $6] = f1($9); cv[p, c, $6] = $7; cf[p, c, $6] = fc($10); has[p, $6] = 1; pc[p]++; next }
function sname(g, s) { if (g == "bmc") sub(/_[Tt]emp$/, "", s); gsub(/_/, " ", s); return s }
FILENAME == ARGV[5] { ho[++nho] = $1; next }
FILENAME == ARGV[6] { ur[++nur] = "<tr><td class=\"host\">" e($1) "</td><td>" e($2) "</td></tr>"; next }
function row(l,   p, i, n, s, c) { n = split(l, p, " "); c = fc(p[n]); s = "<tr" (c != "" ? " class=\"" c "\"" : "") ">"
    for (i = 1; i <= n; i++) s = s "<td" (i >= 7 && i < n ? " class=\"n\" data-v=\"" num(p[i]) "\"" : "") ">" e(p[i]) "</td>"; return s "</tr>" }
END {
    split("inlet cpu gpu mem nvme nic other", tyo, " "); split("Inlet CPU GPU Mem NVMe NIC Other", tyn, " ")
    for (i = 1; i <= 7; i++) tname[tyo[i]] = tyn[i]
    gname["bmc"] = "BMC / IPMI"; gname["os"] = "OS (hwmon, nvidia-smi)"
    printf "<header><h1>Thermals: %s</h1><div class=\"mut\">%s to %s UTC &middot; %s &middot; hwmon + nvidia-smi%s &middot; thermals_capture %s</div></header>\n", e(label), e(start), e(end), (nsamp > 1 ? nsamp " samples (cells show the max)" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), e(ver)
    print "<div class=\"body\"><nav id=\"nav\" aria-label=\"Sections\">"
    print "<button type=\"button\" data-panel=\"overview\" aria-selected=\"true\"><span>Overview</span><span class=\"count\">" nh "</span></button>"
    print "<div class=\"navgroup\">By type</div>"
    for (t = 1; t <= 7; t++) { ty = tyo[t]; tc = ((("os-" ty) in pc) ? pc["os-" ty] : 0) + ((("bmc-" ty) in pc) ? pc["bmc-" ty] : 0); if (!tc) continue
        print "<button type=\"button\" data-panel=\"" ty "\" aria-selected=\"false\"><span>" tname[ty] "</span><span class=\"count\">" tc "</span></button>" }
    print "<div id=\"nav-footer\"><button type=\"button\" data-panel=\"notread\" aria-selected=\"false\"" (nn + nur ? " class=\"warn\"" : "") "><span>Not read</span><span class=\"count\">" nn + nur "</span></button></div>"
    print "</nav><main>"
    print "<section class=\"panel\" id=\"p-overview\"><h2>Overview</h2>"
    printf "<div class=\"card\"><span class=\"res %s\">%s</span> &middot; %d of %d hosts gave readings &middot; %d sensors &middot; %d flagged &middot; %d no-data%s%s</div>\n", res, res, hwd, nt, ns, nf, nn, (unreach ? " &middot; " unreach " unreachable (no ssh connection)" : ""), (nn + nur ? " &middot; <a href=\"#notread\" data-panel=\"notread\">see Not read</a>" : "")
    if (nh) { print "<h3>Hottest reading per host and type (&deg;C)</h3><div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Host</th><th class=\"n\" data-col=\"1\">Inlet</th><th class=\"n\" data-col=\"2\">CPU</th><th class=\"n\" data-col=\"3\">GPU</th><th class=\"n\" data-col=\"4\">Mem</th><th class=\"n\" data-col=\"5\">NVMe</th><th class=\"n\" data-col=\"6\">NIC</th><th class=\"n\" data-col=\"7\">Other</th><th data-col=\"8\">Flags</th></tr></thead><tbody>"
        for (i = 1; i <= nh; i++) { split(hm[i], q, " ")
            w = q[9] ~ /crit/ ? "crit" : q[9] ~ /high/ ? "high" : q[9] ~ /near/ ? "near" : q[9] ~ /rise/ ? "rise" : ""
            s = "<tr" (w != "" ? " class=\"" w "\"" : "") "><td class=\"host\">" e(q[1]) "</td>"; for (j = 2; j <= 8; j++) s = s "<td class=\"n\" data-v=\"" num(q[j]) "\">" q[j] "</td>"
            print s "<td>" e(q[9]) "</td></tr>" }
        print "</tbody></table></div>" }
    if (nf) { print "<h3>Flagged sensors</h3><div class=\"wrap\"><table class=\"sortable\">" hdr "<tbody>"; for (i = 1; i <= nf; i++) print row(fr[i]); print "</tbody></table></div>" }
    print "<p class=\"mut\">Flags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "&deg;C of high" (nsamp > 1 ? "; rise = up more than " rise "&deg;C over the samples" : "") ".</p></section>"
    for (t = 1; t <= 7; t++) { ty = tyo[t]; if (!((("os-" ty) in pc) || (("bmc-" ty) in pc))) continue
        printf "<section class=\"panel\" id=\"p-%s\"><h2>%s</h2><p class=\"mut\">The OS table (hwmon, nvidia-smi) and the BMC / IPMI table. One row per host; each cell is the %s in &deg;C, with the crit threshold under the sensor name (in the cell when hosts differ); flagged readings are shaded. Click a sensor to sort.</p>\n", ty, tname[ty], (nsamp > 1 ? "highest reading" : "reading")
        for (g = 1; g <= 2; g++) { p = (g == 1 ? "os" : "bmc") "-" ty; if (!(p in pc)) continue
        printf "<h3>%s <span class=\"mut\">&middot; %d reading%s</span></h3>\n", gname[pg[p]], pc[p], (pc[p] == 1 ? "" : "s")
        two = 0; for (j = 1; j <= nc[p]; j++) { gs[j] = (j == 1 || cd[p, j] != cd[p, j - 1] || cchip[p, j] != cchip[p, j - 1]); if (cd[p, j] != "-") two = 1 }
        s = "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\"" (two ? " rowspan=\"2\"" : "") ">Host</th>"
        if (two) { for (j = 1; j <= nc[p]; j = k) { for (k = j + 1; k <= nc[p] && !gs[k]; k++) ; s = s "<th class=\"grp\" colspan=\"" (k - j) "\">" (cd[p, j] != "-" ? e(cd[p, j]) "<span class=\"chip\">" e(cchip[p, j]) "</span>" : e(cchip[p, j])) "</th>" }
            s = s "</tr><tr>" }
        for (j = 1; j <= nc[p]; j++) { c = col[p, j]
            s = s "<th class=\"n" (gs[j] ? " gs" : "") "\" data-col=\"" j "\">" e(cs[p, j]) "<span class=\"dev\">" (((p, c) in crmix) ? "temp / crit" : (cr[p, c] == "-" ? "no crit" : "crit " cr[p, c])) "</span></th>" }
        print s "</tr></thead><tbody>"
        for (h = 1; h <= nho; h++) { x = ho[h]; if (!((p, x) in has)) continue
            s = "<tr><td class=\"host\">" e(x) "</td>"
            for (j = 1; j <= nc[p]; j++) { c = col[p, j]; k = "n" (gs[j] ? " gs" : "")
                s = s (((p, c, x) in cell) ? "<td class=\"" k (cf[p, c, x] != "" ? " " cf[p, c, x] : "") "\" data-v=\"" num(cv[p, c, x]) "\">" cell[p, c, x] (((p, c) in crmix) ? " / " ccr[p, c, x] : "") "</td>" : "<td class=\"" k "\" data-v=\"\">-</td>") }
            print s "</tr>" }
        print "</tbody></table></div>" }
        print "</section>" }
    print "<section class=\"panel\" id=\"p-notread\"><h2>Not read</h2>"
    print "<h3>No temperature data (" nn ")</h3><p class=\"mut\">Reached, but a source gave no reading; never shown as cool.</p>"
    if (nn) { print "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Host</th><th data-col=\"1\">Source</th><th data-col=\"2\">Reason</th></tr></thead><tbody>"; for (i = 1; i <= nn; i++) print nd[i]; print "</tbody></table></div>" }
    else print "<p>None.</p>"
    print "<h3>Unreachable (" nur ")</h3><p class=\"mut\">Took no ssh connection in any sample (timed out, refused, no route, name not found); left out of every count.</p>"
    if (nur) { print "<div class=\"wrap\"><table class=\"sortable\"><thead><tr><th class=\"host\" data-col=\"0\">Target</th><th data-col=\"1\">Reason</th></tr></thead><tbody>"; for (i = 1; i <= nur; i++) print ur[i]; print "</tbody></table></div>" }
    else print "<p>None.</p>"
    print "</section></main></div>" }'

# Markdown, laid out like the html: contents, Overview (result, no-data list, hottest per host and type, flagged
# sensors), then a section per type with its OS and BMC / IPMI tables, one row per host. A BMC table has a column per sensor ("HGX GPU",
# crit in the header when every host has the same one, else in the cell). An OS table has a column per device
# ("ibp13s0 mlx5"); its cell lists that device's sensors ("asic 41.0 · Module0 26.4"), or "max T of N sensors" past 4 of
# them (a CPU socket's cores). A flagged reading is bold with its flag. Every single reading is in the jsonl.
MD_AWK='
function f1(x) { return x == "-" ? x : sprintf("%.1f", x) }
function sname(g, s) { if (g == "bmc") sub(/_[Tt]emp$/, "", s); gsub(/_/, " ", s); return s }
function fl(v, f) { return f == "-" || f == "" ? v : "**" v " " f "**" }
FILENAME == ARGV[1] { hm[++nh] = $0; next }
FILENAME == ARGV[2] { if (FNR == 1) { hdr = "|"; al = "|"; for (i = 1; i <= NF; i++) { hdr = hdr " " $i " |"; al = al (i >= 7 && i < NF ? "--:|" : "---|") } hdr = hdr "\n" al; next }
    ns++; if ($NF != "-") { nf++; fr[nf] = $0 } next }
FILENAME == ARGV[3] { if (FNR > 1 && $12 ~ /^nodata/) nd[++nn] = "- **" $1 "** " $2 ": " substr($12, 8); next }
FILENAME == ARGV[4] { p = $1 "-" $2; if (!(p in pc)) { pord[++np] = p; pg[p] = $1; pt[p] = $2 }
    if ($1 == "bmc") { c = $5; if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cn[p, nc[p]] = sname($1, $5); cr[p, c] = f1($9) }
        else if (cr[p, c] != f1($9)) crmix[p, c] = 1
        cell[p, c, $6] = f1($7); ccr[p, c, $6] = f1($9); cf[p, c, $6] = $10 }
    else { c = $4 " " $3; if (!((p, c) in seen)) { seen[p, c] = 1; col[p, ++nc[p]] = c; cn[p, nc[p]] = ($4 == "-" ? $3 : $4 " " $3) }
        k = p SUBSEP c SUBSEP $6; n[k]++; if (n[k] == 1 || $7 + 0 > mx[k]) mx[k] = $7 + 0
        lst[k] = lst[k] (lst[k] == "" ? "" : " · ") sname($1, $5) " " fl(f1($7), $10); if ($10 != "-") wf[k] = $10 }
    has[p, $6] = 1; pc[p]++; next }
{ ho[++nho] = $1 }
function row(l,   q, i, m, s) { m = split(l, q, " "); s = "|"; for (i = 1; i <= m; i++) s = s " " (i == m && q[i] != "-" ? "**" q[i] "**" : q[i]) " |"; return s }
END {
    split("inlet cpu gpu mem nvme nic other", tyo, " "); split("Inlet CPU GPU Mem NVMe NIC Other", tyn, " ")
    for (i = 1; i <= 7; i++) tname[tyo[i]] = tyn[i]
    gname["bmc"] = "BMC / IPMI"; gname["os"] = "OS (hwmon, nvidia-smi)"; gshort["bmc"] = "BMC"; gshort["os"] = "OS"
    printf "# Thermals: %s\n\n%s to %s UTC · %s · hwmon + nvidia-smi%s · thermals_capture %s\n\n", label, start, end, (nsamp > 1 ? nsamp " samples (tables show the max)" : "one reading"), (ipmi ? " + BMC (ipmitool)" : ""), ver
    printf "**%s** · %d of %d hosts gave readings · %d sensors · %d flagged · %d no-data%s\n", res, hwd, nt, ns, nf, nn, (unreach ? " · " unreach " unreachable (no ssh connection)" : "")
    s = ""
    for (t = 1; t <= 7; t++) { ty = tyo[t]; tc = ((("os-" ty) in pc) ? pc["os-" ty] : 0) + ((("bmc-" ty) in pc) ? pc["bmc-" ty] : 0)
        if (tc) s = s " · [" tname[ty] "](#" ty ") (" tc ")" }
    print "\n**Contents:** [Overview](#overview)" s
    print "\n## Overview"
    if (nn) { print "\n### No temperature data (never read as cool)\n"; for (i = 1; i <= nn; i++) print nd[i] }
    if (nh) { print "\n### Hottest reading per host and type (°C)\n\n| Host | Inlet | CPU | GPU | Mem | NVMe | NIC | Other | Flags |\n|---|--:|--:|--:|--:|--:|--:|--:|---|"
        for (i = 1; i <= nh; i++) { split(hm[i], q, " "); s = "| " q[1] " |"; for (j = 2; j <= 8; j++) s = s " " q[j] " |"; print s " " (q[9] == "-" ? "-" : "**" q[9] "**") " |" } }
    if (nf) { print "\n### Flagged sensors\n\n" hdr; for (i = 1; i <= nf; i++) print row(fr[i]) }
    print "\nFlags: crit = at or above crit (or BMC cr/nr); high = at or above high (or BMC nc); near = within " margin "°C of high" (nsamp > 1 ? "; rise = up more than " rise "°C over the samples" : "") "."
    for (t = 1; t <= 7; t++) { ty = tyo[t]; if (!((("os-" ty) in pc) || (("bmc-" ty) in pc))) continue
        print "\n## " tname[ty]
        for (gi = 1; gi <= 2; gi++) { g = (gi == 1 ? "os" : "bmc"); p = g "-" ty; if (!(p in pc)) continue
        printf "\n### %s · %d reading%s\n\n", gname[g], pc[p], (pc[p] == 1 ? "" : "s")
        s = "| Host |"; a = "|---|"
        for (j = 1; j <= nc[p]; j++) { c = col[p, j]
            s = s " " cn[p, j] (g == "bmc" ? (((p, c) in crmix) ? " (temp / crit)" : (cr[p, c] == "-" ? "" : " (crit " cr[p, c] ")")) : "") " |"; a = a (g == "bmc" ? "--:|" : "---|") }
        print s "\n" a
        for (h = 1; h <= nho; h++) { x = ho[h]; if (!((p, x) in has)) continue
            s = "| " x " |"
            for (j = 1; j <= nc[p]; j++) { c = col[p, j]
                if (g == "bmc") s = s " " (((p, c, x) in cell) ? fl(cell[p, c, x] (((p, c) in crmix) ? " / " ccr[p, c, x] : ""), cf[p, c, x]) : "-") " |"
                else { k = p SUBSEP c SUBSEP x; s = s " " (!(k in n) ? "-" : n[k] <= 4 ? lst[k] : fl("max " f1(mx[k]) " of " n[k] " sensors", wf[k])) " |" } }
            print s } } }
    print "\nEvery single reading is in the jsonl (-o jsonl)." }'

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
    [[ $1 == --help ]] && { usage; exit 0; }
    : "${FF_SSH_USER:=$(id -un)}" "${FF_SSH_PARALLEL:=64}" "${FF_MAX_TARGETS:=4096}" "${FF_OUT_DIR:=.}"
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
    # targets: FF_HOSTS (backends as FF_SSH_USER, key ssh), or the -t file's rows (FF_SSH_USER the default login)
    declare -ga T_LOGIN=() T_PW=() T_TYPE=() T_LINE=() T_FROM=() T_ROW=() BMCS=() B_LOGIN=() B_PW=() B_LINE=() B_ROW=(); HAVE_PW=0
    TARGETS=(); _SEEN=(); INPUT_RANGES=0
    [[ $FF_SSH_USER =~ ^[A-Za-z0-9._@-]+$ ]] || die "FF_SSH_USER: bad login (letters, digits . _ @ - only)"
    if [[ -n $FF_HOSTS ]]; then expand_targets "$FF_HOSTS"; for v in "${!TARGETS[@]}"; do T_LOGIN[$v]=$FF_SSH_USER; T_TYPE[$v]=backend; done; fi
    [[ -n $tfile ]] && load_target_file "$tfile" "$FF_SSH_USER"
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
    # a password ssh login: SSH_ASKPASS reading a one-use fifo (no sshpass, never in an environment or argv); pw_transport
    # (auth.sh) checks this ssh takes it unattended, or dies
    SETSID=; (( ${#T_PW[@]} )) && pw_transport
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

    # nodata rows come out in awk's hash order (differs between awks): sort them so the output is the same
    # a sensor with a crit but no high (or 0) gets high = 95% of crit, so high and near flag it too (Frank 10-26)
    awk 'NR > 1 && $6 != "none" && ($8 == "-" || $8 + 0 <= 0) && $9 != "-" && $9 + 0 > 0 { $8 = sprintf("%.1f", $9 * 0.95) } { print }' \
        "$WORK/temps.txt" > "$WORK/temps.hi" && mv "$WORK/temps.hi" "$WORK/temps.txt"
    awk -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" "$TEMP_SUM_AWK" "$WORK/temps.txt" > "$WORK/temps_summary.raw"
    { awk '$12 !~ /^nodata/' "$WORK/temps_summary.raw"; awk '$12 ~ /^nodata/' "$WORK/temps_summary.raw" | sort -k1,1 -k2,2; } > "$WORK/temps_summary.sorted"
    awk "$TYPE_AWK" "$WORK/temps.txt" "$WORK/temps_summary.sorted" > "$WORK/temps_summary.txt"
    awk -v ns="$NSAMP" "$VIEW_AWK" "$WORK/temps_summary.txt" > "$WORK/view"
    awk "$HOST_MAX_AWK" "$WORK/temps_summary.txt" | sort -k1,1V > "$WORK/hostmax"
    # the html's per-type tables: "group type chip dev sensor host value high crit flag", BMC first, then by type,
    # chip, device and sensor (version order, any case: Core_2 before Core_10, asic before Module0); hosts likewise
    awk 'BEGIN { split("inlet cpu gpu mem nvme nic other", t, " "); for (i = 1; i <= 7; i++) r[t[i]] = i }
         NR > 1 && $6 != "none" { g = ($2 == "ipmi" ? "bmc" : "os"); print (g == "bmc" ? 1 : 2), r[$3], $4, $5, tolower($6), g, $3, $4, $5, $6, $1, $8, $10, $11, $12 }' \
        "$WORK/temps_summary.txt" | sort -k1,1n -k2,2n -k3,3 -k4,4V -k5,5V | cut -d' ' -f6- > "$WORK/pivot"
    awk 'NR > 1 && $6 != "none" {print $1}' "$WORK/temps_summary.txt" | sort -u | sort -V > "$WORK/hostorder"
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
            html) { printf '%s\n' "${HTML_HEAD//@TITLE@/Thermals $label}"
                    awk "${common[@]}" "$HTML_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" "$WORK/pivot" "$WORK/hostorder" "$WORK/unreachlist"
                    printf '%s\n' "$HTML_TAIL"; } > "$f.tmp" ;;
            md) awk "${common[@]}" "$MD_AWK" "$WORK/hostmax" "$WORK/view" "$WORK/temps_summary.txt" "$WORK/pivot" "$WORK/hostorder" > "$f.tmp" ;;
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
