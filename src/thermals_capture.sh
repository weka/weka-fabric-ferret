#!/usr/bin/env bash
# thermals_capture: every hwmon temperature and the BMC's (ipmitool) on a set of hosts, read only, over ssh.
# One snapshot by default, or a sample every -i seconds for -d seconds. Output: any of .jsonl, .html, .md.
# Standalone companion to fabric_ferret.sh: same host syntax and FF_ settings, same reader and flags.
# bash 4.3+ (declare -A, wait -n, namerefs): checked first, in bash 3 syntax, before anything else runs
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } || {
    echo "thermals_capture.sh: needs bash 4.3+ (this is bash $BASH_VERSION)" >&2; echo "RESULT data=STOPPED (needs bash 4.3+)" >&2; exit 2; }

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
                   page per type with its OS and BMC tables, one row per host, sortable; md: the same layout).
                   A run that saw an ssh failure also writes thermcap_<UTC>.ssh_errors.log: one line per failed
                   read, "s<sample> <target> rc=<rc>: <ssh's stderr>" (the no-data reason is its last line)
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
  FF_FERRET (0)    1 = on a terminal a ferret roams over the log (ferret_view.py beside it, python3; r rolls it,
                   q hides it; blocks = half blocks for a font without braille). A dead viewer: said once, the
                   run goes on, its lines not replayed (the files hold the data)

Flags per sensor, worst first: crit (at or above crit, or BMC status cr/nr), high (at or above high, or BMC
nc), near (within FF_TEMP_MARGIN of high), then +rise. A threshold of 0 counts as unset. A sensor with a crit
but no high gets high = 95% of crit. A host or source that
connected but gave no reading (auth refused, cut off, no hwmon, no ipmitool, sudo refused, ipmitool timed out) gets a nodata record
with the reason: no data is never shown as cool.

Output: stdout gets one row per host: the GPU cells from nvidia-smi when it answered, the BMC's (ipmi) otherwise; every other
type the BMC's, hwmon's only for a type the BMC lacks; Source lists the sources used: "Host Source Sensors Inlet Avg CPU Avg GPU Avg
Mem Avg NVMe Avg NIC Avg Other Avg Flags", each type's hottest reading and the mean of its sensors' latest readings; Sensors
counts every sensor of the host, all sources; Flags lists every flagged sensor of the host, one behind no shown cell with its
source ("cpu:high/hwmon"); stderr gets the progress, the flagged sensors, the no-data list and the result. Every sensor, one
row each, is in the files (-o).
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

#@include sh/ipaddr.sh

#@include sh/expand.sh

#@include sh/tc_reader.sh

#@include sh/auth.sh

#@include sh/tc_bmc.sh

#@include sh/tc_summary.sh

#@include sh/jobs.sh

#@include sh/tc_collect.sh

#@include sh/hostfile.sh

#@include sh/tc_unreach.sh

#@include sh/tc_output.sh

#@include sh/tc_main.sh

# ---------- main ----------

main() {
    [[ $1 == --help ]] && { usage; exit 0; }
    local pl; for pl in "${HF_PRELOG[@]}"; do log "$pl"; done   # the -t file's settings notes (settings_prepass, run first)
    : "${FF_SSH_USER:=$(id -un)}" "${FF_SSH_PARALLEL:=64}" "${FF_MAX_TARGETS:=4096}" "${FF_OUT_DIR:=.}"
    : "${FF_IPMI:=1}" "${FF_IPMI_TIMEOUT:=60}" "${FF_TEMP_MARGIN:=5}" "${FF_TEMP_RISE:=10}"
    local v; for v in FF_IPMI_TIMEOUT FF_SSH_PARALLEL FF_MAX_TARGETS; do   # FF_HOSTS expands against FF_MAX_TARGETS below
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
    # the capture (tc_main.sh, shared with fabric_ferret.sh --thermals-only)
    tc_check_settings
    (( list )) && tc_list
    tc_check_opts
    tc_run
}

# run when executed or fed on stdin (ssh jump 'bash -s' < script: BASH_SOURCE is empty); not when sourced
# FF_FERRET: on a terminal the log goes through ferret_view.py (beside this script) to stderr. Missing python3
# or file: said once, then the plain run; no terminal: the plain run. A dead viewer: the terminal restored, a
# line, the rest copied. FF_VIEWER (its command): a test hook.
if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    # A -t file's settings lines first, exported, before anything reads a setting (FF_FERRET, FF_VIEWER included):
    # the file works as the command line does. -t found as main's getopts finds it; a bad line dies here, rc 2.
    HF_PRELOG=(); HF_KNOWN=$TC_KNOWN; HF_OTHER=$FF_KNOWN; HF_OTHER_NAME=fabric_ferret.sh
    pre_t=; OPTIND=1
    while getopts ":o:i:d:t:vh" pre_o; do [[ $pre_o == t ]] && pre_t=$OPTARG; done
    OPTIND=1
    [[ -n $pre_t ]] && settings_prepass "$pre_t"
    view=()
    if [[ -n $FF_FERRET && $FF_FERRET != 0 ]]; then
        if [[ -n $FF_VIEWER ]]; then view=("$FF_VIEWER")
        elif ! py=$(command -v python3); then echo "# FF_FERRET: python3 not found, running without the ferret" >&2
        elif [[ ! -f $(dirname "$0")/ferret_view.py ]]; then echo "# FF_FERRET: ferret_view.py not found beside $0, running without the ferret" >&2
        elif [[ -t 2 ]]; then view=("$py" "$(dirname "$0")/ferret_view.py"); fi
    fi
    if (( ${#view[@]} )); then
        trap ':' INT TERM HUP   # keep waiting for main's cleanup on Ctrl-C or a group kill (a no-op trap, so main gets its own)
        # fd 3 carries main's stdout (the rows); on a terminal they would land on the curses screen, so they are held
        # in a file until the viewer has exited and replayed the log, then printed. Not a terminal: straight through.
        viewed() { { main "$@" 2>&1 1>&3 3>&- | ( trap '' INT TERM HUP; { "${view[@]}" || { vrc=$?; [[ -t 2 ]] && printf '\033[?1049l\033[?25h\033[0m'; echo "# FF_FERRET: the ferret viewer stopped (rc $vrc); the run continues plainly"; cat; }; } >&2 3>&- ); rc=${PIPESTATUS[0]}; }; }
        if [[ -t 1 ]]; then
            rows=$(mktemp "${TMPDIR:-/tmp}/tc_rows.XXXXXX") || exit 2
            viewed "$@" 3>"$rows"; cat "$rows"; rm -f "$rows"
        else viewed "$@" 3>&1; fi
        exit "$rc"
    else main "$@"; fi
fi
