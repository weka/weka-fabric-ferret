#!/usr/bin/env bash
# Built by ./build from src/ (README, Source): edit src/, never this file.
# fabric_ferret: backend-to-backend (any number of rails) and client-to-backend iperf3 fabric check.
# Hosts and rails come from env vars (see usage); output is a .tgz bundle
# that generate_dashboard.py turns into an HTML dashboard.
# bash 4.3+ (declare -A, wait -n, namerefs): checked first, in bash 3 syntax, before anything else runs
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } || {
    echo "fabric_ferret.sh: needs bash 4.3+ (this is bash $BASH_VERSION)" >&2; echo "RESULT coverage=STOPPED (needs bash 4.3+)" >&2; exit 2; }

usage() {
    cat <<'EOF'
Usage: FF_HOSTS=<targets> FF_RAILS='<cidr,...>;<cidr,...>' ./fabric_ferret.sh [duration_s]
       FF_RAILS='<cidr,...>;<cidr,...>' ./fabric_ferret.sh -t FILE [duration_s]   (targets from a file instead)
       FF_HOSTS=<targets> ./fabric_ferret.sh --list   (print expanded targets, no ssh; -t FILE works too)
From a jump host (settings ride in the remote command; nothing to edit or copy first):
       ssh jump "FF_HOSTS=10.1.0.0/24 FF_RAILS='10.20.1.0/24;10.20.2.0/24' bash -s -- 120" < fabric_ferret.sh
       The run ends by printing the scp + render line for the tarball it left on the jump host.
       With -t: bash -s -- -t FILE 120, and FILE must be on the jump host (copy it there first).

  -t FILE    targets from a file instead of FF_HOSTS/FF_CLIENTS (not both): <type>,<host>,<login>,<pw> lines, the
             format thermals_capture.sh reads (# comments; a line with no comma is a backend). Types: backend (or
             host) and client, each an IP, hostname, CIDR or range as in FF_HOSTS; bmc lines are skipped (counted in
             one log line). Each target takes its row's login and password, credential rows (a host of * or a
             glob) included, as thermals_capture.sh resolves them; no login: FF_SSH_USER; no password: key ssh.
             A password is read once, where the target's ssh session opens, through SSH_ASKPASS from a one-use
             fifo (OpenSSH 8.4+, or setsid, here): never an environment variable, a command line or a file.
             Remote steps run as root: a root login directly; any other login through the first passwordless
             escalator (FF_SSH_USER below); where none works, a row password runs them with sudo -S -k (the
             password first on the ssh input stream, behind a guard that never lets it run as a command). A host
             with neither is left out, listed in unusable.txt with the reason, and counted as missing.
The bundle also carries each host's system info (sysinfo/<host>/<item>: OS, CPU, PCIe, NIC rings/IRQs/QoS, routes,
sysctls, kernel log over the run) and host_rx.txt, the per-host receive side (rings, PCIe, drops, iperf3 CPU, flags).

Required
  FF_HOSTS   ssh targets, comma or space separated, any mix of:
               10.1.0.5,node07          single IPs or hostnames
               10.1.0.0/24              CIDR (network and broadcast dropped below /31)
               10.1.0.10-10.1.1.20      full range
               10.1.0.10-40             last-octet range
               10.1.0-1.10-40           per-octet ranges (nmap style)
               @hosts.txt               file, entries split on lines/commas/spaces, # comments
  FF_RAILS   each rail's data subnets: ';' between rails (A first), ',' between a rail's subnets.
               '10.20.1.0/24;10.20.2.0/24'                two rails, one subnet each
               '10.20.1.0/24,10.20.3.0/24;10.20.2.0/24'   rail A has two subnets
               10.20.1.0/24                               one rail (no cross-rail phase)
             Any number of rails, labelled A, B, C... Quote it: ';' ends a shell command.
   or
  FF_NICS    data NIC per rail, rail A first:   enp5s0np0,enp196s0np0   (wins over FF_RAILS)
  None set: the tool sweeps the hosts, prints the IPv4 subnets it found, and stops.

Clients (optional): tested against every backend rail, both ways
  FF_CLIENTS        client ssh targets, FF_HOSTS syntax
  FF_CLIENT_NETS    the clients' data subnets, comma separated (every NIC with an address in them is a data NIC)
   or
  FF_CLIENT_NICS    the clients' data NIC names, comma separated (a client may have one or several)
                    Neither set: the tool lists the subnets on the clients and stops.
  FF_CLIENT_RATIO   N (1): waves, at most N client NICs on each backend NIC at once; full: every client NIC
                    at once, clients->backends then backends->clients; N:full: the waves, then all at once
  FF_CLIENT_GBPS    client line rate (default: each client NIC's ethtool speed; a bond counts its total)
  FF_EXPECT_CLIENTS clients that should be tested; fewer makes the coverage PARTIAL
  A client run is judged against min(client line rate, backend rail line rate / flows sharing that backend NIC).
  Clients follow FF_ITER: each iteration ends with a client phase and moves every client NIC on to the next
  backend, so after as many iterations as a rail has backends every client NIC has met every backend NIC
  (FF_ITER=all covers it). Each client's route to each backend rail must leave by a declared data NIC; one
  that leaves by another NIC (management, say) is flagged.

Optional (default)
  FF_DURATION      iperf3 seconds per run (120; $1 also sets it)
  FF_ITER          passes of the full test set (every host and client NIC, every phase), to flush out
                   noise and outliers; each pass gets new partners, round robin: no pair repeats, every
                   host pair is tested after n-1 passes (n if n is odd); the next n-1 swap client
                   and server, so every direction on every NIC pair runs after 2(n-1).
                   all = 2(n-1) (3)
  FF_STREAMS       iperf3 parallel streams, >=2 (16)
  FF_TOS           IP TOS byte for the test traffic, 0-255 (iperf3 -S), e.g. 106 = DSCP 26
                   + ECT(0); TCP keeps the DSCP, the kernel sets the ECN bits (unset: 0)
  FF_SKIP_IPERF=1  no iperf3 at all, for a cluster whose I/O can't stop (WEKA running): every other check
                   runs (discovery, rails, path checks for every planned path, mesh, LLDP, NIC/FEC/priority
                   and drop counters, system info, host-side receive), the counters over one FF_DURATION
                   window of the cluster's own traffic. The busy check reports but doesn't stop the run.
  FF_UDP (1)       after the TCP phases, run the same pairs (and client runs) with UDP and no rate cap; 0 = off
                   (iperf3 -u -b 0, datagrams sized to the path MTU). Loss is split into sender
                   TX (never left the sender's NIC: kernel and port tx packet counts, udp_tx.txt),
                   receiver socket, NIC, kernel backlog and unaccounted. Uncapped UDP has no
                   backoff: where what the senders sent into a NIC exceeds its line, 1 - line/offered
                   is expected loss (udp_expected.txt); only unaccounted loss beyond it is flagged.
                   With FF_TOS the whole TOS byte, ECN bits included, is sent.
  FF_UDP_DURATION  seconds per UDP run (FF_DURATION)
  FF_IGNORE_LOCK=1 run even if another fabric_ferret run holds a host (two runs on the same hosts
                   kill each other's iperf3 servers and both get garbage)
  FF_MESH (1)      before load, ping every tested host's rail IPs from every other one's (same rail and
                   cross-rail), and every backend rail IP from every client data NIC (clients never
                   ping each other); tested hosts only, so other clusters on shared subnets are never
                   probed. Failures go to mesh_failures.txt and the Preflight card. 0 = off.
  FF_CROSS_RAIL=0  the rails are separate fabrics by design: skip the cross-rail phase and leave it
                   out of the coverage count. Default: test it; unrouted cross-rail paths count
                   as skipped (PARTIAL), since missing inter-rail routes can be the fault. When every
                   cross-rail check fails on routing and no same-rail one does, the log says so.
  FF_CROSS_MAX=N   at most N cross-rail flows at once: phase 2 (and U2) run in balanced waves,
                   each flow for the full duration; keeps a shared inter-rail path from capping
                   every flow (unset: all at once)
  FF_SYSINFO_TIMEOUT  seconds per host for the system info capture before load (300); a host that runs
                   out keeps what it sent and is flagged sysinfo_partial
  FF_PORT          iperf3 port (5201)
  FF_SSH_USER      ssh user, and -t's default login (the current user). A non-root login with no -t password runs
                   the remote steps through the first passwordless escalator: on each host, once per run, during
                   the sweep, `<escalator> true` (5 s timeout) for dzdo -n, pbrun, sesu, pmrun, doas -n, ksu -e,
                   sudo -n, in that order
  FF_SSH_PARALLEL  ssh sessions at once for sweep and collection (64)
  FF_SSH_RETRY_PARALLEL  retry targets that refused ssh under load (reset, kex) this many at a time (8)
  FF_MAX_TARGETS   refuse to expand FF_HOSTS beyond this (4096)
  FF_LABEL         name in the report and tarball (first tested hostname)
  FF_OUT_DIR       where the .tgz bundle goes (.)
  FF_LINE_GBPS     link speed for OK/SLOW cut-offs: N for every rail, or one per rail (A,B,...) when
                   the rails differ by design (e.g. 100,50). Default: the fastest rail's most common
                   NIC speed for all, so a rail that came up slow everywhere shows as slow
  FF_OK_PCT        OK at or above this % of link speed (75)
  FF_SLOW_PCT      SLOW at or above this %, CRITICAL below (50)
  FF_RETR_PCT      a data NIC whose TCP retransmits exceed this % of the segments it sent gets (retr) on its
                   Status; throughput still decides OK/SLOW/CRITICAL (0.1)
  FF_TEMPS (1)     read every hwmon temperature (/sys/class/hwmon: CPU, NVMe, NIC…) on every host and client
                   before the run and after every phase, read only; temps.txt, temps_summary.txt. 0 = off
  FF_IPMI (1)      with FF_TEMPS, also the BMC's temperatures (inlet, exhaust…) via ipmitool sensor, once per
                   iteration and at the end, where ipmitool is installed (needs root or sudo). 0 = off
  FF_IPMI_TIMEOUT  seconds per ipmitool read (60)
  FF_TEMP_MARGIN   a sensor within this many °C of its high threshold is flagged near (5)
  FF_TEMP_RISE     a sensor that climbs more than this many °C over the run is flagged rise (10)

                   Each iteration: phase 1 same rail (A->A, B->B, ...); phase 2 cross-rail, one flow each
                   way per pair between two rails (with more than two rails, the rail pair rotates each
                   pairing cycle). Host Status = the worst of its rail columns and Cross;
                   SLOW(cross)/CRITICAL(cross) = only the cross-rail runs were that slow.
  FF_SPINES        number of spines every leaf uplinks to (all three uplink settings or none; no defaults)
  FF_SPINE_LINKS   uplinks from each backend leaf to EACH spine
  FF_SPINE_GBPS    Gbps per uplink; the summary judges each leaf's cross-leaf runs (leaf = LLDP neighbour)
                   against spines x links x Gbps per direction: oversubscribed by design, or a lost
                   link/spine. Without these it only sums each leaf's runs. Status is unchanged.
  FF_CLIENT_SPINE_LINKS  uplinks from each client leaf to each spine (with FF_CLIENT_SPINE_GBPS: both or neither)
  FF_CLIENT_SPINE_GBPS   Gbps per client leaf uplink; they need FF_SPINES (one spine layer serves both). A leaf
                   that serves both clients and backends is flagged and judged as a backend leaf.
  FF_BUSY_CHECK    command run on each host before any load; exit 0 = host is in
                   production use, 1 = idle, anything else = unknown (counts as in use).
                   Default: WEKA containers running (`weka local ps`); idle where WEKA
                   isn't installed. Other example: 'systemctl is-active --quiet myservice'.
                   none = no check.
  FF_BUSY_OK=1     run even where FF_BUSY_CHECK says in use (stop the cluster's I/O first)
  FF_EXPECT_HOSTS  hosts that should be tested; fewer makes the coverage PARTIAL
                   (default: every target for a plain host list, the hosts found on
                   the rails when FF_HOSTS has a CIDR or range)

Result: the last line is "RESULT coverage=COMPLETE|PARTIAL|NONE hosts=t/e paths=r/p ..." (with clients,
also clients=t/e client_paths=r/p);
exit 0 = COMPLETE, 3 = PARTIAL, 4 = NONE (no throughput result at all), 2 = stopped early.
EOF
}

die() { echo "ERROR: $*" >&2; echo "RESULT coverage=STOPPED ($*)" >&2; exit 2; }
log() { echo "# $*" >&2; }
# phase_start / phase_end name / phase_skip name: phase_times.txt rows "iter phase start end" (UTC), to line
# the tool's counters up with switch and monitoring data
phase_start() { PT0=$(date -u +%Y-%m-%dT%H:%M:%SZ); }
phase_end() { echo "$ITER $1 $PT0 $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$COLLECT_DIR/phase_times.txt"; }
phase_skip() { echo "$ITER $1 - -" >> "$COLLECT_DIR/phase_times.txt"; }
# err_hist file...: the ERROR rows ("src,dst,ERROR rc=N iperf3: error - <reason>") grouped by the reason, as
# '<runs> x "<reason>" to <N> destination(s) (<first 4> ...)', one line per reason, most runs first; a row without
# iperf3's prefix keeps its own text; a client row's trailing "share:K" is not part of the reason. A 10-27 field run:
# 138 rows, one reason, 48 destinations, 9 that answered.
err_hist() {
    cat "$@" | tr -s ' ' | awk -F, '$3 ~ /^ *ERROR/ {
        s = $0; sub(/^[^,]*,[^,]*, */, "", s); i = index(s, "iperf3: error - ")
        if (i) s = substr(s, i + 16); else sub(/^ERROR *(rc=[0-9]+)? */, "", s)
        sub(/ share:[0-9]+$/, "", s)
        if (!(s in n)) ord[++no] = s
        n[s]++; if (!(($2, s) in seen)) { seen[$2, s] = 1; nd[s]++; if (nd[s] <= 4) dl[s] = dl[s] " " $2 } }
        END { for (i = 1; i <= no; i++) { s = ord[i]; printf "%d x \"%s\" to %d destination%s (%s%s)\n", n[s], s, nd[s], (nd[s] == 1 ? "" : "s"), substr(dl[s], 2), (nd[s] > 4 ? " ..." : "") } }' | sort -t x -k1,1nr
}
log_hist() { err_hist "$@" | sed 's/^/#   /' >&2; }

# ---------- target expansion (pure bash, no ssh) ----------

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

in_cidr() {  # ip cidr; no subshells, it runs per address per host
    is_ip "$1" || return 1
    local -a o; IFS=. read -ra o <<<"$1"
    local n=$(( (10#${o[0]} << 24) + (10#${o[1]} << 16) + (10#${o[2]} << 8) + 10#${o[3]} ))
    local b=${_CIDR_CACHE[$2]}
    [[ -n $b ]] || { b=$(cidr_bounds "$2") || return 1; _CIDR_CACHE[$2]=$b; }
    (( n >= ${b% *} && n <= ${b#* } ))
}
declare -A _CIDR_CACHE=()

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

# Every FF_* setting each tool reads (shared here so each can name the other's). Any other FF_* in the environment
# is a typo that would be silently ignored (a dropped letter, say), so fabric_ferret.sh stops the run on one
# (check_settings); both tools stop on one in a -t file's settings lines. A regress test keeps FF_KNOWN complete.
FF_KNOWN="FF_BUSY_CHECK FF_BUSY_OK FF_CLIENT_GBPS FF_CLIENT_NETS FF_CLIENT_NICS FF_CLIENT_RATIO FF_CLIENT_SPINE_GBPS FF_CLIENT_SPINE_LINKS FF_CLIENTS FF_CROSS_MAX FF_CROSS_RAIL FF_DURATION FF_EXPECT_CLIENTS FF_EXPECT_HOSTS FF_HOSTS FF_IGNORE_LOCK FF_ITER FF_LABEL FF_LINE_GBPS FF_LOCK_FILE FF_MAX_TARGETS FF_MESH FF_NICS FF_OK_PCT FF_OUT_DIR FF_PORT FF_RAILS FF_RETR_PCT FF_RUNLOG FF_SKIP_IPERF FF_SLOW_PCT FF_SPINE_GBPS FF_SPINE_LINKS FF_SPINES FF_SSH_PARALLEL FF_SSH_RETRY_PARALLEL FF_SSH_USER FF_STREAMS FF_SYSFS FF_PROCNET FF_SYSINFO_TIMEOUT FF_TEMP_MARGIN FF_TEMP_RISE FF_TEMPS FF_IPMI FF_IPMI_TIMEOUT FF_TOS FF_UDP FF_UDP_DURATION"
TC_KNOWN="FF_HOSTS FF_SSH_USER FF_SSH_PARALLEL FF_MAX_TARGETS FF_IPMI FF_IPMI_TIMEOUT FF_TEMP_MARGIN FF_TEMP_RISE FF_LABEL FF_OUT_DIR FF_SYSFS FF_PROCFS"

# load_settings_lines file: a -t file's settings lines, "FF_<setting>=value" as the whole line (the value verbatim,
# commas and all), read before the rows so FF_SSH_USER from the file is the rows' default login. The caller sets
# HF_KNOWN (its own names), HF_OTHER and HF_OTHER_NAME (the other tool's) and HF_ENV (the FF_ names exported in
# the environment at startup, " a b "): the environment beats the file; the other tool's names are skipped and
# named once; FF_HOSTS/FF_CLIENTS, a credential-looking name or an unknown one stops the run by line number, the
# value never printed. Sets HF_SET_USER when the file set FF_SSH_USER.
load_settings_lines() {
    local f=$1 line ln=0 nm val; local -a skipped=()
    HF_SET_USER=
    while IFS= read -r line || [[ -n $line ]]; do
        ln=$(( ln + 1 )); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(FF_[A-Z0-9_]+)[[:space:]]*=(.*)$ ]] || continue
        nm=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}; val=${val#"${val%%[![:space:]]*}"}
        [[ $nm =~ PASS|PW|SECRET|TOKEN ]] && die "-t $f line $ln: $nm looks like a credential; a password goes in a row's pw field, never in a setting"
        [[ $nm == FF_HOSTS || $nm == FF_CLIENTS ]] && die "-t $f line $ln: $nm is not a setting here; list the targets as rows"
        if [[ " $HF_KNOWN " == *" $nm "* ]]; then
            if [[ " $HF_ENV " == *" $nm "* ]]; then log "-t $f line $ln: $nm is set in the environment; the file's value is ignored"
            else
                printf -v "$nm" '%s' "$val"; [[ $nm == FF_SSH_USER ]] && HF_SET_USER=1
                # the rows below expand against FF_MAX_TARGETS, so a file value is checked here, not after the load
                [[ $nm == FF_MAX_TARGETS ]] && { [[ $val =~ ^[0-9]+$ ]] && (( val > 0 )) || die "-t $f line $ln: FF_MAX_TARGETS must be a positive integer"; }
            fi
        elif [[ " $HF_OTHER " == *" $nm "* ]]; then skipped+=("$nm")
        else die "-t $f line $ln: unknown setting $nm; this tool reads: ${HF_KNOWN// /, }"; fi
    done < "$f"
    (( ${#skipped[@]} )) && log "-t $f: ${#skipped[@]} setting line(s) for $HF_OTHER_NAME skipped: ${skipped[*]}"
    return 0
}

# load_target_file file deflogin: "<type>,<host>,<login>,<pw>" lines (# comments, blank lines skipped; FF_<setting>=value
# lines are settings, load_settings_lines). type backend
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
    load_settings_lines "$f"; [[ -n $HF_SET_USER ]] && def=$FF_SSH_USER
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
        [[ $line =~ ^[[:space:]]*FF_[A-Z0-9_]+[[:space:]]*= ]] && continue   # a settings line (read above)
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

# ---------- rail spec ----------

# Rails: RAIL_SPEC[r] = rail r's CIDRs (space separated) or NIC name; NR rails, labelled A, B, C...
LETTERS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
rail_letter() { echo "${LETTERS:$1:1}"; }
parse_rails() {
    if [[ -n $FF_NICS ]]; then
        RAIL_MODE=nic; _words "$FF_NICS"; RAIL_SPEC=("${WORDS[@]}")
        local n m
        for n in "${RAIL_SPEC[@]}"; do [[ $n =~ ^[A-Za-z0-9_.:-]+$ ]] || die "bad NIC name in FF_NICS: '$n'"; done
        for (( n = 0; n < ${#RAIL_SPEC[@]}; n++ )); do for (( m = n + 1; m < ${#RAIL_SPEC[@]}; m++ )); do
            [[ ${RAIL_SPEC[n]} != "${RAIL_SPEC[m]}" ]] || die "FF_NICS names the same NIC twice: ${RAIL_SPEC[n]}"
        done; done
    elif [[ -n $FF_RAILS ]]; then
        RAIL_MODE=cidr; RAIL_SPEC=()
        local -a parts; local p
        IFS=';' read -r -a parts <<<"$FF_RAILS"
        for p in "${parts[@]}"; do
            _words "$p"; (( ${#WORDS[@]} )) || die "FF_RAILS has an empty rail: '$FF_RAILS' (';' between rails, ',' between a rail's subnets)"
            RAIL_SPEC+=("${WORDS[*]}")
        done
    else
        RAIL_MODE=none; RAIL_SPEC=(); NR=0; RAILS=(); return
    fi
    NR=${#RAIL_SPEC[@]}; RAILS=($(seq 0 $(( NR - 1 ))))
    (( NR >= 1 && NR <= 26 )) || die "need 1 to 26 rails, got $NR"
    [[ $RAIL_MODE == cidr ]] || return 0
    # a rail is a set of CIDRs; no CIDR of one rail may overlap one of another
    local ca cb a b r s
    for r in "${RAILS[@]}"; do for ca in ${RAIL_SPEC[r]}; do [[ -n $(cidr_bounds "$ca") ]] || die "bad rail CIDR: '$ca'"; done; done
    for r in "${RAILS[@]}"; do for (( s = r + 1; s < NR; s++ )); do
        for ca in ${RAIL_SPEC[r]}; do for cb in ${RAIL_SPEC[s]}; do
            a=$(cidr_bounds "$ca"); b=$(cidr_bounds "$cb")
            if (( ${a% *} <= ${b#* } && ${b% *} <= ${a#* } )); then
                die "rail $(rail_letter $r) $ca overlaps rail $(rail_letter $s) $cb, so the rails can't be told apart; list each rail's subnets or set FF_NICS"
            fi
        done; done
    done; done
}

# Client data NICs: CLIENT_MODE nets (CLIENT_SPEC = CIDRs) or nics (names); none without clients (FF_CLIENTS or -t
# client lines, TF_CL)
parse_clients() {
    CLIENT_MODE=none; CLIENT_SPEC=()
    [[ -n $FF_CLIENTS ]] || (( ${#TF_CL[@]} )) || { [[ -n $FF_CLIENT_NETS$FF_CLIENT_NICS ]] && die "FF_CLIENT_NETS/FF_CLIENT_NICS need FF_CLIENTS or -t client lines (the client ssh targets)"; return 0; }
    local c
    if [[ -n $FF_CLIENT_NICS ]]; then
        CLIENT_MODE=nics; _words "$FF_CLIENT_NICS"; CLIENT_SPEC=("${WORDS[@]}")
        for c in "${CLIENT_SPEC[@]}"; do [[ $c =~ ^[A-Za-z0-9_.:-]+$ ]] || die "bad NIC name in FF_CLIENT_NICS: '$c'"; done
    elif [[ -n $FF_CLIENT_NETS ]]; then
        CLIENT_MODE=nets; _words "$FF_CLIENT_NETS"; CLIENT_SPEC=("${WORDS[@]}")
        for c in "${CLIENT_SPEC[@]}"; do [[ -n $(cidr_bounds "$c") ]] || die "bad client CIDR in FF_CLIENT_NETS: '$c'"; done
    else
        CLIENT_MODE=list   # sweep, list the clients' subnets, stop
    fi
    [[ -z $FF_CLIENT_RATIO || $FF_CLIENT_RATIO =~ ^([1-9][0-9]*|full|[1-9][0-9]*:full)$ ]] ||
        die "FF_CLIENT_RATIO must be N, full or N:full (N = client NICs per backend NIC per wave), got '$FF_CLIENT_RATIO'"
    : "${FF_CLIENT_RATIO:=1}"
    CL_WAVES=1; CL_FULL=0; CL_R=${FF_CLIENT_RATIO%%:*}
    [[ $FF_CLIENT_RATIO == full ]] && { CL_WAVES=0; CL_FULL=1; CL_R=0; }
    [[ $FF_CLIENT_RATIO == *:full ]] && CL_FULL=1
    [[ -z $FF_CLIENT_GBPS || $FF_CLIENT_GBPS =~ ^[1-9][0-9]*$ ]] || die "FF_CLIENT_GBPS must be a positive integer, got '$FF_CLIENT_GBPS'"
    [[ -z $FF_EXPECT_CLIENTS || $FF_EXPECT_CLIENTS =~ ^[1-9][0-9]*$ ]] || die "FF_EXPECT_CLIENTS must be a positive integer"
    return 0
}

# exit 1 = WEKA not installed or no container running, 0 = one is Running, 2 = CLI failed
WEKA_BUSY_CHECK='[ -n "$(command -v weka)" ] || exit 1; s=$(weka local ps --no-header -o name,state) || exit 2; echo "$s" | grep -qw Running'

# ---------- ssh ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
# TL[target]: the target's login (FF_SSH_USER, or its -t row's), keyed by the target so cleanup can use it too
rsh() { local t=$1; shift; ssh -n "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" "$@"; }
# sweep_ssh target cmd...: the call that opens the target's ssh master. A password login (TPW) reads its password here,
# through the askpass helper from a one-use fifo (BatchMode=no first: ssh keeps an option's first value); every later
# call rides the master under BatchMode=yes, so a lost master fails loud instead of prompting
sweep_ssh() {
    local t=$1 rc; shift
    [[ -n ${TPW[$t]+x} ]] || { rsh "$t" "$@"; return; }
    pwfifo "s.$BASHPID" "${TPW[$t]}" || return 255
    THERMCAP_PW_FIFO=$PWFIFO SSH_ASKPASS=$AUTH/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none} \
        $SETSID ssh -n -o BatchMode=no -o NumberOfPasswordPrompts=1 "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" "$@"; rc=$?
    exec 4>&-; rm -f "$PWFIFO" "$PWFIFO.used"; return $rc
}
# The sweep's probe (sh, stdin empty under ssh -n): "uid escalator". Not root: the first passwordless escalator that
# runs `true` within 5 s, in this order; "none" if none does ("-" for root). Every login is probed, a password login
# too: a passwordless escalator wins, and sudo -S with the password is the fallback.
# One line (it travels as an ssh argument, %q-quoted for the remote sh).
PRIV_PROBE='u=$(id -u); e=-; if [ "$u" != 0 ]; then e=none; T=; [ -n "$(command -v timeout)" ] && T="timeout 5"; for c in "dzdo -n" pbrun sesu pmrun "doas -n" "ksu -e" "sudo -n"; do [ -n "$(command -v ${c%% *})" ] || continue; if $T $c true; then e=$c; break; fi; done; fi; echo "$u $(echo "$e" | tr " " _)"'
# sweep_probe target: the sweep's one ssh to the target, the probe its command
sweep_probe() { sweep_ssh "$1" sh -c "$(printf '%q' "$PRIV_PROBE")" ff-probe; }
# TESC[target]: how remote steps get root there: "" (root), the escalator the probe found, or S: sudo -S -k with its -t
# password. The stream to a sudo -S host is "password, SENTINEL, then the script or nothing": sudo takes the first
# line when it asks; when it doesn't (NOPASSWD, or -k not honoured), the guard below reads the password line away
# itself, so no line of the stream is ever run as a command. SENTINEL is a per-run random token, never the password.
# privv target: PRIV, the words that go before the remote command
privv() { case ${TESC[$1]-} in "") PRIV=() ;; S) PRIV=(sudo -S -k -p "''") ;; *) read -ra PRIV <<<"${TESC[$1]}" ;; esac; }
# sudo_guard "<what runs next>": the remote one-liner (%q-quoted for the shell) that skips to the sentinel first
sudo_guard() { printf '%q' "IFS= read -r l; [ \"\$l\" = \"$SENTINEL\" ] || IFS= read -r l; exec $1"; }
# rbash [-T secs] target args...: stdin as a bash script on the target, as root (TESC); -T: cut off after secs
rbash() {
    local -a to=() PRIV; [[ $1 == -T ]] && { to=(timeout "$2"); shift 2; }
    local t=$1; shift; privv "$t"
    if [[ ${TESC[$t]-} == S ]]; then
        [[ -n ${TPW[$t]+x} ]] || return 3   # after a crash: no password to give sudo (never saved); no blank try
        { printf '%s\n%s\n' "${TPW[$t]}" "$SENTINEL"; cat; } | "${to[@]}" ssh "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" \
            "${PRIV[@]}" bash -c "$(sudo_guard 'bash -s -- "$@"')" ff-sudo -- "$@"
    else "${to[@]}" ssh "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" "${PRIV[@]}" bash -s -- "$@"; fi
}
# rroot target cmd...: one command as root (TESC). Returns 3, running nothing, for a sudo -S host whose password isn't
# in memory: the cleanup after a crash works from the state file, which never holds a password
rroot() {
    local t=$1 PRIV; shift; privv "$t"
    if [[ ${TESC[$t]-} != S ]]; then rsh "$t" "${PRIV[@]}" "$@"; return; fi
    [[ -n ${TPW[$t]+x} ]] || return 3
    printf '%s\n%s\n' "${TPW[$t]}" "$SENTINEL" | ssh "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" \
        "${PRIV[@]}" sh -c "$(sudo_guard '"$@"')" ff-sudo "$@"
}

# Discovery: raw facts only, parsed locally.
read -r -d '' DISCOVER_SCRIPT <<'EOF'
echo "=== hostname ==="; hostname -s
echo "=== machine-id ==="; cat /etc/machine-id 2>&1
echo "=== addr ==="; ip -o -4 addr show
echo "=== link ==="; ip -o link show
echo "=== tools ==="
for c in iperf3 ethtool lldpcli ibstat ss timeout; do p=$(command -v $c); echo "$c ${p:--}"; done
echo "=== iperf3 ==="; [ -n "$(command -v iperf3)" ] && iperf3 --version 2>&1 | head -n 1
echo "=== sysctl ==="
for s in rmem_max wmem_max; do echo "$s $(cat /proc/sys/net/core/$s 2>&1)"; done
if [ -n "$BUSY_CHECK" ]; then
    out=$(timeout 20 bash -c "$BUSY_CHECK" 2>&1); rc=$?
    echo "=== busy ==="; echo "rc=$rc"; echo "$out" | head -n 20
fi
EOF

# Per-host diagnostics for the rail NICs ($@, "-" = none)
read -r -d '' DIAG_SCRIPT <<'EOF'
h=$(hostname -s)
have() { [ -n "$(command -v "$1")" ]; }
ctr() { awk -v k="$1:" '$1==k {print $2; f=1; exit} END {if (!f) print "n/a"}'; }
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ip=$(ip -o -4 addr show dev "$nic" 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')
    if have ethtool; then
        eth=$(ethtool "$nic" 2>&1); inf=$(ethtool -i "$nic" 2>&1)
        mod=$(ethtool -m "$nic" 2>&1); st=$(ethtool -S "$nic" 2>&1)
    else
        eth="ethtool not installed"; inf=$eth; mod=$eth; st=$eth
    fi
    speed=$(echo "$eth" | awk '/Speed:/{print $2}')
    set -- $(for k in rx_corrected_bits_phy rx_err_lane_0_phy rx_err_lane_1_phy rx_err_lane_2_phy \
                      rx_err_lane_3_phy link_down_events_phy rx_pcs_symbol_err_phy; do echo "$st" | ctr $k; done)
    # Rx power per channel (dBm) and module temp; vendors word these differently
    rxp=$(echo "$mod" | awk '
        /(Rcvr|Receiver|Rx).*power/ && /dBm/ && !/thresh|alarm|warning/ {
            ch = 1; if (match($0, /Channel [0-9]+/)) ch = substr($0, RSTART + 8, RLENGTH - 8)
            for (i = 2; i <= NF; i++) if ($i == "dBm") v[ch] = $(i-1)
        }
        END { for (c = 1; c <= 4; c++) printf "%s ", (c in v ? v[c] : "n/a") }')
    # passive DACs have no monitoring and report 0.00 C at 0 V: that is n/a, not a reading
    temp=$(echo "$mod" | awk '/Module temperature/ && t == "" {for (i = 1; i <= NF; i++) if ($i == "degrees") {t = $(i-1); break}}
        /Module voltage *:/ && $NF == "V" && $(NF-1) + 0 == 0 {z = 1} END {if (t != "" && !z) print t}')
    echo "@@NIC_DIAG $h $nic ${ip:-none} ${speed:-unknown} $* $rxp${temp:-n/a}"
    f() { echo "$inf" | awk -F': ' -v k="$1" '$1==k {print $2; exit}'; }
    drv=$(f driver); ver=$(f version); ver=${ver// /_}; fw=$(f firmware-version); bus=$(f bus-info)
    # LLDP: one row for the NIC and, when it is a bond, one per member (a bond has no neighbour of its own; a 10-27
    # field run had 215 bond rows "unknown" while the members named their leaves). Member rows carry the bond's IP.
    # FF_SYSFS (default /sys) is a test hook.
    members=""; [ "$drv" = bonding ] && [ -r "${FF_SYSFS:-/sys}/class/net/$nic/bonding/slaves" ] && members=$(cat "${FF_SYSFS:-/sys}/class/net/$nic/bonding/slaves" 2>&1)
    for port in $nic $members; do
        if have lldpcli; then lldp=$(lldpcli show neighbors ports "$port" 2>&1); else lldp=""; fi
        chassis=$(echo "$lldp" | awk -F': *' '/SysName:/{gsub(/ /,"_",$2); print $2; exit}')
        portid=$(echo "$lldp" | awk '/PortID:/{print $NF; exit}')
        portdesc=$(echo "$lldp" | awk -F': *' '/PortDescr:/{gsub(/ /,"_",$2); print $2; exit}')
        sysdesc=$(echo "$lldp" | awk -F': *' '/SysDescr:/{gsub(/ /,"_",$2); print $2; exit}')
        echo "@@LLDP $h $port ${ip:-none} ${chassis:-unknown} ${portid:-unknown} ${portdesc:-unknown} ${sysdesc:-unknown}"
        if [ "$port" = "$nic" ]; then lldp0=$lldp; else echo "=== lldpcli $port ==="; echo "${lldp:-lldpcli not installed}"; fi
    done
    lldp=$lldp0
    echo "@@DRV $h $nic ${ip:-none} ${drv:-unknown} ${ver:-unknown} ${fw:-unknown} ${bus:-unknown}"
    # a bond: its slaves' MII state as "@@BOND host nic up total down_slaves" (none = all up) and the kernel's
    # whole report, so a bond at half speed names the member without link. FF_PROCNET (default /proc/net) is a test hook.
    if [ "$drv" = bonding ] && [ -r "${FF_PROCNET:-/proc/net}/bonding/$nic" ]; then
        bnd=$(cat "${FF_PROCNET:-/proc/net}/bonding/$nic" 2>&1)
        echo "$bnd" | awk -v h="$h" -v n="$nic" '/^Slave Interface:/ { s = $3; t++ }
            /^MII Status:/ && s != "" { if ($3 == "up") u++; else d = d (d == "" ? "" : ",") s; s = "" }
            END { printf "@@BOND %s %s %d %d %s\n", h, n, u + 0, t + 0, (d == "" ? "none" : d) }'
        echo "=== bonding $nic ==="; echo "$bnd"
    fi
    echo "=== ethtool $nic ==="; echo "$eth"
    echo "=== ethtool -i $nic ==="; echo "$inf"
    echo "=== ethtool -m $nic ==="; echo "$mod"
    echo "=== ethtool -S $nic ==="; echo "$st" | grep -E "rx_|tx_|link_down|pcs_symbol|prio|pause" | grep -v "ch[0-9]"
    echo "=== lldpcli $nic ==="; echo "${lldp:-lldpcli not installed}"
done
echo "=== hostname ==="; echo "$h"
echo "=== ip -br -4 a ==="; ip -br -4 a
if have ibstat; then echo "=== ibstat ==="; ibstat 2>&1; fi
EOF

# Drop counters for the rail NICs ($@): "host_nic ip rx_drop tx_drop rx_oob"
read -r -d '' DROPS_SCRIPT <<'EOF'
h=$(hostname -s)
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ip=$(ip -o -4 addr show dev "$nic" 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')
    rx=$(cat /sys/class/net/$nic/statistics/rx_dropped 2>&1); tx=$(cat /sys/class/net/$nic/statistics/tx_dropped 2>&1)
    oob=$(ethtool -S "$nic" 2>&1 | awk '$1=="rx_out_of_buffer:" {print $2; f=1} END {if (!f) print "na"}')
    # carrier drops: vendor-neutral, and counts flaps that mlx5 link_down_events_phy misses on some firmware
    cd=$(cat /sys/class/net/$nic/carrier_down_count 2>&1); case $cd in ''|*[!0-9]*) cd=na ;; esac
    echo "${h}_${nic} ${ip:-none} ${rx:-na} ${tx:-na} ${oob:-na} $cd"
done
EOF

# Per-priority, PFC/pause, ECN/CNP and NIC discard counters for the rail NICs ($@): "host_nic counter value".
# Names differ by driver (mlx5 rx_prio3_pause, ice rx_priority_3_xon.nic, bnxt pfc_*); per-queue/ring lines
# (chN_, rxN_, txN_, _qN, queue) skipped. RoCE ECN/CNP/retransmit counters live only in the RDMA port's sysfs, printed as "rdma:<name>".
# FF_SYSFS (default /sys) is a test hook.
read -r -d '' PRIO_SCRIPT <<'EOF'
h=$(hostname -s); sys=${FF_SYSFS:-/sys}
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ethtool -S "$nic" 2>&1 | awk -v k="${h}_${nic}" '$2 ~ /^[0-9]+$/ && $1 ~ /:$/ {
        n = $1; sub(/:$/, "", n); l = tolower(n)
        if (l ~ /prio|pri[0-9]|pfc|pause|xon|xoff|ecn|cnp|discard|out_of_buffer/ && l !~ /ch[0-9]|_q[0-9]|queue|^[rt]x[0-9]+_/) print k, n, $2 }'
    # the RDMA port whose default GID is on this NIC, or on its only lower device (a VLAN's parent)
    phys=$nic; n=0
    for l in "$sys/class/net/$nic"/lower_*; do [ -e "$l" ] && { phys=${l##*lower_}; n=$((n + 1)); }; done
    [ "$n" -le 1 ] || phys=$nic
    for p in "$sys"/class/infiniband/*/ports/*; do
        [ "$(cat "$p/gid_attrs/ndevs/0" 2>&1)" = "$phys" ] || continue
        for f in "$p"/hw_counters/* "$p"/counters/*; do
            c=${f##*/}
            case $c in *ecn*|*cnp*|*seq*|*nak*|*timeout*|*retrans*|*restart*|*discard*|*err*|*downed*|*out_of_buffer*|\
                       *duplicate*|*exceeded*|*invalid*|*dropped*|*xmit_wait*) ;; *) continue ;; esac
            v=$(cat "$f" 2>&1)
            case $v in ''|*[!0-9]*) ;; *) echo "${h}_${nic} rdma:$c $v" ;; esac
        done
    done
done
EOF

# FEC counters for the rail NICs ($@): "host_nic corrected_blocks uncorrectable_blocks corrected_bits symbol_errors".
# Blocks come from the vendor-neutral ethtool -I --show-fec; corrected bits and symbol errors are mlx5 extras. na = not exposed,
# off = the link runs without FEC (Active FEC encoding Off/None), so there is no pre-FEC BER.
read -r -d '' FEC_SCRIPT <<'EOF'
h=$(hostname -s)
num() { awk -v k="$1" '$1 == k {for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}'; }
for nic in "$@"; do
    [ "$nic" = - ] && continue
    f=$(ethtool -I --show-fec "$nic" 2>&1); s=$(ethtool -S "$nic" 2>&1)
    cb=$(echo "$f" | num corrected_blocks:); ub=$(echo "$f" | num uncorrectable_blocks:)
    bits=$(echo "$s" | num rx_corrected_bits_phy:); sym=$(echo "$s" | num rx_pcs_symbol_err_phy:)
    echo "$f" | grep -q -i -E '^Active FEC encoding: *(off|none)' && { cb=off; ub=off; bits=off; }
    echo "${h}_${nic} ${cb:-na} ${ub:-na} ${bits:-na} ${sym:-na}"
done
EOF

# Mesh: src_a src_b dst... -> "MESHFAIL src dst" for each rail IP pair that does not answer one ping.
# 64 pings at a time; "none" skips a missing rail.
read -r -d '' MESH_SCRIPT <<'EOF'
a=$1 b=$2; shift 2
n=0
for s in $a $b; do
    [ "$s" = none ] && continue
    for d in "$@"; do
        ( out=$(ping -c1 -W1 -I "$s" "$d" 2>&1) || echo "MESHFAIL $s $d" ) &
        n=$(( n + 1 )); [ $(( n % 64 )) = 0 ] && wait
    done
done
wait
EOF

# Run lock per host: take <id> <info> <max_age_s> | touch <id> | release <id>.
# take prints OK, or BUSY <holder> when another run touched the lock within max_age.
read -r -d '' LOCK_SCRIPT <<'EOF'
L=${FF_LOCK_FILE:-/tmp/fabric_ferret.lock}
mine() { [ -f "$L" ] && grep -q "^$1 " "$L"; }
case $1 in
take)
    # atomic create: set -C (noclobber) refuses an existing file, so two runs cannot both win
    if out=$( (set -C; echo "$2 $3" > "$L") 2>&1 ); then echo OK; exit 0; fi
    mine "$2" && { echo OK; exit 0; }
    age=$(( $(date +%s) - $(date -r "$L" +%s) ))
    if [ "$age" -lt "$4" ]; then echo "BUSY $(cut -d" " -f2- "$L") (lock refreshed ${age}s ago)"; exit 0; fi
    # stale lock: replace it whole, then re-read; of two runs doing this, only the last writer keeps it
    echo "$2 $3" > "$L.$$" && mv -f "$L.$$" "$L"; sleep 1
    if mine "$2"; then echo OK; else echo "BUSY $(cut -d" " -f2- "$L") (took over a stale lock first)"; fi ;;
touch) mine "$2" && touch "$L"; echo OK ;;
release) mine "$2" && rm -f "$L"; echo OK ;;
esac
EOF

# Rail gateways: rail_ip nic df_size peer... -> "DIRECT" or "GW <ip> OK|MTU|FAIL" per distinct gateway
# that `ip route get <peer> from <rail_ip>` uses (routed fabrics: /31 or per-rail policy tables).
read -r -d '' GW_SCRIPT <<'EOF'
src=$1 nic=$2 size=$3; shift 3
gws=""
for p in "$@"; do
    g=$(ip -o route get "$p" from "$src" 2>&1 | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i+1); exit}}')
    [ -n "$g" ] && case " $gws " in *" $g "*) ;; *) gws="$gws $g" ;; esac
done
[ -z "$gws" ] && { echo "DIRECT"; exit 0; }
for g in $gws; do
    if out=$(ping -c2 -W1 -M do -s "$size" -I "$src" "$g" 2>&1); then echo "GW $g OK"
    elif out=$(ping -c2 -W1 -I "$src" "$g" 2>&1); then echo "GW $g MTU"
    else echo "GW $g FAIL"; fi
done
EOF

# Path check: src_ip dst_ip src_nic df_size -> OK or a reason
read -r -d '' PATH_SCRIPT <<'EOF'
r=$(ip -o route get "$2" from "$1" 2>&1); r=${r%%$'\n'*}
case " $r " in *" dev $3 "*) ;; *) echo "ROUTE egress is not $3: $r"; exit 0 ;; esac
out=$(ping -c1 -W1 -I "$1" "$2" 2>&1) || { echo "PING no reply"; exit 0; }
out=$(ping -c1 -W2 -M do -s "$4" -I "$1" "$2" 2>&1) || { echo "MTU $(( $4 + 28 ))B no-fragment ping failed"; exit 0; }
echo OK
EOF

# Servers: port count ip... (count servers per IP, on port..port+count-1: a backend NIC that serves
# several client flows at once needs one server each); clears earlier iperf3 first (port clash)
read -r -d '' SERVER_SCRIPT <<'EOF'
port=$1 count=$2; shift 2
pkill -x iperf3
for i in $(seq 20); do [ -z "$(pgrep -x iperf3)" ] && break; sleep 0.5; done
for ip in "$@"; do for j in $(seq 0 $(( count - 1 ))); do iperf3 -s -D -B "$ip" -p $(( port + j )); done; done
EOF

# Client routes: backend_ip... -> "@@CROUTE ip egress_dev" by the kernel's own choice (no source address),
# the path a client's own traffic to that rail takes
read -r -d '' CROUTE_SCRIPT <<'EOF'
for ip in "$@"; do
    d=$(ip -o route get "$ip" 2>&1 | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    echo "@@CROUTE $ip ${d:-none}"
done
EOF

# One iperf3 run: src dst port streams secs [tos] -> "[SUM] ... receiver retransmits:N cpu:S/R" or "ERROR ..."
# cpu: -V's process CPU % on the sender (client) and receiver (server); over 100 with iperf3 3.16+ threads, na if absent.
read -r -d '' IPERF_SCRIPT <<'EOF'
out=$(iperf3 --connect-timeout 5000 -c "$2" -B "$1" -p "$3" -P "$4" -t "$5" -f g -Z -V ${6:+-S $6} 2>&1); rc=$?
retr=$(echo "$out" | awk '/SUM.*sender/{print $(NF-1)}')
rcv=$(echo "$out" | grep -m1 'SUM.*receiver')
cpu=$(echo "$out" | awk '/CPU Utilization/ {for (i = 1; i < NF; i++) {if ($i == "local/sender") s = $(i+1); if ($i == "remote/receiver") r = $(i+1)}}
    END {gsub(/[%,]/, "", s); gsub(/[%,]/, "", r); print (s == "" ? "na" : s) "/" (r == "" ? "na" : r)}')
if [ -n "$rcv" ]; then echo "$rcv retransmits:${retr:-0} cpu:$cpu"
else echo "ERROR rc=$rc $(echo "$out" | grep -i -m1 error | tr -s ' ')"; fi
EOF

# One UDP run, no rate cap: src dst port streams secs len [tos] -> "[SUM] ... receiver" or "ERROR ..."
read -r -d '' UDP_SCRIPT <<'EOF'
out=$(iperf3 --connect-timeout 5000 -u -b 0 -l "$6" -c "$2" -B "$1" -p "$3" -P "$4" -t "$5" -f g ${7:+-S $7} 2>&1); rc=$?
rcv=$(echo "$out" | grep -m1 'SUM.*receiver')
if [ -n "$rcv" ]; then echo "$rcv"
else echo "ERROR rc=$rc $(echo "$out" | grep -i -m1 error | tr -s ' ')"; fi
EOF

# Sender-side packet counts per data NIC: "host_nic ip kernel_tx wire_tx". kernel_tx = packets the kernel handed
# the driver (sysfs, every driver); wire_tx = packets the port sent (mlx5 tx_packets_phy). A bond or VLAN has no
# port: its lower devices' sum, down to 3 levels ("na" if any has no port counter; a VLAN parent's count includes
# its other traffic, which can only hide a shortfall). FF_SYSFS (default /sys) is a test hook.
read -r -d '' TXCTR_SCRIPT <<'EOF'
h=$(hostname -s); sys=${FF_SYSFS:-/sys}
wire() {
    local p l s=0 n=0 d=${2:-0}
    p=$(ethtool -S "$1" 2>&1 | awk '$1=="tx_packets_phy:" {print $2; exit}')
    case $p in ''|*[!0-9]*|0) ;; *) echo "$p"; return ;; esac   # 0: an mlx5 VF has the counter but no port behind it
    [ "$d" -lt 3 ] || { echo na; return; }
    for l in "$sys/class/net/$1"/lower_*; do
        [ -e "$l" ] || continue
        p=$(wire "${l##*lower_}" $(( d + 1 ))); case $p in ''|*[!0-9]*) echo na; return ;; esac
        s=$(( s + p )); n=$(( n + 1 ))
    done
    if [ "$n" -gt 0 ]; then echo "$s"; else echo na; fi
}
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ip=$(ip -o -4 addr show dev "$nic" 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')
    k=$(cat "$sys/class/net/$nic/statistics/tx_packets" 2>&1); case $k in ''|*[!0-9]*) k=na ;; esac
    echo "${h}_${nic} ${ip:-none} $k $(wire "$nic")"
done
EOF

# Temperatures, read only: every hwmon sensor (kernel sysfs; the data lm-sensors reads, no package needed) as
# "@@HWMON host chip dev sensor milli_c high crit" (dev: the NIC's netdev, else the device; thresholds in milli-C
# or -), "@@HWMON host - - none - - -" when there is none. $1 = ipmi adds the BMC's readings (ipmitool sensor,
# timeout $2) as "@@IPMI host sensor c status high crit", or "@@IPMI host none <why>". FF_SYSFS is a test hook.
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
[ "$1" = ipmi ] || exit 0
if [ -z "$(command -v ipmitool)" ]; then echo "@@IPMI $h none ipmitool_not_installed"; exit 0; fi
if [ -n "$(command -v timeout)" ]; then out=$(timeout "${2:-60}" ipmitool sensor 2>&1); else out=$(ipmitool sensor 2>&1); fi; rc=$?
# ipmitool sensor: name | value | units | status | lnr | lc | lnc | unc | uc | unr (unc = high, uc = crit)
r=$(printf '%s\n' "$out" | awk -F'|' -v h="$h" '{for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i)}
    $3 == "degrees C" && $2 ~ /^-?[0-9.]+$/ {nm = $1; gsub(/[^A-Za-z0-9_.:-]/, "_", nm)
        print "@@IPMI", h, nm, $2, ($4 == "" ? "-" : $4), ($8 ~ /^-?[0-9.]+$/ ? $8 : "-"), ($9 ~ /^-?[0-9.]+$/ ? $9 : "-")}')
if [ -n "$r" ]; then echo "$r"
else echo "@@IPMI $h none rc=${rc}_$(printf '%s' "$out" | head -n 1 | tr -c 'A-Za-z0-9_.:=-' '_' | cut -c1-80)"; fi
EOF

# Host-side UDP loss counters: "host InErrors RcvbufErrors SndbufErrors softnet_dropped".
# InErrors includes RcvbufErrors; softnet_stat column 2 (hex) is the per-CPU backlog drop count.
read -r -d '' UDPHOST_SCRIPT <<'EOF'
h=$(hostname -s)
u=$(awk '/^Udp:/ { n++; if (n == 1) split($0, k); else for (i = 2; i <= NF; i++) v[k[i]] = $i }
    END { printf "%d %d %d", v["InErrors"], v["RcvbufErrors"], v["SndbufErrors"] }' /proc/net/snmp)
d=0; while read -r a b rest; do d=$(( d + 16#$b )); done < /proc/net/softnet_stat
echo "$h $u $d"
EOF

# System info, once per tested host: wekatester's set plus the receive path, as "=== SYSINFO <item> ===" sections
# (split locally into sysinfo/<host>/<item>). Rail NICs are $@. A missing tool or file says "n/a: <why>", never a blank.
read -r -d '' SYSINFO_SCRIPT <<'EOF'
have() { [ -n "$(command -v "$1")" ]; }
s() { echo "=== SYSINFO $1 ==="; }
to=""; have timeout && to=timeout   # an item that hangs (a stale mount under df, say) costs its section, not the host
cmd() {   # T=seconds (20)
    if ! have "$1"; then echo "n/a: $1 not installed"; return; fi
    $to ${to:+${T:-20}} "$@" 2>&1; [ $? = 124 ] && echo "n/a: $1 timed out after ${T:-20}s"
}
f() { if [ -r "$1" ]; then cat "$1" 2>&1; else echo "n/a: $1 not readable"; fi; }
s epoch; date +%s
for p in cmdline mounts meminfo softirqs; do s $p; f /proc/$p; done
s isolated; f /sys/devices/system/cpu/isolated
s os-release; f /etc/os-release
s uname; uname -a
s uptime; cmd uptime
s df; cmd df -kP
s ip; ip -o addr 2>&1; ip -o link 2>&1
s ip-rule; ip rule 2>&1
s ip-route-all; ip route show table all 2>&1 | head -n 2000
s lscpu; cmd lscpu
s lspci; cmd lspci
s numactl; cmd numactl --hardware
s free; cmd free
s iperf3; cmd iperf3 --version
s weka; cmd weka local ps
s chrony; if have chronyc; then cmd chronyc tracking; else cmd timedatectl status; fi
s ofed; cmd ofed_info -s
s dmidecode; cmd dmidecode -t bios -t system -t baseboard
s sysctl
for k in net/core/netdev_max_backlog net/core/netdev_budget net/core/rmem_max net/core/wmem_max net/ipv4/tcp_rmem \
         net/ipv4/tcp_wmem net/ipv4/tcp_congestion_control net/ipv4/tcp_ecn; do echo "$k $(cat /proc/sys/$k 2>&1)"; done
for n in all default "$@"; do
    [ "$n" = - ] && continue
    for k in rp_filter arp_ignore arp_announce; do echo "net/ipv4/conf/$n/$k $(cat /proc/sys/net/ipv4/conf/$n/$k 2>&1)"; done
done
s cpu-governor
g=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [ -r $g ]; then cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>&1 | sort | uniq -c
else echo "n/a: no cpufreq governor (the BIOS or a VM controls frequency)"; fi
s irqbalance; if [ -n "$(pgrep -x irqbalance)" ]; then echo running; else echo "not running"; fi
for nic in "$@"; do
    [ "$nic" = - ] && continue
    dev=/sys/class/net/$nic/device; bus=$(basename "$(readlink -f $dev)")
    s "nic-$nic"
    echo "bus $bus"; echo "driver $(basename "$(readlink -f $dev/driver)")"; echo "numa_node $(cat $dev/numa_node 2>&1)"
    for a in current_link_speed current_link_width max_link_speed max_link_width; do echo "$a $(cat $dev/$a 2>&1 | tr ' ' _)"; done
    for a in correctable nonfatal fatal; do
        echo "aer_$a $(awk '$1 ~ /^TOTAL_ERR/ {print $2; f = 1} END {if (!f) print "n/a"}' $dev/aer_dev_$a 2>&1)"
    done
    irqs=$(ls $dev/msi_irqs 2>&1); echo "msi_irqs $(echo "$irqs" | grep -c '^[0-9]')"
    echo "irq_cpus $(for i in $irqs; do cat /proc/irq/$i/smp_affinity_list 2>&1; done | tr '\n' ' ')"
    for o in -g -l -c -a; do echo "--- ethtool $o"; cmd ethtool $o "$nic"; done
    echo "--- modinfo"; d=$(basename "$(readlink -f $dev/driver/module)"); cmd modinfo "$d" | head -n 12
    echo "--- mlnx_qos"; cmd mlnx_qos -i "$nic"
    echo "--- mlxconfig"; if have mlxconfig; then T=60 cmd mlxconfig -d "$bus" q | head -n 400; else echo "n/a: mlxconfig not installed (MFT)"; fi
done
EOF

# Receive-side host counters, read at each TCP phase boundary: "host key value". TCP from /proc/net/snmp and
# netstat, softnet_stat summed over CPUs (hex), NET_RX softirqs, PCIe AER totals per rail NIC ($@).
read -r -d '' HOSTCTR_SCRIPT <<'EOF'
h=$(hostname -s)
awk -v h="$h" -v want='^(RetransSegs|InErrs|TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|TCPOFOQueue|PruneCalled|RcvPruned|OfoPruned|TCPRcvCollapsed|TCPZeroWindowDrop|TCPLostRetransmit|TCPTimeouts|TCPMemoryPressures)$' '
    $1 == "Tcp:" || $1 == "TcpExt:" { if (seen[$1]++ % 2 == 0) { for (i = 2; i <= NF; i++) n[i] = $i }
                                      else for (i = 2; i <= NF; i++) if (n[i] ~ want) print h, n[i], $i }' /proc/net/snmp /proc/net/netstat
p=0; d=0; q=0; while read -r a b c rest; do p=$(( p + 16#$a )); d=$(( d + 16#$b )); q=$(( q + 16#$c )); done < /proc/net/softnet_stat
echo "$h softnet_processed $p"; echo "$h softnet_dropped $d"; echo "$h softnet_squeezed $q"
awk -v h="$h" '$1 == "NET_RX:" {for (i = 2; i <= NF; i++) s += $i; print h, "softirq_net_rx", s}' /proc/softirqs
for nic in "$@"; do
    [ "$nic" = - ] && continue
    for a in correctable nonfatal fatal; do
        v=$(awk '$1 ~ /^TOTAL_ERR/ {print $2}' /sys/class/net/$nic/device/aer_dev_$a 2>&1)
        case $v in ''|*[!0-9]*) ;; *) echo "$h aer_$a:$nic $v" ;; esac
    done
done
EOF

# Kernel log since the run began, by the host's own clock ($1 = its epoch from the sysinfo capture)
read -r -d '' KLOG_SCRIPT <<'EOF'
if [ -n "$(command -v journalctl)" ] && out=$(timeout 60 journalctl -k --no-pager -o short-iso --since "@$1" 2>&1); then echo "$out" | tail -n 3000
else echo "n/a: journalctl -k failed or missing (${out%%$'\n'*}); dmesg instead, last 500 lines of the boot"; dmesg -T 2>&1 | tail -n 500; fi
EOF

# ---------- helpers on discovery files ----------

section() {  # file name -> lines of "=== name ===" section
    awk -v s="=== $2 ===" '$0==s {on=1; next} /^=== .* ===$/ {on=0} on' "$1"
}

# rail_lookup k r: sets RNIC/RIP/RMTU/RSTATE for host k rail r from its discovery file
rail_lookup() {
    local k=$1 r=$2 f=${DISC[$1]} nic="" ip="" n
    if [[ $RAIL_MODE == nic ]]; then
        nic=${RAIL_SPEC[$r]}
        if ! section "$f" link | awk -v n="$nic" '{sub(/:$/,"",$2); sub(/@.*/,"",$2)} $2==n {f=1} END {exit !f}'; then
            RSTATE[$k,$r]="no NIC $nic"; RNIC[$k,$r]=-; RIP[$k,$r]=none; return
        fi
        ip=$(section "$f" addr | awk -v n="$nic" '$2==n {split($4,a,"/"); print a[1]; exit}')
        [[ -n $ip ]] || { RNIC[$k,$r]=$nic; RIP[$k,$r]=none; RSTATE[$k,$r]="no IPv4 on $nic"; return; }
    else
        local -a hits=()
        local c
        while read -r n a; do
            for c in ${RAIL_SPEC[$r]}; do in_cidr "$a" "$c" && { hits+=("$n $a"); break; }; done
        done < <(section "$f" addr | awk '{split($4,a,"/"); print $2, a[1]}')
        if (( ${#hits[@]} == 0 )); then
            RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="no address in ${RAIL_SPEC[$r]// /,}"; return
        fi
        nic=${hits[0]% *}; ip=${hits[0]#* }
        for n in "${hits[@]}"; do
            [[ ${n% *} == "$nic" ]] || { RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="AMBIGUOUS: ${#hits[@]} NICs in ${RAIL_SPEC[$r]// /,}"; return; }
        done
    fi
    RNIC[$k,$r]=$nic; RIP[$k,$r]=$ip
    local line; line=$(section "$f" link | awk -v n="$nic" '{x=$2; sub(/:$/,"",x); sub(/@.*/,"",x)} x==n {print; exit}')
    RMTU[$k,$r]=$(awk '{for (i = 1; i < NF; i++) if ($i == "mtu") print $(i+1)}' <<<"$line")
    if [[ $line != *LOWER_UP* ]]; then RSTATE[$k,$r]="link DOWN on $nic"
    else RSTATE[$k,$r]=ok; fi
}

rail_ok() { [[ ${RSTATE[$1,$2]} == ok ]]; }

# client_lookup k: client k's data NICs (CN, CNIC/CIP/CMTU/CSTATE by j) per FF_CLIENT_NETS or FF_CLIENT_NICS
client_lookup() {
    local k=$1 f=${DISC[$1]} n a c j=0 line
    local -A got=()
    while read -r n a; do
        [[ $n == lo || -n ${got[$n]} ]] && continue
        if [[ $CLIENT_MODE == nics ]]; then [[ " ${CLIENT_SPEC[*]} " == *" $n "* ]] || continue
        else local hit=; for c in "${CLIENT_SPEC[@]}"; do in_cidr "$a" "$c" && { hit=1; break; }; done; [[ -n $hit ]] || continue; fi
        got[$n]=1; CNIC[$k,$j]=$n; CIP[$k,$j]=$a
        line=$(section "$f" link | awk -v n="$n" '{x=$2; sub(/:$/,"",x); sub(/@.*/,"",x)} x==n {print; exit}')
        CMTU[$k,$j]=$(awk '{for (i = 1; i < NF; i++) if ($i == "mtu") print $(i+1)}' <<<"$line")
        if [[ $line != *LOWER_UP* ]]; then CSTATE[$k,$j]="link DOWN on $n"; else CSTATE[$k,$j]=ok; fi
        j=$(( j + 1 ))
    done < <(section "$f" addr | awk '{split($4,a,"/"); print $2, a[1]}')
    if [[ $CLIENT_MODE == nics ]]; then   # a named NIC with no IPv4 is a finding, not silence
        for c in "${CLIENT_SPEC[@]}"; do
            [[ -n ${got[$c]} ]] && continue
            section "$f" link | awk -v n="$c" '{sub(/:$/,"",$2); sub(/@.*/,"",$2)} $2==n {f=1} END {exit !f}' || continue
            CNIC[$k,$j]=$c; CIP[$k,$j]=none; CSTATE[$k,$j]="no IPv4 on $c"; j=$(( j + 1 ))
        done
    fi
    CN[$k]=$j
}
cl_ok() { [[ ${CSTATE[$1,$2]} == ok ]]; }

# list_subnets k...: the IPv4 subnets on hosts k (hosts, NIC, subnet); where two NICs on a host share
# a subnet, the mask can't tell them apart, so also each NIC's addresses by /24 and the FF_NICS hint
list_subnets() {
    local k
    for k in "$@"; do
        section "${DISC[$k]}" addr | awk '$2!="lo" {print $2, $4}' | while read -r n a; do
            local b; b=$(cidr_bounds "$a") && echo "$n $(int2ip ${b% *})/${a#*/}"
        done
    done | sort | uniq -c | sort -rn | sed 's/^/#   /' >&2
    local shared; shared=$(for k in "$@"; do
        section "${DISC[$k]}" addr | awk '$2!="lo" {print $2, $4}' | while read -r n a; do
            local b; b=$(cidr_bounds "$a") && echo "$k $n $(int2ip ${b% *})/${a#*/} ${a%/*}"
        done | awk '{h[$3] = h[$3] " " $2; c[$3]++; ip[$2] = $4} END {for (s in c) if (c[s] > 1) {n = split(h[s], x, " "); for (i = 1; i <= n; i++) {split(ip[x[i]], o, "."); print x[i], o[1] "." o[2] "." o[3] ".0/24"}}}'
    done)
    [[ -n $shared ]] || return 0
    log "Some hosts have several NICs in one subnet, so the subnet can't tell their rails apart. Those NICs' addresses by /24 (hosts, NIC, /24):"
    sort <<<"$shared" | uniq -c | sort -k2,2 -k1,1rn | sed 's/^/#   /' >&2
    log "Name the rails by NIC (FF_NICS=$(awk '{print $1}' <<<"$shared" | sort -u | paste -sd, -)) or by narrower subnets, ';' between rails"
}

# Swapped rails by NIC name (subnet mode): a host whose rail-A NIC is the name most hosts
# use for rail B, and the reverse, has its IPs or cables swapped.
rail_consistency() {
    [[ $RAIL_MODE == cidr ]] && (( NR >= 2 )) || return 0
    local maj k r n=0
    maj=$(for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do [[ ${RNIC[$k,$r]} != - ]] && echo "$r ${RNIC[$k,$r]}"; done; done |
        awk -v nr=$NR '{c[$1 " " $2]++} END {for (x in c) {split(x, p, " "); if (c[x] > b[p[1]]) {b[p[1]] = c[x]; m[p[1]] = p[2]}}
                            for (r = 0; r < nr; r++) printf "%s ", (r in m) ? m[r] : "-"}')
    if (( NR > 2 )); then   # a rail NIC that is the name most hosts use for another rail
        local -a M=($maj); local s
        for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
            [[ ${RNIC[$k,$r]} != - && ${RNIC[$k,$r]} != "${M[r]}" ]] || continue
            for s in "${RAILS[@]}"; do
                [[ $s != "$r" && ${RNIC[$k,$r]} == "${M[s]}" ]] || continue
                echo "${T_HOST[$k]} rail_nic_overlap rail $(rail_letter $r) on ${RNIC[$k,$r]}, the NIC most hosts use for rail $(rail_letter $s) (most use ${M[r]} for rail $(rail_letter $r))" >> "$COLLECT_DIR/rail_anomalies.txt"
                n=$(( n + 1 ))
            done
        done; done
        (( n )) && { log "WARNING: $n rail NICs are the NIC most hosts use for another rail:"; grep ' rail_nic_overlap ' "$COLLECT_DIR/rail_anomalies.txt" | sed 's/^/#   /' | head -n 10 >&2; }
        return 0
    fi
    local ma=${maj%% *} mb; mb=${maj#* }; mb=${mb%% *}
    [[ $ma != - && $mb != - && $ma != "$mb" ]] || return 0
    for k in "${ELIG[@]}"; do
        if [[ ${RNIC[$k,0]} == "$mb" && ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} swapped_nics rail A is on $mb and rail B on $ma, the reverse of most hosts (A=$ma, B=$mb): IPs or cables swapped" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        elif [[ ${RNIC[$k,0]} == "$mb" || ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} rail_nic_overlap rail A on ${RNIC[$k,0]}, rail B on ${RNIC[$k,1]}; most hosts use A=$ma, B=$mb" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        fi
    done
    (( n )) && { log "WARNING: $n hosts have rail NICs the other way round from most hosts:"; grep -E ' swapped_nics | rail_nic_overlap ' "$COLLECT_DIR/rail_anomalies.txt" | sed 's/^/#   /' | head -n 10 >&2; }
    return 0
}

# "mtu host" lines -> where they differ: "most at M; N on h1 h2;" (nothing when they agree)
mtu_odd() {
    awk '{if (!($1 in n)) d++; n[$1]++; h[$1] = h[$1] " " $2} END {if (d < 2) exit; for (m in n) if (n[m] > b) {b = n[m]; mm = m}
         t = 0; for (m in n) if (n[m] == b) t++
         if (t > 1) {printf "no majority:"; for (m in n) printf " %s on%s;", m, h[m]}
         else {printf "most at %s;", mm; for (m in n) if (m != mm) printf " %s on%s;", m, h[m]}}'
}

# Client routes: each client asks its kernel for the route to one backend IP per rail and backend subnet;
# a route that leaves by a NIC that isn't a declared data NIC is flagged (client_routes.txt, rail_anomalies.txt)
client_routes() {
    local k j r ip
    local -A pick=() rl=()
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        rail_ok $k $r || continue
        local pfx; pfx=$(section "${DISC[$k]}" addr | awk -v ip="${RIP[$k,$r]}" '{split($4, a, "/"); if (a[1] == ip) {print a[2]; exit}}')
        local b; b=$(cidr_bounds "${RIP[$k,$r]}/${pfx:-32}") || continue
        [[ -n ${pick[$r,${b% *}]} ]] || { pick[$r,${b% *}]=${RIP[$k,$r]}; rl[${RIP[$k,$r]}]=$(rail_letter $r); }
    done; done
    local -a ips=("${pick[@]}")
    : > "$COLLECT_DIR/client_routes.txt"
    (( ${#ips[@]} )) || return 0
    for k in "${CLI[@]}"; do
        throttle
        ( rbash "${T_TARGET[$k]}" "${ips[@]}" <<<"$CROUTE_SCRIPT" > "$WORK/croute.$k" 2>&1 ) &
    done
    wait
    for k in "${CLI[@]}"; do
        local decl=" "; for (( j = 0; j < CN[$k]; j++ )); do decl+="${CNIC[$k,$j]} "; done
        awk -v h="${T_HOST[$k]}" -v decl="$decl" -v rl="$(for ip in "${!rl[@]}"; do printf '%s=%s ' "$ip" "${rl[$ip]}"; done)" '
            BEGIN { n = split(rl, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); R[kv[1]] = kv[2] } }
            $1 == "@@CROUTE" { d = $3; dc = index(decl, " " d " "); print h, (dc ? d : "-"), R[$2], $2, d, (dc ? "declared" : "undeclared"); seen = 1 }
            END { if (!seen) print h, "-", "-", "-", "none", "unread" }' "$WORK/croute.$k"
    done | sort -V > "$WORK/croutes"
    cat "$WORK/croutes" > "$COLLECT_DIR/client_routes.txt"
    local bad; bad=$(awk '$6 == "undeclared"' "$WORK/croutes")
    local unread; unread=$(awk '$6 == "unread" {print $1}' "$WORK/croutes" | paste -sd' ' -)
    if [[ -n $unread ]]; then   # no answer is not a clean route: flag it like a bad one
        log "WARNING: client routes not read on: $unread"
        for k in $unread; do echo "$k client_route_unread no route answer from this client (ssh or ip route failed); its routes are unknown"; done >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
    if [[ -n $bad ]]; then
        awk '{r[$1] = r[$1] sprintf("%srail %s (%s) by %s", (r[$1] == "" ? "" : "; "), $3, $4, $5)} END {for (h in r) print h, "client_route_undeclared route to", r[h], "- not a declared data NIC"}' <<<"$bad" |
            sort -V >> "$COLLECT_DIR/rail_anomalies.txt"
        log "WARNING: $(awk '{print $1}' <<<"$bad" | sort -u | wc -l | tr -d ' ') clients route to a backend rail by a NIC that isn't a declared data NIC (client_routes.txt):"
        echo "$bad" | head -n 10 | column -t | sed 's/^/#   /' >&2
    else
        log "Client routes: every client reaches every backend rail by a declared data NIC ($(wc -l < "$WORK/croutes" | tr -d ' ') routes read)"
    fi
}

# Each usable rail's gateway(s) must answer a full-MTU no-fragment ping (routed rails only).
gateway_check() {
    local k r j
    : > "$COLLECT_DIR/gateways.txt"
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        rail_ok $k $r || continue
        local -a peers=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] && rail_ok $j $r && peers+=("${RIP[$j,$r]}"); done
        (( ${#peers[@]} )) || continue
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" "${RIP[$k,$r]}" "${RNIC[$k,$r]}" $(( ${RMTU[$k,$r]:-1500} - 28 )) "${peers[@]}" <<<"$GW_SCRIPT" 2>&1)
          while read -r line; do [[ -n $line ]] && echo "${T_HOST[$k]} $(rail_letter $r) ${RIP[$k,$r]} $line"; done <<<"${out:-SSH no output}" > "$WORK/gw.$k.$r" ) &
    done; done
    wait
    cat "$WORK"/gw.* 2>&1 | grep -v 'No such file' | sort -V > "$COLLECT_DIR/gateways.txt"
    local direct ok bad
    direct=$(grep -c ' DIRECT$' "$COLLECT_DIR/gateways.txt"); ok=$(grep -c ' OK$' "$COLLECT_DIR/gateways.txt")
    bad=$(grep -v -E ' (DIRECT|OK)$' "$COLLECT_DIR/gateways.txt")
    log "Rail gateways: $ok answered a full-MTU no-fragment ping, $direct rails have no gateway (peers on-link)"
    if [[ -n $bad ]]; then
        log "WARNING: rail gateways that failed (MTU = answers only small pings):"; echo "$bad" | sed 's/^/#   /' >&2
        echo "$bad" | awk '{print $1, "gateway_" $NF, "rail", $2, $3, "gateway", $5}' >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}

# Run lock: take on every tested host before load; another live run (its lock refreshed within
# about two iterations) stops this one, since each run kills stray iperf3 servers on its hosts.
take_locks() {
    local k busy other
    RUN_ID="$(hostname -s)-$$-$START_TS"
    cross_waves $(( ${#ELIG[@]} / 2 ))   # phase 2 waves stretch an iteration
    local max=$(( 2 * ((1 + XW) * FF_DURATION + (FF_UDP == 1 ? (1 + XW) * FF_UDP_DURATION : 0)) + 300 ))
    local info="since=$(date -u +%Y-%m-%dT%H:%M:%SZ),from=$(hostname -s),user=$(id -un)"   # no spaces: args are re-split remotely
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" take "$RUN_ID" "$info" "$max" <<<"$LOCK_SCRIPT" 2>&1)
          echo "${T_HOST[$k]} ${out%%$'\n'*}" > "$WORK/lock.$k" ) &
    done
    wait
    LOCKED=1   # release whatever we took, even if we stop below
    save_state
    busy=$(cat "$WORK"/lock.* | grep ' BUSY ')
    other=$(cat "$WORK"/lock.* | grep -v -E ' (OK|BUSY .*)$')
    [[ -n $other ]] && { log "WARNING: could not take the run lock on:"; echo "$other" | sed 's/^/#   /' >&2; }
    [[ -n $busy ]] || return 0
    if [[ $FF_IGNORE_LOCK == 1 ]]; then
        log "WARNING: FF_IGNORE_LOCK=1: running although another run holds:"; echo "$busy" | sed 's/^/#   /' >&2
    else
        die "another fabric_ferret run is active on $(echo "$busy" | wc -l | tr -d ' ') hosts (it would lose its iperf3 servers to this one): $(echo "$busy" | head -n 3 | tr '\n' ';') wait for it, or set FF_IGNORE_LOCK=1 if it is dead"
    fi
}

lock_all() {  # touch | release on every tested host and client (only our own lock is changed)
    local k
    for k in "${ELIG[@]}" "${CLI[@]}"; do rbash "${T_TARGET[$k]}" "$1" "$RUN_ID" <<<"$LOCK_SCRIPT" >> "$WORK/lock.log" 2>&1 & done
    wait
}

# FF_MESH=1: every usable rail IP of each tested host pings every other tested host's usable rail IPs,
# and every usable client data NIC IP pings every backend rail IP.
mesh_check() {
    local k j r total=0 a b
    local -A host_of=()
    for j in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do rail_ok $j $r && host_of[${RIP[$j,$r]}]=${T_HOST[$j]}; done; done
    log "Mesh: every rail IP pings the ${#host_of[@]} rail IPs of the other tested hosts..."
    for k in "${ELIG[@]}"; do
        local -a dst=() src=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] || continue; for r in "${RAILS[@]}"; do rail_ok $j $r && dst+=("${RIP[$j,$r]}"); done; done
        for r in "${RAILS[@]}"; do rail_ok $k $r && src+=("${RIP[$k,$r]}"); done
        (( ${#src[@]} )) || continue
        total=$(( total + ${#src[@]} * ${#dst[@]} ))
        # the script takes two sources ("none" = no such rail): one call per two rails
        local q
        for (( q = 0; q < ${#src[@]}; q += 2 )); do
            a=${src[q]}; b=${src[q+1]:-none}
            throttle
            ( rbash "${T_TARGET[$k]}" "$a" "$b" "${dst[@]}" <<<"$MESH_SCRIPT" > "$WORK/mesh.$k.$q" 2>&1 ) &
        done
    done
    # clients: every usable client data NIC pings every backend rail IP (clients never ping each other)
    local ctotal=0; local -A chost_of=(); local -a bdst=("${!host_of[@]}")
    for k in "${CLI[@]}"; do
        local -a src=()
        for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j && { src+=("${CIP[$k,$j]}"); chost_of[${CIP[$k,$j]}]=${T_HOST[$k]}; }; done
        (( ${#src[@]} && ${#bdst[@]} )) || continue
        ctotal=$(( ctotal + ${#src[@]} * ${#bdst[@]} ))
        for (( q = 0; q < ${#src[@]}; q += 2 )); do
            a=${src[q]}; b=${src[q+1]:-none}
            throttle
            ( rbash "${T_TARGET[$k]}" "$a" "$b" "${bdst[@]}" <<<"$MESH_SCRIPT" > "$WORK/cmesh.$k.$q" 2>&1 ) &
        done
    done
    (( ${#CLI[@]} )) && log "Mesh: and the ${#chost_of[@]} client data NIC IPs ping every backend rail IP..."
    wait
    cat "$WORK"/mesh.* 2>&1 | awk '$1 == "MESHFAIL" {print $2, $3}' | while read -r s d; do
        echo "${host_of[$s]:-?} $s ${host_of[$d]:-?} $d"
    done | sort -V > "$WORK/mesh_b"
    : > "$WORK/mesh_c"
    if (( ${#CLI[@]} )); then
        cat "$WORK"/cmesh.* 2>&1 | awk '$1 == "MESHFAIL" {print $2, $3}' | while read -r s d; do
            echo "${chost_of[$s]:-?} $s ${host_of[$d]:-?} $d client"
        done | sort -V > "$WORK/mesh_c"
    fi
    cat "$WORK/mesh_b" "$WORK/mesh_c" > "$COLLECT_DIR/mesh_failures.txt"
    local fails cfails; fails=$(wc -l < "$COLLECT_DIR/mesh_failures.txt" | tr -d ' '); cfails=$(wc -l < "$WORK/mesh_c" | tr -d ' ')
    total=$(( total + ctotal ))
    log "Mesh: $total pings, $fails failed$( (( ${#CLI[@]} )) && echo " (from clients: $cfails of $ctotal)")"
    MESH_PINGS=$total; MESH_FAILS=$fails; MESH_CPINGS=$ctotal; MESH_CFAILS=$cfails
    (( fails )) || return 0
    : > "$WORK/mesh_anom"
    if (( cfails )); then
        # A client IP failing to every backend rail IP gets no replies at all; otherwise a backend rail IP
        # failing from many client IPs points at that rail as clients reach it
        local ip; for ip in "${!chost_of[@]}"; do echo "$ip ${chost_of[$ip]}"; done > "$WORK/cmeship"
        awk -v nb=${#bdst[@]} 'FNR == 1 {f++}
             f == 1 {hof[$1] = $2; nc++; next}
             {m++; s[m] = $2; d[m] = $4; dh[$4] = $3; fs[$2]++}
             END {
                 for (x in fs) if (fs[x] >= nb) {dead[x] = 1; nd++}
                 for (x in dead) printf "%s mesh_client_no_replies client IP %s got no reply from any of the %d backend rail IPs (inbound ICMP blocked, or no route to the rails)\n", hof[x], x, nb
                 for (i = 1; i <= m; i++) if (!(s[i] in dead)) n[d[i]]++
                 for (x in n) printf "%s mesh_client_unreachable rail IP %s did not answer %d of %d client IPs\n", dh[x], x, n[x], nc - nd
             }' "$WORK/cmeship" "$WORK/mesh_c" | sort -k2,2 -k7,7rn > "$WORK/mesh_anom"
    fi
    if [[ -s $WORK/mesh_b ]]; then
        local ip; for ip in "${!host_of[@]}"; do echo "$ip ${host_of[$ip]}"; done > "$WORK/meship"   # backends only
        # A source whose pings fail to every peer gets no replies at all (its inbound ICMP or rail is
        # blocked): report it once as the source and keep its failures out of the destination counts.
        # Otherwise a destination failing from many sources points at that rail.
        # Peers of an IP = every rail IP except its own host's; sources of a destination likewise,
        # minus the silent sources on other hosts.
        awk 'FNR == 1 {f++}
             f == 1 {hof[$1] = $2; c[$2]++; all++; next}
             {m++; s[m] = $2; d[m] = $4; fs[$2]++}
             END {
                 for (x in fs) if (fs[x] >= all - c[hof[x]]) {dead[x] = 1; nd++; deadon[hof[x]]++}
                 for (x in dead) printf "%s mesh_no_replies rail IP %s got no reply from any of its %d peers (inbound ICMP blocked or rail down on that host)\n", hof[x], x, all - c[hof[x]]
                 for (i = 1; i <= m; i++) if (!(s[i] in dead)) n[d[i]]++
                 for (x in n) printf "%s mesh_unreachable rail IP %s did not answer %d of %d pinging rail IPs\n", hof[x], x, n[x], all - c[hof[x]] - (nd - deadon[hof[x]])
             }' "$WORK/meship" "$WORK/mesh_b" | sort -k2,2 -k7,7rn > "$WORK/mesh_banom"
        cat "$WORK/mesh_banom" "$WORK/mesh_anom" > "$WORK/mesh_all"; mv "$WORK/mesh_all" "$WORK/mesh_anom"
    fi
    cat "$WORK/mesh_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    log "WARNING: mesh findings (silent sources first, then destinations, worst first):"
    sed 's/^/#   /' "$WORK/mesh_anom" | head -n 10 >&2
}

# LLDP: a rail NIC whose switch most hosts reach on the other rail is cabled to the wrong rail. A bond's
# member rows carry the bond's IP, so the map also names it: a member is checked against its bond's rail.
lldp_rail_check() {
    local railmap=$WORK/railmap k r
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r) ${RIP[$k,$r]}"
    done; done > "$railmap"
    # compared with the rail most NICs on that switch use (with two rails: the other one)
    awk 'FNR == 1 {f++}
         f == 1 {rail[$1 " " $2] = $3; rails[$3] = 1; if ($4 != "" && $4 != "none") byip[$1 " " $4] = $3; next}
         # a row'\''s rail: by host and NIC, else by host and IP (a bond member'\''s row carries the bond'\''s IP)
         $4 != "unknown" {r = ""; if (($1 " " $2) in rail) r = rail[$1 " " $2]; else if (($1 " " $3) in byip) r = byip[$1 " " $3]
                          if (r != "") {n++; h[n] = $1; nic[n] = $2; sw[n] = $4; rl[n] = r; c[$4 " " r]++}}
         END {for (i = 1; i <= n; i++) {o = ""; for (r in rails) if (r != rl[i] && (o == "" || c[sw[i] " " r] > c[sw[i] " " o])) o = r
                  if (o != "" && c[sw[i] " " o] > c[sw[i] " " rl[i]])
                      printf "%s lldp_wrong_rail rail %s NIC %s is cabled to %s, which %d other NICs reach on rail %s\n", h[i], rl[i], nic[i], sw[i], c[sw[i] " " o], o}}' \
        "$railmap" "$1" > "$WORK/lldp_anom"
    if [[ -s $WORK/lldp_anom ]]; then
        log "WARNING: $(wc -l < "$WORK/lldp_anom" | tr -d ' ') rail NICs are cabled to a switch that serves the other rail (LLDP):"
        sed 's/^/#   /' "$WORK/lldp_anom" | head -n 10 >&2
        cat "$WORK/lldp_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}

# rail_has k r: host k holds rail r (a NIC with an address on it; it may still be DOWN, which is a per-path skip)
rail_has() { case ${RSTATE[$1,$2]} in "no NIC "*|"no IPv4 on "*|"no address in "*) return 1 ;; esac; return 0; }

# rail_groups: the eligible hosts (ORDER) grouped by the rails they hold (HR[k], rail indices), in ORDER's
# order. A rail set held by one host joins the largest group whose rails include it (its pairs plan only the
# rails it holds: JOINED notes "host: rail B not addressed, tested on A only"); a lone host no group contains
# has no partner. Per group g: GKEYS[g] its rail letters, GN[g] hosts, GROT[g] its round-robin circle (a bye
# "-" when odd, none for a lone host), GRAILS[g] rail indices, GROUNDS[g] rounds to meet every pair,
# GPER[g] pairs per iteration, GUPAIRS[g] rail pairs for phase 2 ("0 1;0 2;1 2"), GNUP[g] their count
# (1 with no cross phase), GPPP[g] paths per pair per iteration (a pair with a joined host has fewer).
rail_groups() {
    local k r key g h best
    local -A gi=()
    local -a keys=() n=() rot=() rails=()
    HR=(); JOINED=""
    for k in "${ORDER[@]}"; do
        key=""; HR[$k]=""; for r in "${RAILS[@]}"; do rail_has $k $r && { key+=$(rail_letter $r); HR[$k]+="${HR[$k]:+ }$r"; }; done
        [[ -n $key ]] || key=none
        if [[ -z ${gi[$key]} ]]; then gi[$key]=${#keys[@]}; keys+=("$key"); n+=(0); rot+=(""); rails+=("${HR[$k]}"); fi
        g=${gi[$key]}; n[g]=$(( n[g] + 1 )); rot[g]+="${rot[g]:+ }$k"
    done
    for (( g = 0; g < ${#keys[@]}; g++ )); do
        (( n[g] == 1 )) || continue
        best=-1
        for (( h = 0; h < ${#keys[@]}; h++ )); do
            (( h != g && n[h] > 0 )) || continue
            local ok=1; for r in ${rails[g]}; do [[ " ${rails[h]} " == *" $r "* ]] || ok=0; done
            (( ok )) && { (( best < 0 || n[h] > n[best] )) && best=$h; }
        done
        (( best >= 0 )) || continue
        k=${rot[g]}; local lack="" held=""
        for r in ${rails[best]}; do [[ " ${rails[g]} " == *" $r "* ]] && held+=$(rail_letter $r) || lack+="${lack:+,}$(rail_letter $r)"; done
        JOINED+="${JOINED:+; }${T_HOST[$k]}: rail $lack not addressed, tested on $held only"
        rot[best]+=" $k"; n[best]=$(( n[best] + 1 )); n[g]=0
    done
    GKEYS=(); GN=(); GROT=(); GRAILS=(); GROUNDS=(); GPER=(); GUPAIRS=(); GNUP=(); GPPP=(); GDPER=()
    for (( h = 0; h < ${#keys[@]}; h++ )); do
        (( n[h] > 0 )) || continue
        g=${#GKEYS[@]}; GKEYS+=("${keys[h]}"); GN+=("${n[h]}"); GROT+=("${rot[h]}"); GRAILS+=("${rails[h]}")
        local nn=${GN[g]} nr=0 up="" ua ub m
        (( nn > 1 && nn % 2 )) && GROT[g]+=" -"
        m=$(( nn > 1 ? nn + nn % 2 : 1 ))
        GROUNDS[g]=$(( m > 1 ? m - 1 : 0 )); GPER[g]=$(( nn / 2 ))
        for r in ${GRAILS[g]}; do nr=$(( nr + 1 )); done
        if [[ $CROSS == on ]] && (( nr > 1 )); then
            for ua in ${GRAILS[g]}; do for ub in ${GRAILS[g]}; do (( ub > ua )) && up+="${up:+;}$ua $ub"; done; done
            GUPAIRS[g]=$up; GNUP[g]=$(( (nr * (nr - 1)) / 2 )); GPPP[g]=$(( nr + 2 )); GDPER[g]=$(( nr * nr ))
        else GUPAIRS[g]=""; GNUP[g]=1; GPPP[g]=$nr; GDPER[g]=$nr; fi
    done
}

# pair_rails a b: the rails both hosts hold, in PRL (indices) and PRN (their count)
pair_rails() {
    local r; PRL=""; PRN=0
    for r in ${HR[$1]}; do [[ " ${HR[$2]} " == *" $r "* ]] && { PRL+="${PRL:+ }$r"; PRN=$(( PRN + 1 )); }; done
}

# round_pairs t: iteration t (from 0) of every rail group's circle method over GROT[g] (even length, "-" =
# bye). Slot 0 stays put and the rest rotate one place per round, so no pair repeats until every pair has
# met (GROUNDS[g] rounds); the next cycle repeats the pairings with client and server swapped, and each
# further pair of cycles takes the group's next rail pair for phase 2. Sets, per pair p: PC/PS (client/
# server), PI (pair slot), PR (the round), PG (group), PRAILS (the rails both hosts hold), PXA/PXB (phase 2
# rail pair when both hold it, else empty), PPATHS (its paths this iteration); SITOUT the hosts (one per odd
# group) that sit this iteration out; GXA/GXB per group for the log.
round_pairs() {
    local t=$1 g m i a b rr cyc
    PC=(); PS=(); PI=(); PR=(); PG=(); PRAILS=(); PPATHS=(); PXA=(); PXB=(); GXA=(); GXB=(); SITOUT=""; XA=; XB=
    for (( g = 0; g < ${#GKEYS[@]}; g++ )); do
        local -a rot=(${GROT[g]}) up=()
        m=${#rot[@]}; (( m > 1 )) || continue
        rr=$(( t % (m - 1) )); cyc=$(( t / (m - 1) ))
        local xa="" xb=""
        if [[ -n ${GUPAIRS[g]} ]]; then
            IFS=';' read -r -a up <<<"${GUPAIRS[g]}"
            read -r xa xb <<<"${up[$(( cyc / 2 % ${#up[@]} ))]}"
            [[ -n $XA ]] || { XA=$xa; XB=$xb; }
        fi
        GXA[g]=$xa; GXB[g]=$xb
        local -a arr=("${rot[0]}")
        for (( i = 0; i < m - 1; i++ )); do arr+=("${rot[1 + (i + rr) % (m - 1)]}"); done
        for (( i = 0; i < m / 2; i++ )); do
            a=${arr[i]}; b=${arr[m - 1 - i]}
            (( cyc % 2 )) && { local tmp=$a; a=$b; b=$tmp; }
            if [[ $a == - ]]; then SITOUT+=" $b"
            elif [[ $b == - ]]; then SITOUT+=" $a"
            else
                pair_rails $a $b
                local pxa=$xa pxb=$xb
                [[ -n $xa && " $PRL " == *" $xa "* && " $PRL " == *" $xb "* ]] || { pxa=""; pxb=""; }
                PC+=("$a"); PS+=("$b"); PI+=("$i"); PR+=("$rr"); PG+=("$g"); PRAILS+=("$PRL"); PXA+=("$pxa"); PXB+=("$pxb")
                local np=$PRN; [[ -n $pxa ]] && np=$(( np + 2 )); PPATHS+=("$np")
            fi
        done
    done
}

# xpaths p: pair p's two phase 2 runs, one each way across its group's rail pair (PXA, PXB), in X1/X2
# (src_k src_r dst_k dst_r). Odd: client A <-> server B; even: client B <-> server A. A rotating host moves
# one slot per round, so slot parity swaps its NIC each iteration; slot 0 (the fixed host) swaps by round.
xpaths() {
    local c=${PC[$1]} s=${PS[$1]} i=${PI[$1]} a=${PXA[$1]:-0} b=${PXB[$1]:-1}
    if (( i ? i % 2 : (PR[$1] + 1) % 2 )); then X1=($c $a $s $b); X2=($s $b $c $a); else X1=($c $b $s $a); X2=($s $a $c $b); fi
}

# cross_waves npairs: XW = phase 2 waves under FF_CROSS_MAX (1 when unset). A pair's two flows (one each
# way) stay in one wave, so every wave is balanced A->B / B->A; a cap of 1 runs the flows one at a time.
cross_waves() {
    local np=$1 cap=${FF_CROSS_MAX:-0}
    if (( cap == 0 || 2 * np <= cap )); then XW=1
    elif (( cap == 1 )); then XW=$(( 2 * np ))
    else XW=$(( (np + cap / 2 - 1) / (cap / 2) )); fi
}

# xwaves results [udp]: the current pairs' cross-rail runs in XW waves (pair p in wave p % XW). TCP results
# get a "wave:w/W" marker per wave, so totals only add up flows that ran at the same time.
xwaves() {
    local res=$1 mode=$2 w p q all=$PHASE_OUT
    local -a xp=()   # the pairs with a phase 2 (a one-rail group's pairs have none)
    for (( p = 0; p < ${#PC[@]}; p++ )); do [[ -n ${PXA[p]} ]] && xp+=("$p"); done
    cross_waves ${#xp[@]}
    (( XW > 1 && ITER == 1 )) && log "  $(( 2 * ${#xp[@]} )) cross-rail flows in $XW waves of at most $FF_CROSS_MAX (FF_CROSS_MAX), $( (( FF_CROSS_MAX == 1 )) && echo "one flow at a time" || echo "each wave A->B and B->A balanced")"
    for (( w = 0; w < XW; w++ )); do
        PHASE_OUT=$all.w$w; : > "$PHASE_OUT"
        [[ $mode == udp ]] || echo "### iteration:${ITER} phase:${PHASE}$( (( XW > 1 )) && echo " wave:$(( w + 1 ))/$XW")" >> "$res"
        for (( q = 0; q < ${#xp[@]}; q++ )); do
            p=${xp[q]}; xpaths $p
            if (( ${FF_CROSS_MAX:-0} == 1 && XW > 1 )); then   # cap 1: wave 2q runs X1, 2q+1 runs X2
                (( q == w / 2 )) || continue
                if (( w % 2 )); then run_path p2b_$p "${X2[@]}" $mode; else run_path p2a_$p "${X1[@]}" $mode; fi
            else
                (( q % XW == w )) || continue
                run_path p2a_$p "${X1[@]}" $mode; run_path p2b_$p "${X2[@]}" $mode
            fi
        done
        wait
        [[ $mode == udp ]] || column -t < "$PHASE_OUT" | tee -a "$res"
        cat "$PHASE_OUT" >> "$all"
    done
    PHASE_OUT=$all
}

# p1_paths p check|run [mode]: pair p's same-rail paths, one per rail its group holds: client->server on even
# rails, server->client on odd ones (two rails: A c->s, B s->c), so each host sends on some rails and receives on others
p1_paths() {
    local p=$1 fn=${2}_path mode=$3 r
    for r in ${PRAILS[p]}; do
        if (( r % 2 )); then $fn p1${r}_$p ${PS[p]} $r ${PC[p]} $r $mode
        else $fn p1${r}_$p ${PC[p]} $r ${PS[p]} $r $mode; fi
    done
}
# "A->A and B->B" / "A->B and B->A" for the log
same_desc() { local r o=""; for r in "${RAILS[@]}"; do o+="$( (( r == 0 )) || { (( r == NR - 1 )) && echo " and " || echo ", "; })$(rail_letter $r)->$(rail_letter $r)"; done; echo "$o"; }
cross_desc() { echo "$(rail_letter ${XA:-0})->$(rail_letter ${XB:-1}) and $(rail_letter ${XB:-1})->$(rail_letter ${XA:-0})"; }

# check_path key src_k src_r dst_k dst_r: writes OK or a reason to $PATHS/key
check_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5
    if ! rail_ok $sk $sr; then echo "DOWN ${T_HOST[$sk]}: ${RSTATE[$sk,$sr]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $dk $dr; then echo "DOWN ${T_HOST[$dk]}: ${RSTATE[$dk,$dr]}" > "$PATHS/$key"; return; fi
    local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
    # same rail: the larger MTU, so a 1500/9000 pair fails here, not pass at 1472 and run with retransmits.
    # Cross-rail (routed): the smaller of the two rails' MTUs (each rail at its highest host MTU, as its
    # router side would be), so a 4220 RDMA rail to a 9000 rail passes but a 1500 host on a 9000 rail fails.
    local r1=${RAIL_MTU[$sr]:-$m1} r2=${RAIL_MTU[$dr]:-$m2}
    local size=$(( (sr == dr ? (m1 > m2 ? m1 : m2) : (r1 < r2 ? r1 : r2)) - 28 ))
    ( out=$(rbash "${T_TARGET[$sk]}" "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "${RNIC[$sk,$sr]}" $size <<<"$PATH_SCRIPT" 2>&1)
      echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
}

# run_path key src_k src_r dst_k dst_r [udp]: one iperf3 run, appends to $PHASE_OUT
run_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5 mode=${6:-tcp} st
    st=$(cat "$PATHS/$key")
    if [[ $st != OK ]]; then
        echo "$ITER $PHASE ${T_HOST[$sk]} ${RIP[$sk,$sr]} ${T_HOST[$dk]} ${RIP[$dk,$dr]} $st" >> "$PATH_EXCL"
        log "  skip ${T_HOST[$sk]} ${RIP[$sk,$sr]} -> ${T_HOST[$dk]} ${RIP[$dk,$dr]}: $st"
        return
    fi
    if [[ $mode == check ]]; then echo "${RIP[$sk,$sr]} ${RIP[$dk,$dr]}" >> "$WORK/paths_ok"; return; fi   # FF_SKIP_IPERF=1
    if [[ $mode == udp ]]; then
        local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
        local len=$(( (m1 < m2 ? m1 : m2) - 28 ))   # largest datagram that needs no fragmenting
        ( out=$(rbash -T $(( FF_UDP_DURATION + 30 )) "${T_TARGET[$sk]}" \
                  "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_UDP_DURATION" "$len" "$FF_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(rbash -T $(( FF_DURATION + 30 )) "${T_TARGET[$sk]}" \
              "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FF_PORT" "$FF_STREAMS" "$FF_DURATION" "$FF_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
}

# host_nics k: host k's data NICs ("-" = none on that rail): its rail NICs, or a client's data NICs
host_nics() {
    local k=$1 r
    if [[ -n ${IS_CL[$k]} ]]; then for (( r = 0; r < ${CN[$k]:-0}; r++ )); do echo "${CNIC[$k,$r]}"; done
    else for r in "${RAILS[@]}"; do echo "${RNIC[$k,$r]}"; done; fi
}

collect_counters() {  # script outfile [k...]: run a counter script on every tested host and client (or hosts k...)
    local script=$1 outfile=$2 k; shift 2
    local -a ks=("$@"); (( ${#ks[@]} )) || ks=("${ELIG[@]}" "${CLI[@]}")
    : > "$outfile"
    for k in "${ks[@]}"; do
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$script" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
}

# collect_temps label [ipmi]: TEMP_SCRIPT on every tested host and client, appended to temps.txt as
# "label host source chip dev sensor temp_c high_c crit_c status" (source hwmon|ipmi; sensor none = no data, why in status)
collect_temps() {
    (( FF_TEMPS )) || return 0
    local label=$1 mode=-; [[ $2 == ipmi ]] && (( FF_IPMI )) && mode=ipmi
    local out=$WORK/temps.$label k
    : > "$out"
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        rbash "${T_TARGET[$k]}" "$mode" "$FF_IPMI_TIMEOUT" <<<"$TEMP_SCRIPT" >> "$out" 2>> "$RUNLOG_SSH" &
    done
    wait
    awk -v t="$label" 'function c(m) { return m == "-" ? "-" : sprintf("%.1f", m / 1000) }
        $1 == "@@HWMON" { print t, $2, "hwmon", $3, $4, $5, ($5 == "none" ? "-" : c($6)), c($7), c($8), ($5 == "none" ? "no_hwmon_temperature_sensors" : "-") }
        $1 == "@@IPMI" && $3 == "none" { print t, $2, "ipmi", "bmc", "-", "none", "-", "-", "-", $4 }
        $1 == "@@IPMI" && $3 != "none" { print t, $2, "ipmi", "bmc", "-", $3, $4, $6, $7, $5 }' "$out" >> "$COLLECT_DIR/temps.txt"
}

# temp_summary: temps_summary.txt, one row per sensor over the run: "Host Source Type Chip Dev Sensor First_C Max_C
# Last_C High_C Crit_C Flag". Type cpu|nvme|nic|bmc|other. Flag (worst first): crit (at or above crit, or the BMC says
# cr/nr), high (at or above high, or BMC nc), near (within FF_TEMP_MARGIN of high), then +rise (max - first over
# FF_TEMP_RISE); "-" when none. A threshold of 0 counts as unset. A host/source with no reading at all gets one row,
# Sensor none, Flag nodata:<why>.
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
temp_summary() {
    (( FF_TEMPS )) || return 0
    awk -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" "$TEMP_SUM_AWK" "$COLLECT_DIR/temps.txt" > "$COLLECT_DIR/temps_summary.txt"
}

# System info per tested host, split into $SI/<host>/<item> (SYSINFO_SCRIPT)
collect_sysinfo() {
    local k f t
    log "System info: capturing on $(( ${#ELIG[@]} + ${#CLI[@]} )) hosts, at most ${FF_SYSINFO_TIMEOUT}s each (bundle: sysinfo/<host>/)..."
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        ( rbash -T "$FF_SYSINFO_TIMEOUT" "${T_TARGET[$k]}" $(host_nics $k) \
              <<<"$SYSINFO_SCRIPT" > "$WORK/si.$k" 2>> "$RUNLOG_SSH"; echo $? > "$WORK/si_rc.$k" ) &
    done
    wait
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        f=$WORK/si.$k
        if ! grep -q '^=== SYSINFO ' "$f"; then log "WARNING: ${T_HOST[$k]}: no system info captured (see ssh_errors.log)"; continue; fi
        if [[ $(cat "$WORK/si_rc.$k") == 124 ]]; then
            log "WARNING: ${T_HOST[$k]}: system info cut off after ${FF_SYSINFO_TIMEOUT}s (FF_SYSINFO_TIMEOUT); the partial capture is kept"
            SI_CUT[${T_HOST[$k]}]=1
        fi
        t=$(awk '/^=== SYSINFO / {s = $3} /^n\/a: .* timed out after/ {printf "%s%s", c, s; c = " "}' "$f")
        [[ -n $t ]] && log "WARNING: ${T_HOST[$k]}: system info items timed out: $t"
        mkdir -p "$SI/${T_HOST[$k]}"
        awk -v d="$SI/${T_HOST[$k]}" '/^=== SYSINFO [^ \/]+ ===$/ {if (o) close(o); o = d "/" $3; next} o {print > o}' "$f"
    done
}

# Rail NIC receive config from the sysinfo capture: "host rail numa ring_cur/max pcie_GTs x width cur/max"
rx_config() {
    local k r
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RNIC[$k,$r]} != - ]] && rx_one "${T_HOST[$k]}" "$(rail_letter $r)" "$SI/${T_HOST[$k]}/nic-${RNIC[$k,$r]}"
    done; done
    return 0
}

rx_one() {  # host slot sysinfo_nic_file: one rx config line (slot: rail letter, or a client's NIC number)
    [[ -f $3 ]] || return 0
    awk -v h="$1" -v r="$2" '
            $1 == "numa_node" { numa = $2 }
            $1 ~ /^(current|max)_link_(speed|width)$/ { v = $2; sub(/[^0-9.].*/, "", v); L[$1] = v }
            /^--- / { sec = $3; g = "" }
            sec == "-g" && /^Pre-set maximums/ { g = "max" }
            sec == "-g" && /^Current hardware/ { g = "cur" }
            sec == "-g" && $1 == "RX:" && g != "" && !(g in R) { R[g] = $2 }
            END { ring = ("cur" in R && "max" in R) ? R["cur"] "/" R["max"] : "-"
                  pc = (L["current_link_speed"] != "" && L["max_link_speed"] != "") ? \
                       L["current_link_speed"] "x" L["current_link_width"] "/" L["max_link_speed"] "x" L["max_link_width"] : "-"
                  print h, r, (numa ~ /^-?[0-9]+$/ ? numa : "-"), ring, pc }' "$3"
}

# hostctr_delta label pre post: receive counters that rose -> host_counters.txt "label host key delta"
hostctr_delta() {
    awk -v t="$1" 'NR == FNR {p[$1 " " $2] = $3; next}
        ($1 " " $2) in p && $3 ~ /^[0-9]+$/ && $3 > p[$1 " " $2] {print t, $1, $2, $3 - p[$1 " " $2]}' "$2" "$3" > "$WORK/hc_delta"
    cat "$WORK/hc_delta" >> "$COLLECT_DIR/host_counters.txt"
    # who answered this read, and with AER counters: a counter never read shows as "-" in host_rx.txt, not 0
    awk '{n[$1]++; if ($2 ~ /^aer_/) a[$1] = 1} END {for (h in n) print h, ((h in a) ? 1 : 0)}' "$3" >> "$WORK/hc_reads"
    HC_READS=$(( HC_READS + 1 ))
}

# hc_log what snapshot: one line on the receive drop counters in $WORK/hc_delta (squeezes stay in the table only)
hc_log() {
    local hd; hd=$(awk '$3 ~ /^(softnet_dropped|TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop|TCPMemoryPressures|aer_)/' "$WORK/hc_delta" | sort -k4 -rn)
    if [[ -n $hd ]]; then
        log "  Host receive drops in $1 ($(echo "$hd" | wc -l | tr -d ' ') counters rose; top 5): $(echo "$hd" | head -n 5 | awk '{printf "%s%s %s +%d", s, $2, $3, $4; s = "; "}')"
    else log "  No host receive drop counter rose in $1 ($(wc -l < "$2" | tr -d ' ') counters read)"; fi
}

# Kernel log per host since its own sysinfo epoch -> $SI/<host>/kernel-log
collect_klog() {
    local k e
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        e=$(cat "$SI/${T_HOST[$k]}/epoch" 2>&1); [[ $e =~ ^[0-9]+$ ]] || continue
        throttle
        rbash "${T_TARGET[$k]}" "$e" <<<"$KLOG_SCRIPT" > "$SI/${T_HOST[$k]}/kernel-log" 2>> "$RUNLOG_SSH" &
    done
    wait
}

# Kernel log lines that point at the receive path or the NIC (a match is a lead, not a verdict)
KLOG_RE='aer|pcie bus error|link is down|tx timeout|transmit timeout|watchdog|hung_task|blocked for more than|out of memory|oom-kill|mlx5.*(err|fail|timeout|health)'

# host_rx.txt: per host, rail NIC config + receive counters over the run + iperf3 CPU + kernel log leads, with flags.
# Files: nicmap, ipmap, rx config, hostinfo (host governor irqbalance klog_hits), TCP results, host_counters, prio_counters.
HOSTRX_AWK='
# by argument position, not FNR: an empty file (no counter rose) has no first line and would shift the count
FNR == 1 { for (f = 1; f < ARGC; f++) if (ARGV[f] == FILENAME) break }
f == 1 { nh[$1] = $2; next }
f == 2 { ih[$1] = $2; next }
f == 3 { hosts[$1] = 1; numa[$1, $2] = $3; ring[$1, $2] = $4; pcie[$1, $2] = $5
         if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) fl[$1] = fl[$1] ",ring" $2 "<max"
         if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) fl[$1] = fl[$1] ",pcie" $2 "<max" }
         next }
f == 4 { gov[$1] = $2; irq[$1] = $3; kl[$1] = $4; th[$1] = $6; hosts[$1] = 1
         if ($5 == "missing") fl[$1] = fl[$1] ",sysinfo_missing"; else if ($5 == "cut") fl[$1] = fl[$1] ",sysinfo_partial"
         if ($2 != "-" && $2 != "performance") fl[$1] = fl[$1] ",gov:" $2; if ($4 > 0) fl[$1] = fl[$1] ",klog"; next }
f == 5 { split($1, ip, ","); for (i = 1; i <= NF; i++) if ($i ~ /^cpu:/) { split(substr($i, 5), u, "/")
             if (u[2] ~ /^[0-9.]+$/ && (!(ih[ip[2]] in rc) || u[2] + 0 > rc[ih[ip[2]]])) rc[ih[ip[2]]] = u[2] + 0
             if (u[1] ~ /^[0-9.]+$/ && (!(ih[ip[1]] in sc) || u[1] + 0 > sc[ih[ip[1]]])) sc[ih[ip[1]]] = u[1] + 0 }
         next }
f == 6 { k = $3; sub(/:.*/, "", k)
         if (k == "softnet_dropped") sd[$2] += $4; else if (k == "softnet_squeezed") sq[$2] += $4
         else if (k ~ /^(TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop)$/) td[$2] += $4
         else if (k ~ /^aer_/) ae[$2] += $4
         next }
f == 7 { if ($3 !~ /^rdma:/ && tolower($3) ~ /discard|out_of_buffer/) nd[nh[$2]] += $4; next }
f == 8 { hr[$1] = $2; ha[$1] = $3; next }
f == 9 { if ($2 !~ /^rdma:/ && tolower($2) ~ /discard|out_of_buffer/) dc[nh[$1]] = 1 }
function v(a, k) { return (k in a) ? a[k] : "-" }
END {
    nr = length(RL); hn = "NUMA_"; hg = ""; hp = ""
    for (i = 1; i <= nr; i++) { lt = substr(RL, i, 1); hn = hn (i > 1 ? "/" : "") lt; hg = hg " Ring_" lt; hp = hp " PCIe_" lt }
    print "Host " hn hg hp " Governor IRQbal RcvCPU% RcvThr% SndCPU% Softnet_drop Squeeze TCP_rcv_drop NIC_discard AER Klog Flags"
    for (h in hosts) {
        # "-" = not read (ssh failed, no AER in sysfs, no discard counter on this driver): unknown, not zero
        cr = (h in hr) ? hr[h] : 0
        if (cr == 0) fl[h] = fl[h] ",counters_unread"; else if (cr < ns) fl[h] = fl[h] ",counters_partial"
        SD = cr ? sd[h] + 0 : "-"; SQ = cr ? sq[h] + 0 : "-"; TD = cr ? td[h] + 0 : "-"
        ND = (h in dc) ? nd[h] + 0 : "-"; AE = (ha[h] > 0) ? ae[h] + 0 : "-"
        if (SD > 0) fl[h] = fl[h] ",softnet_drop"; if (TD > 0) fl[h] = fl[h] ",tcp_rcv_drop"
        if (ND > 0) fl[h] = fl[h] ",nic_discard"; if (AE > 0) fl[h] = fl[h] ",aer"
        # iperf3 3.16+ runs a thread per stream and sums their CPU, so judge per thread: raw / threads (th: FF_STREAMS
        # on 3.16+, else 1; an unknown version counts as 1, which can only flag more)
        RT = (h in rc) ? sprintf("%.1f", rc[h] / ((th[h] + 0 > 0) ? th[h] : 1)) : "-"
        if (RT != "-" && RT + 0 >= 90) fl[h] = fl[h] ",rcv_cpu>=90/thread"
        nu = ""; ri = ""; pc = ""
        for (i = 1; i <= nr; i++) { lt = substr(RL, i, 1); nu = nu (i > 1 ? "/" : "") v(numa, h SUBSEP lt); ri = ri " " v(ring, h SUBSEP lt); pc = pc " " v(pcie, h SUBSEP lt) }
        printf "%s %s%s%s %s %s %s %s %s %s %s %s %s %s %s %s\n", h, nu, ri, pc, v(gov, h), v(irq, h),
            ((h in rc) ? rc[h] : "-"), RT, ((h in sc) ? sc[h] : "-"), SD, SQ, TD, ND, AE, v(kl, h), (fl[h] == "" ? "-" : substr(fl[h], 2))
    }
}'

# hostinfo_line host: "host governor irqbalance klog_hits sysinfo_state iperf3_threads" from its sysinfo
hostinfo_line() {
    local h=$1 g i n s t
    g=-; [[ -f $SI/$h/cpu-governor ]] && g=$(awk '$1 ~ /^[0-9]+$/ {printf "%s%s", s, $2; s = "+"} /^n\/a/ {printf "-"}' "$SI/$h/cpu-governor")
    i=$(cat "$SI/$h/irqbalance" 2>&1); [[ $i == running ]] && i=on || { [[ $i == "not running" ]] && i=off || i=-; }
    n=-; [[ -f $SI/$h/kernel-log ]] && n=$(grep -c -i -E "$KLOG_RE" "$SI/$h/kernel-log")
    s=ok; [[ -d $SI/$h ]] || s=missing; [[ -n ${SI_CUT[$h]} ]] && s=cut
    # iperf3 threads per receiving process: one per stream from 3.16 (its own --version, from sysinfo)
    t=1; [[ -f $SI/$h/iperf3 ]] && (( $(awk 'match($0, /iperf 3\.[0-9]+/) {print substr($0, RSTART + 8, RLENGTH - 8) + 0; exit}' "$SI/$h/iperf3") + 0 >= 16 )) && t=$FF_STREAMS
    echo "$h ${g:--} $i $n $s $t"
}

host_rx() {  # writes $COLLECT_DIR/host_rx.txt (and client_rx.txt) and prints the flagged hosts
    local k
    rx_config > "$WORK/rxcfg"
    for k in "${ELIG[@]}"; do hostinfo_line "${T_HOST[$k]}"; done > "$WORK/hostinfo"
    # iperf3 CPU from every run a host was in, the client runs included
    { cat "$1"; [[ -f ${CRESULTS:-} ]] && cat "$CRESULTS"; } | grep "Gbits/sec" > "$WORK/rx_results"
    awk '{r[$1]++; a[$1] += $2} END {for (h in r) print h, r[h], a[h]}' "$WORK/hc_reads" > "$WORK/hcreads"
    [[ -f $WORK/prio_post ]] || : > "$WORK/prio_post"
    awk -v ns="$HC_READS" -v RL="${LETTERS:0:NR}" "$HOSTRX_AWK" "$WORK/nicmap" "$WORK/ipmap" "$WORK/rxcfg" "$WORK/hostinfo" "$WORK/rx_results" \
        "$COLLECT_DIR/host_counters.txt" "$COLLECT_DIR/prio_counters.txt" "$WORK/hcreads" "$WORK/prio_post" \
        | { read -r hdr; echo "$hdr"; sort -V; } > "$COLLECT_DIR/host_rx.txt"
    (( ${#CLI[@]} )) && client_rx
    return 0
}

# client_rx: host_rx.txt's columns for the clients -> client_rx.txt, NIC slots 1..N in clients.txt order
client_rx() {
    local k j h nm=0 sl=""
    for k in "${CLI[@]}"; do (( CN[$k] > nm )) && nm=${CN[$k]}; done
    for (( j = 1; j <= nm; j++ )); do sl+=$j; done
    : > "$WORK/cnicmap"; : > "$WORK/cipslot"; : > "$WORK/crxcfg"; : > "$WORK/chostinfo"
    for k in "${CLI[@]}"; do
        h=${T_HOST[$k]}
        for (( j = 0; j < CN[$k]; j++ )); do
            echo "${h}_${CNIC[$k,$j]} $h $(( j + 1 ))" >> "$WORK/cnicmap"
            [[ ${CIP[$k,$j]} != none ]] && echo "${CIP[$k,$j]} $h $(( j + 1 ))" >> "$WORK/cipslot"
            rx_one "$h" $(( j + 1 )) "$SI/$h/nic-${CNIC[$k,$j]}" >> "$WORK/crxcfg"
        done
        hostinfo_line "$h" >> "$WORK/chostinfo"
    done
    awk -v ns="$HC_READS" -v RL="$sl" "$HOSTRX_AWK" "$WORK/cnicmap" "$WORK/cipslot" "$WORK/crxcfg" "$WORK/chostinfo" "$WORK/rx_results" \
        "$COLLECT_DIR/host_counters.txt" "$COLLECT_DIR/prio_counters.txt" "$WORK/hcreads" "$WORK/prio_post" \
        | { read -r hdr; echo "Client ${hdr#Host }"; sort -V; } > "$COLLECT_DIR/client_rx.txt"
}

# UDP loss placement, the same rule as the dashboard: per phase and receiving host,
# unaccounted = lost - (that host's InErrors + backlog drops + rail-NIC drops), floored at 0. The kernel
# also adds backlog drops to rx_dropped, so NIC = max(0, rx_dropped - backlog) + rx_out_of_buffer.
# Sender TX = datagrams the sender NIC never put on the wire (udp_expected.txt, by run, charged to the run's
# receiver), taken out before unaccounted. Expected = what overload alone loses of what reached the wire;
# beyond = unaccounted above it, per host.
# Files: udp_expected.txt, ipmap (ip host rail), nicmap (host_nic host rail), UDP results, host counters, NIC drops.
# -v t="iterN Ux" limits it to one phase. Prints: lost sent socket nic backlog unaccounted over expected beyond tx
# (over: buckets beyond the loss).
UDP_ATTR_AWK='
FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }   # by name: an empty file must not shift the rest
f == 1 { E[$1 " " $2 " " $3 " " $4 " " $5] = $8; TR[$1 " " $2 " " $3 " " $4 " " $5] = $12 + 0; next }
f == 2 { host[$1] = $2; next }
f == 3 { nh[$1] = $2; next }
f == 4 { if (/^### /) { split($2, a, ":"); split($3, b, ":"); ph = "iter" a[2] " " b[2]; wv = ($4 ~ /^wave:/) ? substr($4, 6) : "-"; next }
         if (t != "" && ph != t) next
         n = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); n = 1 }
         if (!n) next
         split($1, s, ","); k = ph SUBSEP host[s[2]]; L[k] += x[1]; sent += x[2]; r = ph " " wv " " s[1] " " s[2]
         TX[k] += TR[r]; X[k] += E[r] * (x[2] - TR[r]); next }
f == 5 { k = $1 " " $2 SUBSEP $3; SK[k] += $4; BK[k] += $7; next }
f == 6 { k = $1 " " $2 SUBSEP nh[$3]; DR[k] += $4; DO[k] += $5 }
END { for (k in L) { nk = DR[k] - BK[k]; if (nk < 0) nk = 0; nk += DO[k]
                     lost += L[k]; sock += SK[k]; nic += nk; back += BK[k]; ex += X[k]; tx += TX[k]
                     u = L[k] - TX[k] - SK[k] - nk - BK[k]; if (u > 0) un += u; else ov -= u
                     if (u - X[k] > 0) bey += u - X[k] }
      printf "%d %d %d %d %d %d %d %d %d %d\n", lost, sent, sock, nic, back, un, ov, ex + 0.5, bey, tx }'

udp_attr() {  # [iterN Ux] -> "lost sent socket nic backlog unaccounted over expected beyond tx"
    awk -v t="$1" "$UDP_ATTR_AWK" "$COLLECT_DIR/udp_expected.txt" "$WORK/uipmap" "$WORK/unicmap" "$UDP_RESULTS" \
        "$COLLECT_DIR/udp_host_counters.txt" "$COLLECT_DIR/udp_nic_drops.txt"
}

# cross_summary ipmap results: the inter-rail total (an iteration's cross-rail runs share the path between
# the rails at once) and, when only cross-rail runs miss the OK cut-off, where to look.
cross_summary() {
    local x xm am bm
    x=$(awk -F'[, ]+' 'NR == FNR { rail[$1] = $3; next }
        /^### / { split($2, a, ":"); it = a[2]; if ($4 ~ /^wave:/) it = it "w" substr($4, 6); next }
        { g = -1; rt = 0
          for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^retransmits:/) { split($i, q, ":"); rt = q[2] + 0 } }
          if (g >= 0 && ($1 in rail) && ($2 in rail)) print (rail[$1] == rail[$2] ? rail[$1] : rail[$1] ">" rail[$2]), it, g, rt }' "$1" "$2")
    [[ $x == *'>'* ]] || return 0
    awk -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v cm="${FF_CROSS_MAX:-0}" '
        function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
        function k(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e4 ? sprintf("%.1fk", n / 1e3) : n) }
        function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return ""
            for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
            return sprintf("%.1f", n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2) }
        BEGIN { nr = split(lines, q, " "); for (i = 1; i <= nr; i++) { split(q[i], kv, "="); R[i] = kv[1]; L[kv[1]] = kv[2] + 0 } }
        $1 ~ />/ { nx++; d[$1]++; tot[$2] += $3; xr += $4; xv = xv " " $3; if (index($2, "w")) wv = 1; next }
        { sr += $4; sv[$1] = sv[$1] " " $3 }
        END { for (i in tot) { ni++; s += tot[i]; if (ni == 1 || tot[i] < lo) lo = tot[i]; if (ni == 1 || tot[i] > hi) hi = tot[i] }
              if (ni == 1) printf "  Cross-rail total: %s over %d flows run at once", bw(s), nx
              else if (wv) printf "  Cross-rail total per wave (FF_CROSS_MAX=%d flows at once): largest %s, %s on average (%s to %s over %d waves), %d flows", cm, bw(hi), bw(s / ni), bw(lo), bw(hi), ni, nx
              else printf "  Cross-rail total per iteration: %s on average (%s to %s over %d iterations), %d flows", bw(s / ni), bw(lo), bw(hi), ni, nx
              # directions: every one with two rails (as before), the ones that ran with more
              ds = ""; for (i = 1; i <= nr; i++) for (j = 1; j <= nr; j++) if (i != j && (nr == 2 || (R[i] ">" R[j]) in d))
                  ds = ds sprintf("%s%s->%s %d", ds == "" ? "" : ", ", R[i], R[j], d[R[i] ">" R[j]])
              xm = med(xv)
              printf " (%s); median %s Gbps per flow; retransmits %s cross-rail vs %s same-rail\n", ds, xm, k(xr), k(sr + 0)
              lx = 0; for (i = 1; i <= nr; i++) if (i == 1 || L[R[i]] < lx) lx = L[R[i]]
              cx = lx * ok / 100; any = 0; allok = 1; sm = ""
              for (i = 1; i <= nr; i++) { m = med(sv[R[i]]); sm = sm sprintf("%s%s (%s)", i > 1 ? " / " : "", m == "" ? "-" : m, R[i])
                  if (m != "") { any = 1; if (m + 0 < L[R[i]] * ok / 100) allok = 0 } }
              if (lx > 0 && xm + 0 < cx && any && allok)
                  printf "  Same-rail runs are OK, cross-rail runs are not: cross-rail median %s Gbps per flow (OK >= %g), same-rail median %s Gbps. The hosts pass on their own rail, so the likely limit is the shared path between the rails (switch inter-link or spine), not the hosts.\n", xm, cx, sm }' <<<"$x"
}

# uplink_summary ipmap lldp nicdiag results: per leaf (its LLDP neighbour) and phase, the runs that cross
# to another leaf, out by the source's leaf and in by the destination's. With FF_SPINES/FF_SPINE_LINKS/
# FF_SPINE_GBPS, judged against C = spines x links x Gbps per direction. NICs without LLDP stay out.
UPLINK_AWK='
function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return -1
    for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
    return n % 2 ? v[(n + 1) / 2] + 0 : (v[n / 2] + v[n / 2 + 1]) / 2 }
function tb(g) { return g >= 1000 ? sprintf("%.2f T", g / 1000) : sprintf("%.1f G", g) }
BEGIN { nr = split(lines, lq, " "); for (i = 1; i <= nr; i++) { split(lq[i], kv, "="); L[kv[1]] = kv[2] + 0; if (i == 1 || kv[2] + 0 < lx) lx = kv[2] + 0 } }
FNR == 1 { f++ }
f == 1 { rail[$1] = $3; if ($3 == "client") cl[$1] = 1; else nip++; next }
f == 2 { if ($4 != "unknown" && $4 != "") { if (!($3 in leaf)) leaf[$3] = $4; else if (index("+" leaf[$3] "+", "+" $4 "+") == 0) leaf[$3] = leaf[$3] "+" $4 }; next }   # an IP'\''s leaf from any row naming one (a bond: its members); two leaves = an MLAG pair "x+y"
f == 3 { if ($4 ~ /^[0-9]+Mb\/s$/) { s = $4; sub(/Mb\/s/, "", s); sp[$3] = s / 1000 }; next }
/^### / { it = ""; ph = ""; w = ""
          for (i = 2; i <= NF; i++) { if ($i ~ /^iteration:/) it = substr($i, 11); else if ($i ~ /^phase:/) ph = substr($i, 7); else if ($i ~ /^wave:/) w = substr($i, 6) }
          if (w != "") it = it " wave " w; next }
{ g = -1; for (i = 1; i <= NF; i++) if ($i == "Gbits/sec") { g = $(i-1) + 0; break }
  if (g < 0 || !($1 in rail) || !($2 in rail)) next
  if (!($1 in leaf) || !($2 in leaf)) { left++; next }
  x = leaf[$1]; y = leaf[$2]
  if (x == y) { if (rail[$1] == rail[$2]) same[x] = same[x] " " g; next }
  if (!((ph, it, x) in seen)) { seen[ph, it, x] = 1; key[++nk] = ph SUBSEP it SUBSEP x }
  if (!((ph, it, y) in seen)) { seen[ph, it, y] = 1; key[++nk] = ph SUBSEP it SUBSEP y }
  ob[ph, it, x] += g; ib[ph, it, y] += g; xl[ph, x] = xl[ph, x] " " g; xl[ph, y] = xl[ph, y] " " g; its[ph, it] = 1 }
# side: a leaf seen by client NICs only is a client leaf (capacity CC), else a backend leaf (C)
END {
    for (ip in rail) if (ip in leaf) { if (ip in cl) cleaf[leaf[ip]] = 1; else { nl++; bleaf[leaf[ip]] = 1 }
                                       dl[leaf[ip]] += (ip in sp) ? sp[ip] : ((ip in cl) ? cgb : L[rail[ip]]) }
                     else if (!(ip in cl)) nm++
    if (mode == "client") {
        # clients: one pass over the client runs, each leaf against its own side
        for (lf in cleaf) if (lf in bleaf) nsh++
        if (CC > 0) printf "  Declared client leaf uplinks: %d spines x %d links x %dG = %s per leaf, each direction\n", N, CM, CS, tb(CC)
        if (nsh) printf "  %d leaves serve both clients and backends; they are judged as backend leaves (rail_anomalies.txt shared_leaf)\n", nsh
        C0 = C; C = 1   # judge per leaf below
    } else {
        if (C > 0) printf "  Declared uplinks: %d spines x %d links x %dG = %s per leaf, each direction\n", N, M, S, tb(C)
        # the NICs left out are said before any exit (a 10-27 field run dropped 285 runs and said nothing)
        if (nm) printf "  Uplinks: %d of %d rail NICs have no LLDP neighbour; their %d runs are left out of the leaf totals.\n", nm, nip, left
        if (!nl) { if (C > 0) print "  Uplink check skipped: it needs LLDP, and no rail NIC reported a switch neighbour."; exit }
    }
    # busiest iteration per (phase, leaf), in first-seen order
    for (k = 1; k <= nk; k++) { split(key[k], p, SUBSEP); bz = ob[key[k]] > ib[key[k]] ? ob[key[k]] : ib[key[k]]
        pl = p[1] SUBSEP p[3]; if (!(pl in best)) lst[++no] = pl; if (!(pl in best) || bz > best[pl]) { best[pl] = bz; bk[pl] = key[k] } }
    if (mode == "client") {
        if (!no) { print "  No client runs crossed between leaves" (left ? sprintf(" (%d runs have a NIC with no LLDP neighbour)", left) : "") "."; exit }
        print "  Client runs, uplink totals per leaf (busiest wave):"
        for (q = 1; q <= no; q++) { pl = lst[q]; split(pl, p, SUBSEP); k = bk[pl]; split(k, kk, SUBSEP); lf = p[2]
            side = (lf in bleaf) ? ((lf in cleaf) ? "shared" : "backend") : "client"; cp = (lf in bleaf) ? C0 : CC
            bi = sprintf(" [iteration %s]", kk[2])
            if (cp <= 0) { printf "  Uplinks %s (%s leaf) phase %s: out %s / in %s%s; downlinks %s\n", lf, side, p[1], tb(ob[k]), tb(ib[k]), bi, tb(dl[lf]); continue }
            pct = 100 * best[pl] / cp
            printf "  Uplinks %s (%s leaf) phase %s: out %s / in %s of %s declared (%.0f%%)%s; downlinks %s, oversubscribed %.1f:1\n", lf, side, p[1], tb(ob[k]), tb(ib[k]), tb(cp), pct, bi, tb(dl[lf]), dl[lf] / cp
            if (pct >= ok) printf "    at declared uplink capacity: client runs through %s get their share of the uplinks, not line rate\n", lf
        }
        exit
    }
    if (!no && C == 0) exit
    if (C == 0) print "  Uplink totals per leaf (set FF_SPINES, FF_SPINE_LINKS, FF_SPINE_GBPS to judge against uplink capacity):"
    if (!no) { print "  No runs crossed between leaves."; exit }
    okc = lx * ok / 100
    for (q = 1; q <= no; q++) { pl = lst[q]; split(pl, p, SUBSEP); k = bk[pl]; split(k, kk, SUBSEP)
        ni = 0; for (z in its) { split(z, zz, SUBSEP); if (zz[1] == p[1]) ni++ }
        bi = ni > 1 ? sprintf(" [iteration %s, busiest of %d]", kk[2], ni) : ""
        if (C == 0) { printf "  Uplinks %s phase %s: out %s / in %s%s; downlinks %s\n", p[2], p[1], tb(ob[k]), tb(ib[k]), bi, tb(dl[p[2]]); continue }
        pct = 100 * best[pl] / C
        printf "  Uplinks %s phase %s: out %s / in %s of %s declared (%.0f%%)%s; downlinks %s, oversubscribed %.1f:1\n", p[2], p[1], tb(ob[k]), tb(ib[k]), tb(C), pct, bi, tb(dl[p[2]]), dl[p[2]] / C
        xm = med(xl[pl]); sm = med(same[p[2]])
        if (lx > 0 && pct >= ok && xm < lx)
            printf "    at declared uplink capacity: oversubscribed %.1f:1 by design; cross-leaf runs (median %.1f Gbps) get their share of the uplinks, not line rate\n", dl[p[2]] / C, xm
        else if (lx > 0 && xm >= 0 && xm < okc && sm >= okc && pct < slow)
            printf "    uplinks carried only %.0f%% of declared capacity while cross-leaf runs were slow (median %.1f Gbps, OK >= %g) and same-leaf runs were OK (median %.1f); a link or spine may be down, or ECMP is uneven\n", pct, xm, okc, sm
    } }'

# uplink_summary [client] ipmap lldp nicdiag results: "client" = the client runs, each leaf judged by its side
uplink_summary() {
    local mode=; [[ $1 == client ]] && { mode=client; shift; }
    awk -F'[, ]+' -v mode="$mode" -v C="${UPLINK_GBPS:-0}" -v CC="${CL_UPLINK_GBPS:-0}" -v N="$FF_SPINES" -v M="$FF_SPINE_LINKS" -v S="$FF_SPINE_GBPS" \
        -v CM="$FF_CLIENT_SPINE_LINKS" -v CS="$FF_CLIENT_SPINE_GBPS" -v lines="$RAIL_LINES" -v cgb="${FF_CLIENT_GBPS:-0}" \
        -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT" "$UPLINK_AWK" "$@"
}

# UDP phases U1 (same rail) and U2 (cross) on the current pairs, with host and NIC
# counters read around each phase so lost datagrams can be placed.
udp_phases() {
    local u p ck sk a=$WORK/udp.0
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"
    for u in 1 2; do
        PHASE=U$u; PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
        if [[ $u == 2 && $CROSS != on ]]; then log "Phase U2: skipped (cross-rail $CROSS)"; phase_skip U2; continue; fi
        phase_start
        [[ $u == 1 ]] && log "Phase U1: UDP $(same_desc) at once (-b 0), start $PT0" || log "Phase U2: UDP cross-rail, $(cross_desc) at once (-b 0), start $PT0"
        echo "### iteration:${ITER} phase:${PHASE}" >> "$UDP_RESULTS"
        if [[ $u == 1 ]]; then
            for (( p = 0; p < ${#PC[@]}; p++ )); do p1_paths $p run udp; done
            wait
        else xwaves "$UDP_RESULTS" udp; fi
        phase_end $PHASE
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        local errs b=$WORK/udp.$u; errs=$(grep -c ',ERROR' "$PHASE_OUT")
        (( errs > 0 )) && { log "WARNING: $errs UDP runs in phase $PHASE returned no result (lines with ERROR above):"; log_hist "$PHASE_OUT"; }
        collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"; collect_counters "$TXCTR_SCRIPT" "$b.tx"
        collect_temps "iter${ITER}_$PHASE"
        udp_close $PHASE "$a" "$b"
        a=$b
    done
}

# udp_close phase pre post: the phase's host and NIC counter deltas, appended to udp_host_counters.txt
# ("iterN phase host dInErrors dRcvbufErrors dSndbufErrors dSoftnet") and udp_nic_drops.txt ("iterN phase host_nic drx doob"),
# then its loss line
udp_close() {
    local ph=$1 a=$2 b=$3 r
    awk -v t="iter$ITER $ph" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
        ($1, 2) in p {printf "%s %s", t, $1; for (i = 2; i <= 5; i++) printf " %d", $i - p[$1, i]; print ""}' \
        "$a.host" "$b.host" >> "$COLLECT_DIR/udp_host_counters.txt"
    awk -v t="iter$ITER $ph" 'NR==FNR {rx[$1] = $3; oob[$1] = $5; next} ($1 in rx) {
            drx = ($3 ~ /^[0-9]+$/ && rx[$1] ~ /^[0-9]+$/) ? $3 - rx[$1] : 0
            doob = ($5 ~ /^[0-9]+$/ && oob[$1] ~ /^[0-9]+$/) ? $5 - oob[$1] : 0
            print t, $1, drx, doob }' "$a.nic" "$b.nic" >> "$COLLECT_DIR/udp_nic_drops.txt"
    # "iterN phase host_nic ip d_kernel_tx d_wire_tx" ("-" = not read)
    awk -v t="iter$ITER $ph" 'NR==FNR {k[$1] = $3; w[$1] = $4; next} ($1 in k) {
            dk = ($3 ~ /^[0-9]+$/ && k[$1] ~ /^[0-9]+$/) ? $3 - k[$1] : "-"
            dw = ($4 ~ /^[0-9]+$/ && w[$1] ~ /^[0-9]+$/) ? $4 - w[$1] : "-"
            print t, $1, $2, dk, dw }' "$a.tx" "$b.tx" >> "$COLLECT_DIR/udp_tx.txt"
    udp_expect
    read -r -a r <<<"$(udp_attr "iter$ITER $ph")"
    log "  $ph loss: ${r[0]} of ${r[1]} datagrams lost ($(awk -v l="${r[0]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * l / s : 0}')%): sender TX ${r[9]}, receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
    log "  $ph expected from overload: ${r[7]} ($(awk -v e="${r[7]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * e / s : 0}')%); unaccounted beyond it (likely fabric): ${r[8]}"
}

# udp_expect: udp_expected.txt, per UDP run "iterN phase wave src dst offered rx expected lost sent gbps tx".
# tx = this run's share of the datagrams its sender NIC never put on the wire in that phase (udp_tx.txt):
# stack = sent - kernel tx packets, NIC = kernel tx - wire tx, each floored at 0 (other traffic only adds
# packets, so a shortfall is real), shared over the NIC's runs by datagrams sent, at most the run's loss.
# offered = what the runs sending to that dst at once (same phase and wave) put on the wire: each run's
# received Gbps x (sent - tx) / delivered; rx = the dst's line rate; expected = 1 - rx/offered when
# offered > rx (uncapped UDP has no backoff: that much is lost to overload alone), else 0. A run that
# delivered nothing, or a dst line rate not known: offered "-", expected 0, so no loss is excused.
UDP_EXPECT_AWK='
FNR == 1 { for (i = 1; i < ARGC; i++) if (ARGV[i] == FILENAME) f = i }
f == 1 { ln[$1] = $2 + 0; next }
f == 2 { k = $1 " " $2 SUBSEP $4; if ($5 ~ /^[0-9]+$/) TK[k] = $5; if ($6 ~ /^[0-9]+$/) TW[k] = $6; next }
/^### / { split($2, a, ":"); split($3, b, ":"); p = "iter" a[2] " " b[2]; g = p " " (($4 ~ /^wave:/) ? substr($4, 6) : "-"); next }
/receiver/ { split($1, s, ","); n++; G[n] = g; P[n] = p; S[n] = s[1]; D[n] = s[2]
             for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") R[n] = $(i-1); if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); Lo[n] = x[1]; Se[n] = x[2] } }
             SP[p SUBSEP s[1]] += Se[n] }
END { for (i = 1; i <= n; i++) { q = P[i] SUBSEP S[i]; sh = 0
          if (q in TK) { sh = SP[q] - TK[q]; if (sh < 0) sh = 0; if (q in TW && TK[q] > TW[q]) sh += TK[q] - TW[q] }
          t = SP[q] ? sh * Se[i] / SP[q] : 0; if (t > Lo[i]) t = Lo[i]; T[i] = t
          k = G[i] SUBSEP D[i]
          if (Se[i] > Lo[i] && R[i] > 0) off[k] += R[i] * (Se[i] - t) / (Se[i] - Lo[i]); else unk[k] = 1 }
      for (i = 1; i <= n; i++) { k = G[i] SUBSEP D[i]; rx = ln[D[i]]; ok = rx > 0 && !(k in unk)
          ex = (ok && off[k] > rx) ? 1 - rx / off[k] : 0
          printf "%s %s %s %s %s %.4f %d %d %s %d\n", G[i], S[i], D[i], (ok ? off[k] : "-"), ((rx > 0) ? rx : "-"), ex, Lo[i], Se[i], R[i], T[i] + 0.5 } }'
udp_expect() {
    awk "$UDP_EXPECT_AWK" "$WORK/iplines" "$COLLECT_DIR/udp_tx.txt" "$UDP_RESULTS" > "$COLLECT_DIR/udp_expected.txt"
}

# ---------- clients ----------
# client_plan: the client runs. Waves (FF_CLIENT_RATIO N): each client data NIC to one backend on every rail,
# spread over the backends, packed first-fit so no client NIC runs twice in a wave and no backend NIC serves
# more than N at once. All at once (full): each client NIC to one backend NIC, rails and backends round robin.
# Sets CT_* (waves) and FT_* (all at once) by task: K client, J its NIC, R rail, B backend (-1: none usable),
# W wave, S port slot, H share (flows on that backend NIC in that wave); CL_NW waves, CL_K servers per backend IP.
# client_plan [iteration]: each iteration moves every client NIC on to the next backend (all at once: the next
# rail, then the next backend), as backend pairing rotates; CL_ALL = iterations for every client NIC x backend NIC.
client_plan() {
    local k j r g=0 t w b nb off=$(( ${1:-1} - 1 ))
    local -a BL=()   # BL[r] = usable backends on rail r, in host order
    for r in "${RAILS[@]}"; do BL[r]=""; for k in "${ORDER[@]}"; do rail_ok $k $r && BL[r]+=" $k"; done; done
    local nbm=0; for r in "${RAILS[@]}"; do local -a bl=(${BL[r]}); (( ${#bl[@]} > nbm )) && nbm=${#bl[@]}; done
    CL_ALL=0; (( CL_WAVES )) && CL_ALL=$nbm; (( CL_FULL && NR * nbm > CL_ALL )) && CL_ALL=$(( NR * nbm )); CL_NBM=$nbm
    (( off )) ||     for r in "${RAILS[@]}"; do [[ -n ${BL[r]} ]] || log "WARNING: no usable backend NIC on rail $(rail_letter $r): client runs to it are skipped"; done
    local -a ck=($(for k in "${CLI[@]}"; do echo "$k ${T_HOST[$k]}"; done | sort -V -k2 | awk '{print $1}'))
    CT_K=(); CT_J=(); CT_R=(); CT_B=(); CT_W=(); CT_S=(); CT_H=(); FT_K=(); FT_J=(); FT_R=(); FT_B=(); FT_S=(); FT_H=()
    CL_NW=0; CL_K=1
    local -A WC=() WL=() FL=()
    for k in "${ck[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do
        for r in "${RAILS[@]}"; do
            local -a bl=(${BL[r]}); nb=${#bl[@]}
            t=${#CT_K[@]}; CT_K[t]=$k; CT_J[t]=$j; CT_R[t]=$r; CT_B[t]=$( (( nb )) && echo ${bl[(g + r + off) % nb]} || echo -1 ); CT_W[t]=-1
        done
        # all at once: rail by NIC count, backend by NIC count over the rails
        r=$(( (g + off) % NR )); local -a bl=(${BL[r]}); nb=${#bl[@]}
        t=${#FT_K[@]}; FT_K[t]=$k; FT_J[t]=$j; FT_R[t]=$r; FT_B[t]=$( (( nb )) && echo ${bl[((g + off) / NR) % nb]} || echo -1 )
        g=$(( g + 1 ))
    done; done
    if (( CL_WAVES )); then
        for (( t = 0; t < ${#CT_K[@]}; t++ )); do
            b=${CT_B[t]}; (( b >= 0 )) || continue
            for (( w = 0; ; w++ )); do
                [[ -z ${WC[$w,${CT_K[t]},${CT_J[t]}]} && ${WL[$w,$b,${CT_R[t]}]:-0} -lt $CL_R ]] && break
            done
            CT_W[t]=$w; CT_S[t]=${WL[$w,$b,${CT_R[t]}]:-0}; WL[$w,$b,${CT_R[t]}]=$(( CT_S[t] + 1 )); WC[$w,${CT_K[t]},${CT_J[t]}]=1
            (( w + 1 > CL_NW )) && CL_NW=$(( w + 1 ))
        done
        for (( t = 0; t < ${#CT_K[@]}; t++ )); do
            (( CT_W[t] >= 0 )) || continue
            CT_H[t]=${WL[${CT_W[t]},${CT_B[t]},${CT_R[t]}]}; (( CT_H[t] > CL_K )) && CL_K=${CT_H[t]}
        done
    fi
    if (( CL_FULL )); then
        for (( t = 0; t < ${#FT_K[@]}; t++ )); do
            b=${FT_B[t]}; (( b >= 0 )) || continue
            FT_S[t]=${FL[$b,${FT_R[t]}]:-0}; FL[$b,${FT_R[t]}]=$(( FT_S[t] + 1 ))
        done
        for (( t = 0; t < ${#FT_K[@]}; t++ )); do
            (( FT_B[t] >= 0 )) || continue
            FT_H[t]=${FL[${FT_B[t]},${FT_R[t]}]}; (( FT_H[t] > CL_K )) && CL_K=${FT_H[t]}
        done
    fi
}

# cl_check key ck cj b r dir: a client path check, written to $PATHS/key. dir c2b: from the client NIC to the
# backend rail IP; b2c: the reverse, from the backend. MTU: the smaller of the two ends (routed).
cl_check() {
    local key=$1 ck=$2 cj=$3 b=$4 r=$5 dir=$6
    if (( b < 0 )); then echo "DOWN no usable backend NIC on rail $(rail_letter $r)" > "$PATHS/$key"; return; fi
    if ! cl_ok $ck $cj; then echo "DOWN ${T_HOST[$ck]}: ${CSTATE[$ck,$cj]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $b $r; then echo "DOWN ${T_HOST[$b]}: ${RSTATE[$b,$r]}" > "$PATHS/$key"; return; fi
    local m1=${CMTU[$ck,$cj]:-1500} m2=${RMTU[$b,$r]:-1500}
    local size=$(( (m1 < m2 ? m1 : m2) - 28 ))
    if [[ $dir == c2b ]]; then
        ( out=$(rbash "${T_TARGET[$ck]}" "${CIP[$ck,$cj]}" "${RIP[$b,$r]}" "${CNIC[$ck,$cj]}" $size <<<"$PATH_SCRIPT" 2>&1)
          echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
    else
        ( out=$(rbash "${T_TARGET[$b]}" "${RIP[$b,$r]}" "${CIP[$ck,$cj]}" "${RNIC[$b,$r]}" $size <<<"$PATH_SCRIPT" 2>&1)
          echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
    fi
}

# cl_run key ck cj b r dir slot share phase: one client iperf3 run (or, with FF_SKIP_IPERF=1, the path check's
# record), appended to $PHASE_OUT as "src,dst,<result> share:N". c2b runs from the client to port FF_PORT+slot
# on the backend; b2c from the backend to the client's one server.
cl_run() {
    local key=$1 ck=$2 cj=$3 b=$4 r=$5 dir=$6 slot=$7 share=$8 ph=$9 mode=${10:-tcp} st src dst from port
    if [[ $dir == c2b ]]; then src=${CIP[$ck,$cj]}; dst=${RIP[$b,$r]:-none}; from=${T_TARGET[$ck]}; port=$(( FF_PORT + slot ))
    else src=${RIP[$b,$r]:-none}; dst=${CIP[$ck,$cj]}; from=${T_TARGET[$b]}; port=$FF_PORT; fi
    (( b >= 0 )) || { src=${CIP[$ck,$cj]}; dst=none; }
    st=$(cat "$PATHS/$key")
    local sh dh; sh=${T_HOST[$ck]}; dh=$( (( b >= 0 )) && echo "${T_HOST[$b]}" || echo - ); [[ $dir == b2c ]] && { sh=$dh; dh=${T_HOST[$ck]}; }
    if [[ $st != OK ]]; then
        echo "$ITER $ph $sh $src $dh $dst $st" >> "$PATH_EXCL"
        log "  skip $sh $src -> $dh $dst: $st"
        return
    fi
    if (( FF_SKIP_IPERF )); then echo "$src $dst" >> "$WORK/cpaths_ok"; return; fi
    if [[ $mode == udp ]]; then   # as run_path: the largest datagram neither end's MTU fragments
        local m1=${CMTU[$ck,$cj]:-1500} m2=${RMTU[$b,$r]:-1500}
        local len=$(( (m1 < m2 ? m1 : m2) - 28 ))
        ( out=$(rbash -T $(( FF_UDP_DURATION + 30 )) "$from" \
                  "$src" "$dst" "$port" "$FF_STREAMS" "$FF_UDP_DURATION" "$len" "$FF_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "$src,$dst,${out%%$'\n'*} share:$share" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(rbash -T $(( FF_DURATION + 30 )) "$from" \
              "$src" "$dst" "$port" "$FF_STREAMS" "$FF_DURATION" "$FF_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "$src,$dst,${out%%$'\n'*} share:$share" >> "$PHASE_OUT" ) &
}

# client_phase P: P = C1/C2 (waves; client->backend, backend->client) or F1/F2 (all at once). Path checks
# first, then the runs, wave by wave, with the drop counters of every client and backend around the phase.
client_phase() {
    local P=$1 dir t w nw pfx; dir=c2b; [[ $P == ?2 ]] && dir=b2c   # $2 = udp: the phase's UDP twin, U$P
    local -a TK TJ TR TB TW TS TH
    if [[ $P == C? ]]; then TK=("${CT_K[@]}"); TJ=("${CT_J[@]}"); TR=("${CT_R[@]}"); TB=("${CT_B[@]}"); TW=("${CT_W[@]}"); TS=("${CT_S[@]}"); TH=("${CT_H[@]}"); nw=$CL_NW
    else TK=("${FT_K[@]}"); TJ=("${FT_J[@]}"); TR=("${FT_R[@]}"); TB=("${FT_B[@]}"); TS=("${FT_S[@]}"); TH=("${FT_H[@]}"); nw=1
         for (( t = 0; t < ${#TK[@]}; t++ )); do TW[t]=$(( TB[t] >= 0 ? 0 : -1 )); done; fi
    (( ${#TK[@]} )) || return 0
    pfx=$(tr 'A-Z' 'a-z' <<<"$P")
    PATHS=$WORK/paths.client.$ITER.$P
    if [[ $2 == udp ]]; then client_udp_waves; return; fi
    mkdir -p "$PATHS"
    for (( t = 0; t < ${#TK[@]}; t++ )); do cl_check ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir; done
    wait
    CL_PLANNED=$(( CL_PLANNED + ${#TK[@]} ))
    local pre=$WORK/cdrops_pre.$ITER.$P post=$WORK/cdrops_post.$ITER.$P
    if (( ! FF_SKIP_IPERF )); then   # the same reads as a backend phase: drops, host receive and priority counters
        collect_drops "$pre" "${ELIG[@]}" "${CLI[@]}"
        collect_counters "$HOSTCTR_SCRIPT" "$pre.hc"; collect_counters "$PRIO_SCRIPT" "$pre.prio"
    fi
    phase_start
    local bad; bad=$(grep -Lx OK "$PATHS"/* | wc -l | tr -d ' ')
    log "Client phase $P ($( [[ $dir == c2b ]] && echo "clients -> backends" || echo "backends -> clients")$( [[ $P == F? ]] && echo ", all at once")): ${#TK[@]} runs in $nw wave$( (( nw > 1 )) && echo s); path checks $(( ${#TK[@]} - bad )) OK, $bad excluded$( (( FF_SKIP_IPERF )) || echo "; start $PT0")"
    # runs no wave could take (no usable backend on their rail) are recorded once, as skips
    for (( t = 0; t < ${#TK[@]}; t++ )); do (( TW[t] < 0 )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir 0 0 $P; done
    for (( w = 0; w < nw; w++ )); do
        PHASE_OUT=$WORK/cphase.$ITER.$P.$w; : > "$PHASE_OUT"
        (( FF_SKIP_IPERF )) || echo "### client iteration:$ITER phase:$P$( (( nw > 1 )) && echo " wave:$(( w + 1 ))/$nw")" >> "$CRESULTS"
        for (( t = 0; t < ${#TK[@]}; t++ )); do
            (( TW[t] == w )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir ${TS[t]} ${TH[t]} $P
        done
        wait
        (( FF_SKIP_IPERF )) && continue
        column -t < "$PHASE_OUT" | tee -a "$CRESULTS"
        lock_all touch
    done
    (( FF_SKIP_IPERF )) && return 0
    phase_end $P
    local errs; errs=$(cat "$WORK"/cphase.$ITER.$P.* | grep -c ",ERROR")
    (( errs > 0 )) && { log "WARNING: $errs client runs in phase $P returned no result (lines with ERROR above):"; log_hist "$WORK"/cphase.$ITER.$P.*; }
    collect_drops "$post" "${ELIG[@]}" "${CLI[@]}"
    collect_counters "$HOSTCTR_SCRIPT" "$post.hc"; collect_counters "$PRIO_SCRIPT" "$post.prio"; collect_temps "iter${ITER}_$P"
    hostctr_delta "iter${ITER}_client$P" "$pre.hc" "$post.hc"; hc_log "client phase $P" "$post.hc"
    awk -v it="iter${ITER}_client$P" 'NR==FNR {pre[$1" "$2]=$3; next}
        ($1" "$2) in pre && $3 > pre[$1" "$2] {print it, $1, $2, $3 - pre[$1" "$2]}' "$pre.prio" "$post.prio" > "$WORK/cprio_delta"
    cat "$WORK/cprio_delta" >> "$COLLECT_DIR/prio_counters.txt"
    awk 'tolower($3) !~ /byte|packet/ || $3 ~ /^rdma:/' "$WORK/cprio_delta" | sort -k4 -rn > "$WORK/cprio_events"
    if [[ -s $WORK/cprio_events ]]; then
        log "  Pause/ECN/discard/RDMA counters that rose in client phase $P (top 5 of $(wc -l < "$WORK/cprio_events" | tr -d ' ')):"
        head -n 5 "$WORK/cprio_events" | cut -d' ' -f2- | column -t | sed 's/^/#     /' >&2
    else log "  No pause/ECN/discard/RDMA counter rose in client phase $P ($(wc -l < "$post.prio" | tr -d ' ') counters read)"; fi
    local d; d=$(compute_drops "$pre" "$post" "iter${ITER}_client$P")
    if [[ -n $d ]]; then log "Drops during client phase $P:"; echo "$d" | awk '{NF--; print}' | column -t | sed 's/^/#   /' >&2; echo "$d" >> "$DROP_TOTALS"
    else log "No drop counter increases in client phase $P ($(wc -l < "$post" | tr -d ' ') NICs read)"; fi
    local flaps; flaps=$(awk -v it="iter${ITER}_client$P" 'NR == FNR {c[$1] = $6; next}
        ($1 in c) && $6 ~ /^[0-9]+$/ && c[$1] ~ /^[0-9]+$/ && $6 > c[$1] {print it, $1, $2, $6 - c[$1]}' "$pre" "$post")
    if [[ -n $flaps ]]; then
        log "WARNING: links went down during client phase $P (host_nic ip carrier-down count):"
        echo "$flaps" | cut -d' ' -f2- | column -t | sed 's/^/#   /' >&2; echo "$flaps" >> "$COLLECT_DIR/link_flaps.txt"
    fi
}

# client_udp_waves (from client_phase, on its tasks): the UDP twin U$P of client phase P, the same runs and
# waves, reusing P's path checks; UDP host and NIC counters around it, as U1/U2
client_udp_waves() {
    local U=U$P a=$WORK/cudp.$ITER.$P.pre b=$WORK/cudp.$ITER.$P.post
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"; collect_counters "$TXCTR_SCRIPT" "$a.tx"
    phase_start
    log "Client phase $U ($( [[ $dir == c2b ]] && echo "clients -> backends" || echo "backends -> clients")$( [[ $P == F? ]] && echo ", all at once"), UDP -b 0): ${#TK[@]} runs in $nw wave$( (( nw > 1 )) && echo s); start $PT0"
    for (( w = 0; w < nw; w++ )); do
        PHASE_OUT=$WORK/cphase.$ITER.$U.$w; : > "$PHASE_OUT"
        echo "### iteration:$ITER phase:$U$( (( nw > 1 )) && echo " wave:$(( w + 1 ))/$nw")" >> "$UDP_RESULTS"
        for (( t = 0; t < ${#TK[@]}; t++ )); do
            (( TW[t] == w )) && cl_run ${pfx}_$t ${TK[t]} ${TJ[t]} ${TB[t]} ${TR[t]} $dir ${TS[t]} ${TH[t]} $U udp
        done
        wait
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        lock_all touch
    done
    phase_end $U
    local errs; errs=$(cat "$WORK"/cphase.$ITER.$U.* | grep -c ",ERROR")
    (( errs > 0 )) && { log "WARNING: $errs client runs in phase $U returned no result (lines with ERROR above):"; log_hist "$WORK"/cphase.$ITER.$U.*; }
    collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"; collect_counters "$TXCTR_SCRIPT" "$b.tx"
    collect_temps "iter${ITER}_$U"
    udp_close $U "$a" "$b"
}

# clients_iter: this iteration's client phases (backends moved on by one from the last iteration)
clients_iter() {
    (( ${#CLI[@]} )) || return 0
    client_plan $ITER
    (( CL_K <= CL_K0 )) || log "WARNING: iteration $ITER plans $CL_K client flows on one backend NIC, more than the $CL_K0 servers started; the extra runs fail"
    log "---- Clients, iteration $ITER: $( (( CL_WAVES )) && echo "$CL_NW wave$( (( CL_NW > 1 )) && echo s) each way, at most $CL_R client NIC$( (( CL_R > 1 )) && echo s) per backend NIC")$( (( CL_WAVES && CL_FULL )) && echo ", then ")$( (( CL_FULL )) && echo "all at once each way") ----"
    (( CL_WAVES )) && { client_phase C1; client_phase C2; }
    (( CL_FULL )) && { client_phase F1; client_phase F2; }
    if [[ $FF_UDP == 1 ]]; then   # the UDP twins, after the TCP phases as U1/U2 follow phases 1/2
        (( CL_WAVES )) && { client_phase C1 udp; client_phase C2 udp; }
        (( CL_FULL )) && { client_phase F1 udp; client_phase F2 udp; }
    fi
    return 0
}

# NIC_SUM_AWK: one row per data NIC, backends and clients alike (Frank 10-25). Columns: Same (backend to backend,
# same rail), Cross (rail to rail), CB_Out / CB_In (client<->backend waves, this NIC sending / receiving), All_Out /
# All_In (the all-at-once phase). Each run is judged at its expected rate: its rail's line (Cross: the slower rail's),
# a client run min(client line, backend rail line / flows sharing that backend NIC). Status: each column's average
# share of expected, worst; (cross) = only Cross is that bad. Retr: TCP retransmits over the runs this NIC sent;
# Retr_%: of the segments it sent (bytes / (MTU - 52)); (retr) when above rl (FF_RETR_PCT). A NIC with no runs shows
# its rail state (no address, link down) or no_result. Files: data NIC map (key role host nic rail line_gbps mtu
# state; key = ip, or none_<host>_<rail> without one), backend results, client results. Prints a sort key first.
NIC_SUM_AWK='
BEGIN { n = split(lines, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); L[kv[1]] = kv[2] + 0 }; N[0] = "OK"; N[1] = "SLOW"; N[2] = "CRITICAL"; nc = split(cl > 0 ? "S X CO CI FO FI" : "S X", C, " ") }   # no clients: no client columns
FNR == 1 { f++ }
f == 1 { ro[$1] = $2; ho[$1] = $3; ni[$1] = $4; ra[$1] = $5; ln[$1] = $6 + 0; mtu[$1] = $7 + 0; stt[$1] = $8; ips[++ni_n] = $1; next }
/^### / { ph = ""; for (i = 2; i <= NF; i++) if ($i ~ /^phase:/) ph = substr($i, 7); next }
{ s = $1; d = $2; g = -1; sh = 1; rx = 0; bv = 0
  for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^share:/) sh = substr($i, 7) + 0; if ($i ~ /^retransmits:/) rx = substr($i, 13) + 0
                              if ($i ~ /^[KMGT]?Bytes$/ && !bv) bv = $(i-1) * (substr($i, 1, 1) == "K" ? 1024 : substr($i, 1, 1) == "M" ? 1048576 : substr($i, 1, 1) == "G" ? 1073741824 : substr($i, 1, 1) == "T" ? 1099511627776 : 1) }
  if (g < 0 || !(s in ro) || !(d in ro)) next
  rt[s] += rx; by[s] += bv
  if (f == 2) { if (ra[s] == ra[d]) { ex = L[ra[s]]; add(s, "S", g, ex); add(d, "S", g, ex) }
                else { ex = L[ra[s]]; if (L[ra[d]] < ex) ex = L[ra[d]]; add(s, "X", g, ex); add(d, "X", g, ex) }; next }
  c = (ro[s] == "client") ? s : d; b = (c == s) ? d : s
  ex = L[ra[b]] > 0 ? L[ra[b]] / (sh > 0 ? sh : 1) : 0; if (ln[c] > 0 && (ex == 0 || ln[c] < ex)) ex = ln[c]
  p = (ph ~ /^F/) ? "F" : "C"; add(s, p "O", g, ex); add(d, p "I", g, ex) }
function add(ip, col, g, ex) { sum[ip, col] += g; cnt[ip, col]++; if (ex > 0) { pct[ip, col] += 100 * g / ex; pc[ip, col]++; if (!((ip) in mx) || ex < mx[ip]) mx[ip] = ex } }
END {
    print "0 0 Role Host NIC IP Same Cross" (cl > 0 ? " CB_Out CB_In All_Out All_In" : "") " Retr Retr_% Expect Status"
    for (k = 1; k <= ni_n; k++) { ip = ips[k]; w = -1; wn = -1; lo = 1e9; o = ""; any = 0
        for (j = 1; j <= nc; j++) { col = C[j]
            if (!cnt[ip, col]) { o = o " -"; continue }
            any = 1; o = o sprintf(" %.1f", sum[ip, col] / cnt[ip, col])
            if (pc[ip, col]) { pv = pct[ip, col] / pc[ip, col]; if (pv < lo) lo = pv; lv = pv >= ok ? 0 : (pv >= slow ? 1 : 2)
                               if (lv > w) w = lv; if (col != "X" && lv > wn) wn = lv } }
        sg = by[ip] / (mtu[ip] > 52 ? mtu[ip] - 52 : 1448); rp = sg > 0 ? 100 * rt[ip] / sg : 0
        st = !any ? (stt[ip] != "" && stt[ip] != "ok" ? stt[ip] : "no_result") : (w < 0 ? "-" : N[w] (wn >= 0 && w > wn ? "(cross)" : "")) (any && rp > rl ? "(retr)" : "")
        printf "%d %.1f %s %s %s %s%s %d %s %s %s\n", (!any ? 7 : (w < 0 ? -1 : 2 * w + (rp > rl))), (lo < 1e9 ? lo : 0), ro[ip], ho[ip], ni[ip], (ip ~ /^none_/ ? "-" : ip), o, rt[ip],
               (sg > 0 ? sprintf("%.3f", rp) : "-"), (ip in mx ? sprintf("%g", mx[ip]) : "-"), st } }'

# client_summary: per client data NIC, its runs each way judged at min(client line, backend rail line / share)
# Files: client map (ip host nic line_gbps), rail map (ip host rail), client results.
CLIENT_SUM_AWK='
BEGIN { n = split(lines, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); L[kv[1]] = kv[2] + 0 }; N[0] = "OK"; N[1] = "SLOW"; N[2] = "CRITICAL" }
FNR == 1 { f++ }
f == 1 { ch[$1] = $2; cn[$1] = $3; cl[$1] = $4 + 0; next }
f == 2 { br[$1] = $3; next }
/^### / { ph = ""; it = ""; for (i = 2; i <= NF; i++) { if ($i ~ /^phase:/) ph = substr($i, 7); if ($i ~ /^iteration:/) it = substr($i, 11) }; next }
{ s = $1; d = $2; g = -1; sh = 1; rx = 0
  for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^share:/) sh = substr($i, 7) + 0; if ($i ~ /^retransmits:/) rx = substr($i, 13) + 0 }
  if (g < 0) next
  c = (s in ch) ? s : d; b = (s in ch) ? d : s; if (!(c in ch) || !(b in br)) next
  lb = L[br[b]]; lc = cl[c]; ex = lb > 0 ? lb / (sh > 0 ? sh : 1) : 0; if (lc > 0 && (ex == 0 || lc < ex)) ex = lc
  col = (ph ~ /^F/) ? "F" : "C"; col = col ((s in ch) ? "o" : "i")
  sum[c, col] += g; cnt[c, col]++; if (ex > 0) { pct[c, col] += 100 * g / ex; pc[c, col]++ }
  if (!((c, "x") in mx) || ex < mx[c, "x"]) mx[c, "x"] = ex; seen[c] = 1
  if (s in ch) rt[c] += rx
  if (ph ~ /^F/) { ft[ph, it] += g; fn[ph, it]++ } }
END {
    print "Client NIC IP C->B B->C All_C->B All_B->C Retr Expect Status"
    for (c in seen) { w = -1; o = ""
        for (k = 1; k <= 4; k++) { col = substr("CoCiFoFi", 2 * k - 1, 2)
            if (!cnt[c, col]) { o = o " -"; continue }
            o = o sprintf(" %.1f", sum[c, col] / cnt[c, col])
            if (pc[c, col]) { p = pct[c, col] / pc[c, col]; lv = p >= ok ? 0 : (p >= slow ? 1 : 2); if (lv > w) w = lv } }
        printf "%s %s %s%s %d %s %s\n", ch[c], cn[c], c, o, rt[c], (mx[c, "x"] > 0 ? sprintf("%g", mx[c, "x"]) : "-"), (w < 0 ? "-" : N[w]) }
    # all at once: per iteration, then the average and the lowest over the iterations
    for (x in ft) { split(x, y, SUBSEP); p = y[1]; ni[p]++; ts[p] += ft[x]; nf[p] = fn[x]; if (!(p in lo) || ft[x] < lo[p]) lo[p] = ft[x] }
    for (p in ni) printf "#TOTAL %s %d %.1f %.1f %d\n", p, nf[p], ts[p] / ni[p], lo[p], ni[p] }'

# fec_deltas label seconds: per-NIC FEC counter changes over the iteration, appended to
# fec_rates.txt as "label host_nic seconds d_corrected_blocks d_uncorrectable_blocks d_corrected_bits d_symbol_errors"
# (na = not exposed, reset = counter went backwards). Links carry symbols even when idle, so wall time is the right base.
fec_deltas() {
    awk -v t="$1" -v s="$2" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
        ($1, 2) in p {printf "%s %s %d", t, $1, s
            for (i = 2; i <= 5; i++) printf " %s", ($i ~ /^[0-9]+$/ && p[$1, i] ~ /^[0-9]+$/) ? ($i + 0 >= p[$1, i] + 0 ? $i - p[$1, i] : "reset") : ($i == "off" ? "off" : "na")
            print ""}' "$WORK/fec_pre" "$WORK/fec_post" > "$WORK/fec_delta"
    cat "$WORK/fec_delta" >> "$COLLECT_DIR/fec_rates.txt"
    local seen unc off
    seen=$(awk '$4 ~ /^[0-9]+$/ || $6 ~ /^[0-9]+$/' "$WORK/fec_delta" | wc -l | tr -d ' ')
    off=$(awk '$4 == "off"' "$WORK/fec_delta" | wc -l | tr -d ' ')
    unc=$(awk '$5 ~ /^[0-9]+$/ && $5 > 0 {printf "%s(%s) ", $2, $5}' "$WORK/fec_delta")
    log "FEC over ${2}s: counters exposed on $seen of $(wc -l < "$WORK/fec_delta" | tr -d ' ') rail NICs$( (( off )) && echo "; FEC off on $off")"
    [[ -n $unc ]] && log "WARNING: uncorrectable FEC blocks (errors reach the host): $unc"
    return 0
}

collect_drops() {  # outfile [k...]
    local outfile=$1 k; shift
    local -a ks=("$@"); (( ${#ks[@]} )) || ks=("${ELIG[@]}" "${CLI[@]}")
    : > "$outfile"
    for k in "${ks[@]}"; do
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$DROPS_SCRIPT" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
    sort -o "$outfile" "$outfile"
}

compute_drops() {
    awk -v label="$3" '
        NR==FNR { pre[$1]=$3" "$4" "$5; next }
        ($1 in pre) {
            split(pre[$1], p, " ")
            drx = ($3 ~ /^[0-9]+$/ && p[1] ~ /^[0-9]+$/) ? $3 - p[1] : 0
            dtx = ($4 ~ /^[0-9]+$/ && p[2] ~ /^[0-9]+$/) ? $4 - p[2] : 0
            doob = ($5 ~ /^[0-9]+$/ && p[3] ~ /^[0-9]+$/) ? $5 - p[3] : 0
            if (drx > 0 || dtx > 0 || doob > 0)
                printf "%s %s %s rx_drop:%d tx_drop:%d rx_oob:%d %s\n", $1, $2, label, drx, dtx, doob, label
        }' "$1" "$2"
}

stop_servers() {
    (( ${#STARTED[@]} > 0 )) || return 0
    local k
    log "Stopping iperf3 on ${#STARTED[@]} hosts..."
    for k in "${!STARTED[@]}"; do
        local t=${T_TARGET[$k]}
        if [[ ${TESC[$t]-} == S && -z ${TPW[$t]+x} ]]; then   # the cleanup after a crash: no password in the state file
            log "iperf3 on $t not stopped: its sudo needs the -t password, which is never saved; stop it by hand"; continue
        fi
        rroot "$t" pkill -x iperf3 >> "$WORK/cleanup.log" 2>&1 &
    done
    wait
    STARTED=()
}

# cleanup's inputs, so the wrapper can finish cleanup when main dies without it: SIGKILL, OOM, or (seen 1 in ~76
# Ctrl-C runs under load) bash running the INT trap's exit but never the EXIT trap. Written whole, then renamed.
save_state() {
    [[ -n $STATE_FILE ]] || return 0
    declare -p WORK SOCKET_DIR COLLECT_DIR LOADED DONE LOCKED RUN_ID STARTED T_TARGET REACH_ONLY ELIG CLI SSH_OPTS \
        FF_SSH_USER TL TESC 2>&1 | grep '^declare ' > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

cleanup() {
    local rc=$? k   # first: bash 5.1 would otherwise end a piped main with cleanup's last status
    trap '' INT TERM HUP PIPE   # nothing may cut cleanup short: a second signal, or a dead tee (EPIPE, not death)
    stop_servers
    [[ -n $LOCKED ]] && lock_all release
    for k in "${T_TARGET[@]}" "${!REACH_ONLY[@]}"; do
        ssh -O exit -o "ControlPath=$SOCKET_DIR/%C" -l "${TL[$k]:-$FF_SSH_USER}" "$k" >> "$WORK/cleanup.log" 2>&1 &
    done
    wait
    if [[ -z $DONE ]]; then
        if [[ -n $LOADED ]]; then { [[ -f $FF_RUNLOG ]] && cp "$FF_RUNLOG" "$COLLECT_DIR/run.log"; log "Run did not finish; partial data left in $COLLECT_DIR"; }
        else rm -rf "${COLLECT_DIR:?}"; fi
    fi
    rm -rf "${SOCKET_DIR:?}" "${WORK:?}"
    [[ -z $STATE_FILE ]] || rm -f "$STATE_FILE"   # last: the wrapper reruns a cleanup cut short
    exit $rc
}

# FF_KNOWN, every FF_* setting this tool reads, is in hostfile.sh (shared with thermals_capture.sh).
# write_targets_template path: hostlist.example.csv, written by ./build from this script's own usage text so the
# example and the help never drift: the row rules and example rows, then every documented FF_ setting at its
# default under its help, as comments (FF_HOSTS and FF_CLIENTS are rows in this file, not settings). A default
# is the first "(N)", "(all)" or "(none)" in the setting's help; an "=1" (or "=0") switch defaults to the other value.
write_targets_template() {
    local p=$1
    { cat <<'EOF'
# hostlist.example.csv: a target file for fabric_ferret.sh -t and thermals_capture.sh -t (the same format).
# Copy it, keep the rows you need, and chmod 600 it when a row holds a password.
#
# Row format: <type>,<host>,<login>,<pw>
#   type   backend (or host) and client: ssh targets; bmc: one BMC address, read out of band (fabric_ferret.sh
#          skips bmc rows and says how many). A bare line (no comma) is a backend with the defaults, so a plain
#          host list works as it is. Type * means backend and client, never bmc.
#   host   an IP, hostname, CIDR or range (as FF_HOSTS); a bmc takes one IP or hostname. A host of * or a glob
#          (* ? [...], any case) makes a credential row: it adds no targets and needs a login or a password.
#          A row whose host field is empty or starts with # is skipped ("host,# ..." comments a row out).
#   login  the ssh login (a bmc: its user); empty = FF_SSH_USER, by default the user running the tool.
#   pw     everything after the third comma, verbatim; empty = key (passwordless) ssh, or an empty BMC password.
# Each target takes the most specific row that gives a login or a password: the row naming the one host, then a
# CIDR or range, then a glob, then <type>,*, then *,*. That row is its credential; there is no fallback to a less
# specific one. Passwords never appear on a command line, in an environment variable or in any output.
#
# Targets
backend,10.20.1.0/28
backend,10.20.1.16-23
backend,storage-09,svc-fabric
client,10.20.2.0/26
client,gpu-node-01
client,gpu-node-02
bmc,10.20.100.11
# Credential rows: the login (and password, if any) for every target a more specific row does not cover
backend,*,svc-fabric
*,gpu-node-*,admin
#
# Settings: a line FF_<setting>=value (the whole line; the value verbatim, commas and all) sets that setting for the
# run, for both tools. A setting exported in the environment wins over the file; the other tool's names are
# skipped and named in one log line; an unknown name, or one that looks like a credential, stops the run with its
# line number. Below, every fabric_ferret.sh setting at its default under its help (from --help; empty = none):
EOF
      usage | awk '
        function flush(   i, k, nn) {
            if (cur == "") return
            if (match(txt, / \(([0-9.]+|all|none)[;)]/)) def = substr(txt, RSTART + 2, RLENGTH - 3)
            if (def == "" && flag != "") def = flag
            printf "%s", buf; k = split(cur, nn, " "); for (i = 1; i <= k; i++) print "# " nn[i] "=" def; print "#"
            cur = "" }
        /^Result:/ { flush(); exit }
        /^  FF_[A-Z0-9_]+/ { flush(); line = $0; sub(/^  /, "", line)
            n = split(line, w, /[ ,=(]+/); names = ""
            for (i = 1; i <= n && w[i] ~ /^FF_[A-Z0-9_]+$/; i++) names = names (names == "" ? "" : " ") w[i]
            if (names == "FF_HOSTS" || names == "FF_CLIENTS") next
            flag = ""; if (match(line, /^FF_[A-Z0-9_]+=[01] /)) flag = (substr(line, RLENGTH - 1, 1) == "1") ? "0" : "1"
            help = line; sub(/^FF_[A-Z0-9_]+(, FF_[A-Z0-9_]+)*(=[A-Za-z0-9]+)? */, "", help); sub(/^\([0-9]+\) +/, "", help)
            cur = names; def = ""; txt = line; buf = "#   " help "\n"; next }
        cur != "" && /^            / { h = $0; sub(/^ +/, "", h); txt = txt " " h; buf = buf "#   " h "\n"; next }
        cur != "" { flush() }
        /^$/ { next }
        END { flush() }'
    } > "$p"
}

# edit_distance a b: Levenshtein distance, for the "did you mean" hint
edit_distance() {
    local a=$1 b=$2 i j c x y z; local -a p q
    for (( j = 0; j <= ${#b}; j++ )); do p[j]=$j; done
    for (( i = 1; i <= ${#a}; i++ )); do
        q=($i)
        for (( j = 1; j <= ${#b}; j++ )); do
            [[ ${a:i-1:1} == "${b:j-1:1}" ]] && c=0 || c=1
            x=$(( p[j] + 1 )); y=$(( q[j-1] + 1 )); z=$(( p[j-1] + c ))
            q[j]=$(( x < y ? (x < z ? x : z) : (y < z ? y : z) ))
        done
        p=("${q[@]}")
    done
    echo "${p[${#b}]}"
}

check_settings() {
    local v k d best bd
    for v in $(compgen -e); do
        # the tool was fabric_sleuth; its FS_ settings would otherwise be silently ignored
        [[ $v == FS_* ]] && die "setting $v uses the old FS_ prefix; settings are now FF_ (${v/#FS_/FF_})"
        [[ $v == FF_RAIL_A || $v == FF_RAIL_B ]] && die "$v is gone: give every rail in FF_RAILS, ';' between rails and ',' between a rail's subnets, e.g. FF_RAILS='10.20.1.0/24,10.20.3.0/24;10.20.2.0/24'"
        [[ $v == FF_* &&" $FF_KNOWN " != *" $v "* ]] || continue
        best=; bd=99
        for k in $FF_KNOWN; do d=$(edit_distance "$v" "$k"); (( d < bd )) && { bd=$d; best=$k; }; done
        (( bd == 1 || bd <= (${#v} - 3) / 3 )) && die "unknown setting $v; did you mean $best?"
        die "unknown setting $v; this tool reads: ${FF_KNOWN// /, }"
    done
}

# ======================================================================

main() {
    [[ $1 == -h || $1 == --help ]] && { usage; exit 0; }
    check_settings
    # the FF_ names the environment set, before any default: a -t file's settings lines never override them
    HF_ENV=" $(compgen -e | awk '/^FF_/ {printf "%s ", $0}')"; HF_KNOWN=$FF_KNOWN; HF_OTHER=$TC_KNOWN; HF_OTHER_NAME=thermals_capture.sh

    : "${FF_ITER:=3}" "${FF_STREAMS:=16}" "${FF_PORT:=5201}" "${FF_SSH_USER:=$(id -un)}"
    : "${FF_SSH_PARALLEL:=64}" "${FF_SSH_RETRY_PARALLEL:=8}" "${FF_MAX_TARGETS:=4096}" "${FF_OUT_DIR:=.}"
    : "${FF_OK_PCT:=75}" "${FF_SLOW_PCT:=50}" "${FF_BUSY_OK:=0}" "${FF_SYSINFO_TIMEOUT:=300}" "${FF_RETR_PCT:=0.1}"
    : "${FF_TEMPS:=1}" "${FF_IPMI:=1}" "${FF_TEMP_MARGIN:=5}" "${FF_TEMP_RISE:=10}" "${FF_IPMI_TIMEOUT:=60}"
    # Default busy check: any WEKA container in STATE Running (docs.weka.io CLI reference, `weka local ps`)
    : "${FF_BUSY_CHECK:=$WEKA_BUSY_CHECK}"
    # arguments, any order: --list, -t FILE, one duration (whole seconds); anything else is refused
    local list=0 tfile= dur=
    while (( $# )); do
        case $1 in
            --list) list=1; shift ;;
            -t) (( $# >= 2 )) || die "-t needs a file (--help)"; tfile=$2; shift 2 ;;
            -t?*) tfile=${1#-t}; shift ;;
            *) [[ -z $dur && $1 =~ ^[0-9]+$ ]] || die "unexpected argument '$1' (arguments: [-t FILE] [--list] [duration_s]; --help)"
               dur=$1; shift ;;
        esac
    done
    [[ -n $dur ]] && { FF_DURATION=$dur; HF_ENV+="FF_DURATION "; }   # the argument beats a -t file's FF_DURATION line
    : "${FF_DURATION:=120}" "${FF_MESH:=1}" "${FF_SKIP_IPERF:=0}"
    # -t FILE (the format thermals_capture.sh reads): backend and client rows, each with its own credentials (TL login,
    # TPW password: memory only), keyed by target; credential rows (* and globs) as hostfile.sh resolves them
    local -a TF_BE=() TF_CL=(); declare -gA TL=() TPW=()
    if [[ -n $tfile ]]; then
        [[ -n $FF_HOSTS$FF_CLIENTS ]] && die "use FF_HOSTS/FF_CLIENTS or -t <file>, not both (unset them to use the file)"
        declare -ga T_LOGIN=() T_PW=() T_TYPE=() T_LINE=() T_FROM=() T_ROW=() BMCS=() B_LOGIN=() B_PW=() B_LINE=() B_ROW=()
        TARGETS=(); _SEEN=(); INPUT_RANGES=0; HAVE_PW=0
        load_target_file "$tfile" "$FF_SSH_USER"
        local k
        for k in "${!TARGETS[@]}"; do
            TL[${TARGETS[$k]}]=${T_LOGIN[$k]}; [[ -n ${T_PW[$k]+x} ]] && TPW[${TARGETS[$k]}]=${T_PW[$k]}
            if [[ ${T_TYPE[$k]} == client ]]; then TF_CL+=("${TARGETS[$k]}"); else TF_BE+=("${TARGETS[$k]}"); fi
        done
        (( ${#BMCS[@]} )) && log "-t: ${#BMCS[@]} bmc line(s) skipped (fabric_ferret.sh reads no BMC)"
        (( ${#TF_BE[@]} )) || die "-t $tfile has no backend targets"
    fi
    # settings are checked here, after a -t file's settings lines have had their say
    [[ $FF_SSH_USER =~ ^[A-Za-z0-9._@-]+$ ]] || die "FF_SSH_USER: bad login (letters, digits . _ @ - only)"
    [[ $FF_RETR_PCT =~ ^([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] || die "FF_RETR_PCT must be a number (% of TCP segments sent), got '$FF_RETR_PCT'"
    [[ $FF_TEMPS == 0 || $FF_TEMPS == 1 ]] || die "FF_TEMPS must be 0 or 1, got '$FF_TEMPS'"
    [[ $FF_IPMI == 0 || $FF_IPMI == 1 ]] || die "FF_IPMI must be 0 or 1, got '$FF_IPMI'"
    local tv; for tv in FF_TEMP_MARGIN FF_TEMP_RISE FF_IPMI_TIMEOUT; do
        [[ ${!tv} =~ ^[0-9]+$ ]] || die "$tv must be a whole number, got '${!tv}'"
    done
    [[ $FF_BUSY_CHECK == none ]] && FF_BUSY_CHECK=""
    [[ -z $FF_UDP ]] && FF_UDP=$(( ! FF_SKIP_IPERF ))   # UDP by default, except with no load
    : "${FF_UDP_DURATION:=$FF_DURATION}"
    [[ $FF_UDP == 0 || $FF_UDP == 1 ]] || die "FF_UDP must be 0 or 1, got '$FF_UDP'"
    [[ $FF_MESH == 0 || $FF_MESH == 1 ]] || die "FF_MESH must be 0 or 1, got '$FF_MESH'"
    [[ $FF_SKIP_IPERF == 0 || $FF_SKIP_IPERF == 1 ]] || die "FF_SKIP_IPERF must be 0 or 1, got '$FF_SKIP_IPERF'"
    (( FF_SKIP_IPERF && FF_UDP == 1 )) && die "FF_UDP=1 is a load test; FF_SKIP_IPERF=1 sends no load: set one of them"
    [[ -z $FF_CROSS_RAIL || $FF_CROSS_RAIL == 0 || $FF_CROSS_RAIL == 1 ]] || die "FF_CROSS_RAIL must be 0 or 1, got '$FF_CROSS_RAIL'"
    [[ -z $FF_CROSS_RAIL ]] && FF_CROSS_RAIL=1
    ITER_ALL=0; [[ $FF_ITER == all ]] && { ITER_ALL=1; FF_ITER=1; }   # 2 x the pairing rounds, set once the hosts are known
    [[ -z $FF_CROSS_MAX || $FF_CROSS_MAX =~ ^[1-9][0-9]*$ ]] || die "FF_CROSS_MAX must be a positive integer (cross-rail flows at once), got '$FF_CROSS_MAX'"
    local v
    for v in FF_DURATION FF_UDP_DURATION FF_SYSINFO_TIMEOUT FF_ITER FF_STREAMS FF_PORT FF_SSH_PARALLEL FF_SSH_RETRY_PARALLEL FF_MAX_TARGETS FF_OK_PCT FF_SLOW_PCT; do
        [[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v must be a positive integer, got '${!v}'"
    done
    (( FF_STREAMS >= 2 )) || die "FF_STREAMS must be >= 2 (iperf3 prints no [SUM] line for one stream)"
    [[ -z $FF_LINE_GBPS || $FF_LINE_GBPS =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || die "FF_LINE_GBPS must be an integer (every rail) or one integer per rail (A,B,...), got '$FF_LINE_GBPS'"
    # declared uplinks: all three or none, and no default speed (a guess could pass a fault)
    local sv smiss=; UPLINK_GBPS=0
    for sv in FF_SPINES FF_SPINE_LINKS FF_SPINE_GBPS; do
        if [[ -z ${!sv} ]]; then smiss+=" $sv"
        elif ! [[ ${!sv} =~ ^[1-9][0-9]*$ ]]; then die "$sv must be a positive integer, got '${!sv}'"; fi
    done
    if [[ -z $smiss ]]; then UPLINK_GBPS=$(( FF_SPINES * FF_SPINE_LINKS * FF_SPINE_GBPS ))
    elif [[ $smiss != " FF_SPINES FF_SPINE_LINKS FF_SPINE_GBPS" ]]; then die "FF_SPINES, FF_SPINE_LINKS and FF_SPINE_GBPS go together; missing:$smiss"; fi
    # client leaf uplinks: both or neither, on the same spines
    CL_UPLINK_GBPS=0
    for sv in FF_CLIENT_SPINE_LINKS FF_CLIENT_SPINE_GBPS; do
        [[ -z ${!sv} || ${!sv} =~ ^[1-9][0-9]*$ ]] || die "$sv must be a positive integer, got '${!sv}'"
    done
    if [[ -n $FF_CLIENT_SPINE_LINKS$FF_CLIENT_SPINE_GBPS ]]; then
        [[ -n $FF_CLIENT_SPINE_LINKS && -n $FF_CLIENT_SPINE_GBPS ]] || die "FF_CLIENT_SPINE_LINKS and FF_CLIENT_SPINE_GBPS go together; missing: $([[ -z $FF_CLIENT_SPINE_LINKS ]] && echo FF_CLIENT_SPINE_LINKS || echo FF_CLIENT_SPINE_GBPS)"
        [[ -n $FF_SPINES ]] || die "FF_CLIENT_SPINE_LINKS and FF_CLIENT_SPINE_GBPS need FF_SPINES (one spine layer serves clients and backends)"
        CL_UPLINK_GBPS=$(( FF_SPINES * FF_CLIENT_SPINE_LINKS * FF_CLIENT_SPINE_GBPS ))
    fi
    [[ -z $FF_EXPECT_HOSTS || $FF_EXPECT_HOSTS =~ ^[1-9][0-9]*$ ]] || die "FF_EXPECT_HOSTS must be a positive integer"
    [[ -z $FF_TOS || ( $FF_TOS =~ ^[0-9]{1,3}$ && 10#$FF_TOS -le 255 ) ]] || die "FF_TOS must be 0-255 (decimal), got '$FF_TOS'"
    [[ -n $FF_TOS ]] && FF_TOS=$(( 10#$FF_TOS ))

    parse_rails; parse_clients
    if [[ -n $FF_LINE_GBPS && $FF_LINE_GBPS == *,* ]]; then
        local nl; IFS=, read -r -a nl <<<"$FF_LINE_GBPS"
        (( NR == 0 || ${#nl[@]} == NR )) || die "FF_LINE_GBPS has ${#nl[@]} values for $NR rails: give one for every rail, or one per rail"
    fi
    # clients first, so a target in both lists is caught; TARGETS = hosts, then clients (index >= NHT)
    local -a CL_T=(); CL_RANGES=0
    if [[ -n $tfile ]]; then   # a range per type: a backend range never makes a dead client look normal
        TARGETS=("${TF_BE[@]}"); CL_T=("${TF_CL[@]}"); INPUT_RANGES=${HF_RANGES[backend]}; CL_RANGES=${HF_RANGES[client]}
    else
        if [[ -n $FF_CLIENTS ]]; then expand_targets "$FF_CLIENTS" FF_CLIENTS; CL_T=("${TARGETS[@]}"); CL_RANGES=$INPUT_RANGES; fi
        expand_targets "$FF_HOSTS"
    fi
    NHT=${#TARGETS[@]}
    if (( ${#CL_T[@]} )) && [[ -z $tfile ]]; then
        local t; for t in "${CL_T[@]}"; do [[ -n ${_SEEN[$t]+x} ]] && die "target $t is in both FF_HOSTS and FF_CLIENTS"; done
    fi
    if (( list )); then
        printf '%s\n' "${TARGETS[@]}"; log "${#TARGETS[@]} targets"
        (( ${#CL_T[@]} )) && { printf 'client %s\n' "${CL_T[@]}"; log "${#CL_T[@]} client targets"; }
        exit 0
    fi
    TARGETS+=("${CL_T[@]}")
    local t; for t in "${TARGETS[@]}"; do [[ -n ${TL[$t]} ]] || TL[$t]=$FF_SSH_USER; done   # FF_HOSTS/FF_CLIENTS: FF_SSH_USER

    local c
    for c in ssh timeout column sort awk tar; do [[ -n $(command -v $c) ]] || die "'$c' not found on this machine"; done
    [[ -d $FF_OUT_DIR && -w $FF_OUT_DIR ]] || die "FF_OUT_DIR '$FF_OUT_DIR' is not a writable directory"
    # a password login (a -t row's pw): read once, where its ssh master opens (the sweep), through the askpass helper from a
    # one-use fifo; never in an environment variable, argv or the state file. pw_transport (auth.sh): OpenSSH 8.4+, else setsid.
    SETSID=; (( ${#TPW[@]} )) && pw_transport

    WORK=$(mktemp -d /tmp/ff_work.XXXXXX)
    AUTH=$WORK/auth; mkdir -m 700 "$AUTH" || die "mkdir $AUTH failed"; (( ${#TPW[@]} )) && write_askpass "$AUTH/askpass"
    SOCKET_DIR=$(mktemp -d /tmp/ff_ssh.XXXXXX)
    COLLECT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dp_validation_XXXXXX")
    RAW_DIR=$COLLECT_DIR/raw_per_host; mkdir -p "$RAW_DIR" "$WORK/disc" "$WORK/sweep"
    SI=$COLLECT_DIR/sysinfo
    RUNLOG_SSH=$COLLECT_DIR/ssh_errors.log

    declare -gA TESC=()   # per target: how remote steps get root (the sweep's probe; rbash)
    # the sudo -S stream's sentinel (ff_remote.sh): random per run, never a secret; printed nowhere
    SENTINEL=ff-$(od -An -N8 -tx1 /dev/urandom 2>&1 | tr -dc 'a-f0-9'); [[ ${#SENTINEL} -ge 10 ]] || SENTINEL=ff-$RANDOM$RANDOM$RANDOM
    SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=15m -o "ControlPath=$SOCKET_DIR/%C"
              -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5
              -o ServerAliveInterval=15)   # the login is per target (TL, rsh/rbash)
    declare -gA T_TARGET T_HOST DISC RNIC RIP RMTU RSTATE STARTED REACH_ONLY DOWN_IP SI_CUT
    declare -gA IS_CL CN CNIC CIP CMTU CSTATE   # clients: k -> 1, data NIC count; (k,j) -> NIC, IP, MTU, state
    declare -ga RAIL_MTU=()   # per rail: highest MTU among its usable hosts
    trap cleanup EXIT
    # explicit exits so the EXIT trap always runs on Ctrl-C or kill, whatever command was running
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    trap '' PIPE   # a dead log tee must not abort the run: log writes just fail, results go to files
    local rails_desc="none" r
    if (( NR )); then rails_desc="$RAIL_MODE"; for r in "${RAILS[@]}"; do rails_desc+=" $(rail_letter $r)=${RAIL_SPEC[r]// /,}"; done; fi
    log "Begin $(date) | $NHT targets$( (( ${#CL_T[@]} )) && echo " + ${#CL_T[@]} client targets") | rails: $rails_desc | ${FF_DURATION}s x $( (( ITER_ALL )) && echo "all (2 x pairing rounds$( (( NR > 2 )) && echo " x rail pairs"))" || echo $FF_ITER) iterations$([[ -n $FF_CROSS_MAX ]] && echo " | cross-rail at most $FF_CROSS_MAX flows at once")"
    log "Temp: $WORK $SOCKET_DIR $COLLECT_DIR $FF_RUNLOG $STATE_FILE (all removed at the end; the collect dir is kept if a run is cut short)"
    save_state

    # --- 1. reachability sweep (capped) ---
    local i t
    log "Sweeping ${#TARGETS[@]} targets over ssh, $FF_SSH_PARALLEL at a time..."
    for i in "${!TARGETS[@]}"; do
        throttle
        t=${TARGETS[$i]}
        ( if sweep_probe "$t" > "$WORK/sweep/$i.priv" 2> "$WORK/sweep/$i.err"; then echo "$i" > "$WORK/sweep/$i.ok"; fi ) &
    done
    wait
    # refusals under fan-out (sshd MaxStartups, kex resets) look like dead hosts: retry those slower
    local -a retry=()
    for i in "${!TARGETS[@]}"; do
        [[ -f $WORK/sweep/$i.ok ]] && continue
        grep -q -i -E 'connection reset|kex_exchange_identification|ssh_exchange_identification|connection closed by|too many' \
            "$WORK/sweep/$i.err" && retry+=("$i")
    done
    if (( ${#retry[@]} )); then
        log "Retrying ${#retry[@]} targets that refused under load, $FF_SSH_RETRY_PARALLEL at a time..."
        local attempt keep=$FF_SSH_PARALLEL; FF_SSH_PARALLEL=$FF_SSH_RETRY_PARALLEL
        for attempt in 1 2; do
            for i in "${retry[@]}"; do
                [[ -f $WORK/sweep/$i.ok ]] && continue
                throttle; t=${TARGETS[$i]}
                ( if sweep_probe "$t" > "$WORK/sweep/$i.priv" 2> "$WORK/sweep/$i.err"; then echo "$i" > "$WORK/sweep/$i.ok"; fi ) &
            done
            wait; sleep 1
        done
        FF_SSH_PARALLEL=$keep
        local rec=0; for i in "${retry[@]}"; do [[ -f $WORK/sweep/$i.ok ]] && rec=$(( rec + 1 )); done
        log "Retry recovered $rec of ${#retry[@]}"
    fi
    local -a REACH=(); local pu pe; NUNUSE_B=0; NUNUSE_C=0
    for i in "${!TARGETS[@]}"; do
        if [[ -f $WORK/sweep/$i.ok ]]; then
            # root: none needed; else the escalator the probe found; else a -t password: sudo -S; else unusable for the
            # remote steps (reported, out of the run, counted against coverage)
            read -r pu pe < <(tail -n 1 "$WORK/sweep/$i.priv"); t=${TARGETS[$i]}
            if [[ $pu == 0 ]]; then TESC[$t]=
            elif [[ -n $pe && $pe != none && $pe != - ]]; then TESC[$t]=${pe//_/ }
            elif [[ -n ${TPW[$t]+x} ]]; then TESC[$t]=S
            else
                echo "$t no_passwordless_escalator_dzdo_pbrun_sesu_pmrun_doas_ksu_sudo (login ${TL[$t]}, uid ${pu:-unknown})" >> "$WORK/unusable.txt"
                (( i < NHT )) && NUNUSE_B=$(( NUNUSE_B + 1 )) || NUNUSE_C=$(( NUNUSE_C + 1 )); continue
            fi
            REACH+=("$i")
        else
            local why; why=$(grep -v '^Warning: Permanently added' "$WORK/sweep/$i.err" | tail -n1)
            echo "${TARGETS[$i]} ${why:-no error text}" >> "$WORK/unreachable.txt"
        fi
    done
    if [[ -s $WORK/unreachable.txt ]]; then
        log "$(wc -l < "$WORK/unreachable.txt" | tr -d ' ') of ${#TARGETS[@]} targets unreachable, by reason:"
        awk '{$1=""; sub(/^ /,""); sub(/^ssh: connect to host [^ ]+ port [0-9]+: /,""); print}' "$WORK/unreachable.txt" \
            | sort | uniq -c | sort -rn | sed 's/^/#   /' >&2
        cp "$WORK/unreachable.txt" "$COLLECT_DIR/unreachable.txt"
    fi
    if [[ -s $WORK/unusable.txt ]]; then
        log "$(wc -l < "$WORK/unusable.txt" | tr -d ' ') of ${#TARGETS[@]} targets answered ssh but can't run the remote steps as root (left out, counted as missing):"
        sed 's/^/#   /' "$WORK/unusable.txt" >&2
        cp "$WORK/unusable.txt" "$COLLECT_DIR/unusable.txt"
    fi
    save_state
    (( ${#REACH[@]} > 0 )) || die "no target answered ssh (logins tried: $(printf '%s\n' "${TL[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//'))"

    # --- 2. discovery ---
    log "Discovering ${#REACH[@]} hosts..."
    for i in "${REACH[@]}"; do
        throttle
        rbash "${TARGETS[$i]}" <<<"BUSY_CHECK=$(printf '%q' "$FF_BUSY_CHECK")"$'\n'"$DISCOVER_SCRIPT" \
            > "$WORK/disc/$i" 2>> "$RUNLOG_SSH" &
    done
    wait

    # dedupe: the same host can answer on several targets (mgmt and data IPs in one CIDR)
    local -A SEEN_ID=() SEEN_CL=()
    local k=0 id host dups=0 cdups=0 iscl
    for i in "${REACH[@]}"; do
        host=$(section "$WORK/disc/$i" hostname | head -n1)
        [[ -n $host ]] || { echo "${TARGETS[$i]} discovery returned nothing" >> "$COLLECT_DIR/unreachable.txt"; continue; }
        id=$(section "$WORK/disc/$i" machine-id | head -n1)
        [[ $id =~ ^[0-9a-f]{32}$ ]] || id=$host
        iscl=; (( i >= NHT )) && iscl=1
        if [[ -n ${SEEN_ID[$id]+x} ]]; then
            [[ ${SEEN_CL[$id]} == "$iscl" ]] || die "host ${SEEN_ID[$id]} is in both FF_HOSTS and FF_CLIENTS (target ${TARGETS[$i]}); a host is a backend or a client, not both"
            dups=$(( dups + 1 )); REACH_ONLY[${TARGETS[$i]}]=1; [[ -n $iscl ]] && cdups=$(( cdups + 1 ))
            echo "${TARGETS[$i]} same host as ${SEEN_ID[$id]}" >> "$COLLECT_DIR/excluded.txt"
            continue
        fi
        SEEN_ID[$id]=$host; SEEN_CL[$id]=$iscl
        T_TARGET[$k]=${TARGETS[$i]}; T_HOST[$k]=$host; DISC[$k]=$WORK/disc/$i
        [[ -n $iscl ]] && IS_CL[$k]=1
        k=$(( k + 1 ))
    done
    (( dups > 0 )) && log "$dups targets were a second address of a host already found; using the first"
    local -a BK=() CK=()   # backends, clients (k)
    for k in "${!T_TARGET[@]}"; do if [[ -n ${IS_CL[$k]} ]]; then CK+=("$k"); else BK+=("$k"); fi; done

    if [[ $RAIL_MODE == none ]]; then
        log "No rail subnets or NIC names set. IPv4 subnets on the reachable hosts (hosts, NIC, subnet):"
        list_subnets "${BK[@]}"
        die "set FF_RAILS (each rail's subnets, ';' between rails) or FF_NICS (one NIC name per rail)"
    fi
    if [[ $CLIENT_MODE == list ]]; then
        log "FF_CLIENTS set without FF_CLIENT_NETS or FF_CLIENT_NICS. IPv4 subnets on the reachable clients (clients, NIC, subnet):"
        list_subnets "${CK[@]}"
        die "set FF_CLIENT_NETS (the clients' data subnets) or FF_CLIENT_NICS (their data NIC names)"
    fi

    # --- 3. rails, eligibility, preflight ---
    local -a ELIG=() NO_IPERF=() BUSY=() CLI=()
    local r rc amb=0
    for k in "${BK[@]}"; do
        for r in "${RAILS[@]}"; do rail_lookup $k $r; [[ ${RSTATE[$k,$r]} == AMBIGUOUS* ]] && amb=$(( amb + 1 )); done
        local used="" dup=""
        for r in "${RAILS[@]}"; do
            [[ ${RNIC[$k,$r]} == - ]] && continue
            [[ " $used " == *" ${RNIC[$k,$r]} "* ]] && dup=${RNIC[$k,$r]}
            used+=" ${RNIC[$k,$r]}"
        done
        if [[ -z $used ]]; then
            echo "${T_TARGET[$k]} ${T_HOST[$k]} not on data rails" >> "$COLLECT_DIR/excluded.txt"; continue
        fi
        if [[ -n $dup ]]; then
            echo "${T_TARGET[$k]} ${T_HOST[$k]} $( (( NR == 2 )) && echo both rails || echo two rails) on one NIC $dup" >> "$COLLECT_DIR/excluded.txt"; continue
        fi
        ELIG+=("$k")
        for r in "${RAILS[@]}"; do
            [[ ${RSTATE[$k,$r]} == ok ]] || { [[ ${RIP[$k,$r]} != none ]] && DOWN_IP[${RIP[$k,$r]}]=1; }
        done
    done
    for k in "${CK[@]}"; do
        client_lookup $k
        if (( CN[$k] == 0 )); then echo "${T_TARGET[$k]} ${T_HOST[$k]} client with no data NIC ($CLIENT_MODE ${CLIENT_SPEC[*]})" >> "$COLLECT_DIR/excluded.txt"; continue; fi
        CLI+=("$k")
    done
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        section "${DISC[$k]}" tools | grep -q '^iperf3 /' || NO_IPERF+=("${T_HOST[$k]}")
        if [[ -n $FF_BUSY_CHECK ]]; then
            rc=$(section "${DISC[$k]}" busy | sed -n '1s/^rc=//p')
            if [[ $rc == 0 ]]; then BUSY+=("${T_HOST[$k]}(in use)")
            elif [[ $rc != 1 ]]; then BUSY+=("${T_HOST[$k]}(check rc=${rc:-none})"); fi
        fi
    done
    local not_rail; not_rail=$(grep -c 'not on data rails' "$COLLECT_DIR/excluded.txt" 2>&1)
    [[ $not_rail =~ ^[0-9]+$ && $not_rail -gt 0 ]] && log "$not_rail reachable hosts have no address on $( (( NR == 1 )) && echo the rail || { (( NR == 2 )) && echo either rail || echo any rail; }); left out"
    # FF_RAILS=a,b used to mean two rails; now it is one rail with two subnets, and two-NIC hosts come out ambiguous
    if (( amb )) && [[ $RAIL_MODE == cidr && $FF_RAILS != *';'* ]] && [[ ${RAIL_SPEC[0]} == *' '* ]]; then
        die "$amb hosts have two NICs in rail A (${RAIL_SPEC[0]// /,}): FF_RAILS has no ';', so it is one rail. For one subnet per rail write FF_RAILS='${RAIL_SPEC[0]// /;}'"
    fi
    if (( ${#ELIG[@]} < 2 )); then   # the work dir goes with the stop, so show the left-out hosts here
        [[ -s $COLLECT_DIR/excluded.txt ]] && { log "Left out (first 20):"; head -n 20 "$COLLECT_DIR/excluded.txt" | sed 's/^/#   /' >&2; }
        die "need at least 2 hosts on the rails, found ${#ELIG[@]}"
    fi
    if [[ $CLIENT_MODE != none ]]; then
        local nce; nce=$(grep -c 'client with no data NIC' "$COLLECT_DIR/excluded.txt" 2>&1)
        [[ $nce =~ ^[0-9]+$ && $nce -gt 0 ]] && log "$nce reachable clients have no data NIC ($CLIENT_MODE ${CLIENT_SPEC[*]}); left out"
        (( ${#CLI[@]} )) || die "no client has a data NIC ($CLIENT_MODE ${CLIENT_SPEC[*]})"
    fi
    (( ${#NO_IPERF[@]} == 0 || FF_SKIP_IPERF )) || die "iperf3 missing on ${#NO_IPERF[@]} hosts: ${NO_IPERF[*]}"
    if (( ${#BUSY[@]} > 0 )); then
        if (( FF_SKIP_IPERF )); then
            log "${#BUSY[@]} hosts in use per FF_BUSY_CHECK: fine with FF_SKIP_IPERF=1 (no test load is sent)"
        elif [[ $FF_BUSY_OK != 1 ]]; then
            local nb=${#BUSY[@]}; mapfile -t BUSY < <(printf "%s\n" "${BUSY[@]}" | sort -V)
            die "FF_BUSY_CHECK: $nb hosts in use or check failed$( (( nb > 10 )) && echo " (first 10 of $nb)"): ${BUSY[*]:0:10}. Line-rate load can starve cluster heartbeats and get nodes evicted. Stop the cluster's I/O and set FF_BUSY_OK=1 to proceed, or set FF_SKIP_IPERF=1 to run every check but the bandwidth runs."
        else log "WARNING: ${#BUSY[@]} hosts in use per FF_BUSY_CHECK; FF_BUSY_OK=1 given"; fi
        for k in "${ELIG[@]}" "${CLI[@]}"; do
            echo "== ${T_HOST[$k]}"; section "${DISC[$k]}" busy
        done > "$COLLECT_DIR/busy_check.txt"
    fi

    # iperf3 build and socket-buffer limits per host (UDP ceilings depend on both)
    for k in "${ELIG[@]}"; do
        echo "${T_HOST[$k]} $(section "${DISC[$k]}" iperf3 | awk '{print $2; exit}') $(section "${DISC[$k]}" sysctl | awk '{printf "%s ", $2}')"
    done | sort -V > "$COLLECT_DIR/iperf3_versions.txt"
    if [[ $FF_UDP == 1 ]]; then
        # before 3.16 iperf3 runs every stream in one thread, so UDP tops out on host CPU
        local old; old=$(awk 'NF >= 2 && $2 ~ /^[0-9]/ { split($2, v, "."); if (v[1] < 3 || (v[1] == 3 && v[2] < 16)) printf "%s(%s) ", $1, $2 }' "$COLLECT_DIR/iperf3_versions.txt")
        [[ -n $old ]] && log "WARNING: iperf3 older than 3.16 (single-threaded, UDP ceiling is host CPU-bound): $old"
        local small; small=$(awk '$3 ~ /^[0-9]+$/ && $3 < 4194304 { printf "%s(%s) ", $1, $3 }' "$COLLECT_DIR/iperf3_versions.txt")
        [[ -n $small ]] && log "NOTE: net.core.rmem_max under 4 MiB, receiver-socket UDP loss will be inflated: $small"
    fi

    # rail table: what an engineer checks before load starts
    {
        local hdr="Host Target" L
        for r in "${RAILS[@]}"; do L=$(rail_letter $r); hdr+=" Rail_${L}_NIC Rail_${L}_IP MTU_$L State_$L"; done
        echo "$hdr"
        for k in "${ELIG[@]}"; do
            local row="${T_HOST[$k]} ${T_TARGET[$k]}"
            for r in "${RAILS[@]}"; do row+=" ${RNIC[$k,$r]} ${RIP[$k,$r]} ${RMTU[$k,$r]:--} ${RSTATE[$k,$r]// /_}"; done
            echo "$row"
        done | sort -V
    } | column -t > "$COLLECT_DIR/rails.txt"
    # a rail a host lacks (no NIC x) or does not address (no IPv4 on x) is a host property, not a finding: one counted
    # line per rail and state, the first 8 hosts named (a GPU fleet seen 10-27: 112 hosts, two such rails each); a host
    # with any other bad rail (link DOWN, no address in the subnet, AMBIGUOUS) keeps its full row
    local bad_rails; bad_rails=$(awk 'NR > 1 { full = 0
        for (i = 6; i <= NF; i += 4) { s = $i; L = substr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", (i - 2) / 4, 1)
            if (s ~ /^no_(NIC|IPv4_on)_/) { k = L SUBSEP s; if (!(k in n)) ord[++no] = k; n[k]++; if (n[k] <= 8) hl[k] = hl[k] " " $1 }
            else if (s != "ok") full = 1 }
        if (full) rows[++nr] = $0 }
    END { for (i = 1; i <= no; i++) { k = ord[i]; split(k, p, SUBSEP); s = p[2]; gsub(/_/, " ", s)
              printf "%d host%s: rail %s %s:%s%s\n", n[k], (n[k] == 1 ? "" : "s"), p[1], s, hl[k], (n[k] > 8 ? " and " (n[k] - 8) " more" : "") }
          for (i = 1; i <= nr; i++) print rows[i] }' "$COLLECT_DIR/rails.txt")
    log "${#ELIG[@]} hosts on the rails. Rail NIC names and MTUs seen (count, NIC, MTU):"
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do echo "rail_$(rail_letter $r) ${RNIC[$k,$r]} mtu=${RMTU[$k,$r]:--}"; done; done \
        | sort | uniq -c | sed 's/^/#   /' >&2
    if [[ -n $bad_rails ]]; then
        log "Rails not usable (paths through them are skipped):"
        echo "$bad_rails" | sed 's/^/#   /' >&2
    else
        log "All rails on all ${#ELIG[@]} hosts have an address and link"
    fi
    if (( ${#CLI[@]} )); then   # client table: one row per client data NIC
        local j
        { echo "Client Target NIC IP MTU State"
          for k in "${CLI[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do
              echo "${T_HOST[$k]} ${T_TARGET[$k]} ${CNIC[$k,$j]} ${CIP[$k,$j]} ${CMTU[$k,$j]:--} ${CSTATE[$k,$j]// /_}"
          done; done | sort -V; } | column -t > "$WORK/clients0"
        log "${#CLI[@]} clients, $(awk 'NR > 1' "$WORK/clients0" | wc -l | tr -d ' ') data NICs. Client data NICs and MTUs seen (count, NIC, MTU):"
        awk 'NR > 1 {print $3, "mtu=" $5}' "$WORK/clients0" | sort | uniq -c | sed 's/^/#   /' >&2
        local bad_cl; bad_cl=$(awk 'NR > 1 && $6 != "ok"' "$WORK/clients0")
        [[ -n $bad_cl ]] && { log "Client data NICs not usable (their paths are skipped):"; echo "$bad_cl" | sed 's/^/#   /' >&2; }
        for k in "${CLI[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j || { [[ ${CIP[$k,$j]} != none ]] && DOWN_IP[${CIP[$k,$j]}]=1; }; done; done
    fi
    # run lock before any preflight: a second run on the same hosts would kill this one's iperf3 servers
    take_locks
    : > "$COLLECT_DIR/rail_anomalies.txt"   # preflight findings: host kind detail...
    # one MTU per rail expected; name the odd hosts (their paths fail the no-fragment check)
    local rr
    for rr in "${RAILS[@]}"; do
        RAIL_MTU[$rr]=$(for k in "${ELIG[@]}"; do rail_ok $k $rr && echo "${RMTU[$k,$rr]:-1500}"; done | sort -n | tail -n1)
        local mt; mt=$(for k in "${ELIG[@]}"; do rail_ok $k $rr && echo "${RMTU[$k,$rr]:-?} ${T_HOST[$k]}"; done | mtu_odd)
        [[ -n $mt ]] && log "WARNING: rail $(rail_letter $rr) MTUs differ: $mt paths across them fail the no-fragment check and are skipped"
        [[ -n $mt ]] && echo "rail_$(rail_letter $rr) mtu_mismatch $mt" >> "$COLLECT_DIR/rail_anomalies.txt"
    done
    if (( ${#CLI[@]} )); then
        local mt; mt=$(for k in "${CLI[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j && echo "${CMTU[$k,$j]:-?} ${T_HOST[$k]}_${CNIC[$k,$j]}"; done; done | mtu_odd)
        [[ -n $mt ]] && log "WARNING: client data NIC MTUs differ: $mt"
        [[ -n $mt ]] && echo "clients client_mtu_mismatch $mt" >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
    rail_consistency
    gateway_check
    [[ $FF_MESH == 1 ]] && mesh_check
    (( ${#CLI[@]} )) && client_routes

    # --- 4. diagnostics ---
    log "Collecting NIC diagnostics..."
    local NIC_DIAG=$COLLECT_DIR/nic_diagnostics.txt LLDP_DATA=$COLLECT_DIR/lldp_neighbors.txt DRV_DATA=$COLLECT_DIR/driver_info.txt
    local BOND_DATA=$COLLECT_DIR/bonds.txt   # "host nic slaves_up slaves_total down_slaves" per bond NIC (raw_per_host has the kernel's report)
    : > "$NIC_DIAG"; : > "$LLDP_DATA"; : > "$DRV_DATA"; : > "$BOND_DATA"
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$DIAG_SCRIPT" > "$WORK/diag.$k" 2>&1 &
    done
    wait
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        grep '^@@NIC_DIAG ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$NIC_DIAG"
        grep '^@@LLDP ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$LLDP_DATA"
        grep '^@@DRV ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$DRV_DATA"
        grep '^@@BOND ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$BOND_DATA"
        grep -v '^@@' "$WORK/diag.$k" > "$RAW_DIR/${T_HOST[$k]}.txt"
    done
    log "Diagnostics: $(wc -l < "$NIC_DIAG" | tr -d ' ') NIC, $(wc -l < "$LLDP_DATA" | tr -d ' ') LLDP, $(wc -l < "$DRV_DATA" | tr -d ' ') driver lines$( [[ -s $BOND_DATA ]] && echo ", $(wc -l < "$BOND_DATA" | tr -d ' ') bonds")"
    lldp_rail_check "$LLDP_DATA"

    # line rate: per rail only when declared (FF_LINE_GBPS=A,B,...); otherwise the fastest rail's most common
    # speed for every rail, so a whole rail that came up slow is not judged against itself. Only a usable rail's
    # NIC votes (iprail: "host nic letter", rails in state ok); a NIC a host has but does not address, or a rail
    # it lacks, has no say and no rail letter (a GPU fleet seen 10-27: 112 bond members with no IPv4 were keyed by that
    # "none" and the 107 with a readable speed voted as rail B; the other 5 reported speed Unknown!)
    local -a LINE=() MODE=() VOTE=() TOT=() fl=(); local LINE_GBPS k v
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do rail_ok $k $r && echo "${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r)"; done; done > "$WORK/iprail"
    if [[ -n $FF_LINE_GBPS ]]; then
        IFS=, read -r -a fl <<<"$FF_LINE_GBPS"
        for r in "${RAILS[@]}"; do LINE[r]=${fl[r]:-${fl[0]}}; done
    else
        # per rail "mode/voters/total": the most common speed, how many NICs run at it, how many voted
        read -r -a MODE <<<"$(awk -v L="${LETTERS:0:NR}" 'NR == FNR {rail[$1 " " $2] = $3; next}
            (($1 " " $2) in rail) && $4 ~ /^[0-9]+Mb\/s$/ {s = $4; sub(/Mb\/s/, "", s); r = rail[$1 " " $2]; n[r " " s / 1000]++; t[r]++}
            END {for (k in n) {split(k, p, " "); r = p[1]; v = p[2] + 0
                     if (n[k] > c[r] || (n[k] == c[r] && v > m[r])) {c[r] = n[k]; m[r] = v}}
                 for (i = 1; i <= length(L); i++) {l = substr(L, i, 1); printf "%s ", (l in m) ? m[l] "/" c[l] "/" t[l] : "0/0/0"}}' "$WORK/iprail" "$NIC_DIAG")"
        for r in "${RAILS[@]}"; do v=${MODE[r]}; MODE[r]=${v%%/*}; v=${v#*/}; VOTE[r]=${v%/*}; TOT[r]=${v#*/}; done
        local mx=0 differ= ms=""; for r in "${RAILS[@]}"; do (( MODE[r] > mx )) && mx=${MODE[r]}; done
        for r in "${RAILS[@]}"; do LINE[r]=$mx; (( MODE[r] && MODE[r] != mx )) && differ=1; ms+="${ms:+, }rail $(rail_letter $r) ${MODE[r]}G on ${VOTE[r]} of ${TOT[r]} NICs"; done
        (( mx )) || for r in "${RAILS[@]}"; do LINE[r]=; done
        [[ -n $differ ]] && log "WARNING: rails run at different speeds ($ms): $( (( NR == 2 )) && echo both || echo all) judged at ${mx}G. If that is by design, set FF_LINE_GBPS=$(IFS=,; echo "${MODE[*]}")"
    fi
    LINE_GBPS=0; RAIL_LINES=""; for r in "${RAILS[@]}"; do (( ${LINE[r]:-0} > LINE_GBPS )) && LINE_GBPS=${LINE[r]}; RAIL_LINES+="${RAIL_LINES:+ }$(rail_letter $r)=${LINE[r]:-0}"; done
    (( LINE_GBPS )) || LINE_GBPS=
    local same=1; for r in "${RAILS[@]}"; do [[ ${LINE[r]} == "${LINE[0]}" ]] || same=; done
    if [[ -n $LINE_GBPS ]]; then
        cutoffs() { awk -v l="$1" -v o="$FF_OK_PCT" -v s="$FF_SLOW_PCT" 'BEGIN {printf "%gG (OK >= %gG, SLOW >= %gG)", l, l * o / 100, l * s / 100}'; }
        if [[ -n $same ]]; then log "Link speed for cut-offs: $(cutoffs "${LINE[0]}")"
        else log "Link speed for cut-offs: $(for r in "${RAILS[@]}"; do printf '%srail %s %s' "$( (( r )) && echo ', ')" "$(rail_letter $r)" "$(cutoffs "${LINE[r]:-0}")"; done)"; fi
        awk -v lines="$RAIL_LINES" 'BEGIN {n = split(lines, q, " "); for (i = 1; i <= n; i++) {split(q[i], kv, "="); want[kv[1]] = kv[2] * 1000 "Mb/s"}}
            NR == FNR {rail[$1 " " $2] = $3; next}
            $4 ~ /^[0-9]+Mb\/s$/ && (($1 " " $2) in rail) && $4 != want[rail[$1 " " $2]] {printf "#   %s %s %s (rail %s)\n", $1, $2, $4, rail[$1 " " $2]}' \
            "$WORK/iprail" "$NIC_DIAG" > "$WORK/offspeed"
        if [[ -s $WORK/offspeed ]]; then
            if [[ -n $same ]]; then log "NICs not at ${LINE[0]}G:"; else log "NICs not at their rail's speed:"; fi
            # a bond's line says how many slaves have link (bonds.txt: host nic up total down_slaves)
            awk 'FILENAME == ARGV[1] { b[$1 " " $2] = $3 " of " $4 " slaves up" ($5 == "none" ? "" : ", " $5 " down (MII)"); next }
                 { k = $2 " " $3; print $0 ((k in b) ? ": " b[k] : "") }' "$BOND_DATA" "$WORK/offspeed" >&2
        fi
    else
        log "WARNING: no link speed from ethtool and FF_LINE_GBPS unset; no OK/SLOW status"
    fi
    if (( ${#CLI[@]} )); then   # clients.txt: the client table plus each data NIC's speed
        awk 'NR == FNR {sp[$1 " " $2] = $4; next} FNR == 1 {print $0, "Speed"; next} {print $0, (($1 " " $3) in sp && sp[$1 " " $3] ~ /^[0-9]+Mb\/s$/) ? sp[$1 " " $3] : "unknown"}' \
            "$NIC_DIAG" "$WORK/clients0" | column -t > "$COLLECT_DIR/clients.txt"
        if [[ -n $FF_CLIENT_GBPS ]]; then log "Client line rate: ${FF_CLIENT_GBPS}G (FF_CLIENT_GBPS)"
            awk -v w="$(( FF_CLIENT_GBPS * 1000 ))Mb/s" 'NR > 1 && $7 ~ /^[0-9]+Mb\/s$/ && $7 != w {printf "#   %s %s %s %s\n", $1, $3, $4, $7}' "$COLLECT_DIR/clients.txt" > "$WORK/coffspeed"
            [[ -s $WORK/coffspeed ]] && { log "Client NICs not at ${FF_CLIENT_GBPS}G:"; cat "$WORK/coffspeed" >&2; }
        else log "Client line rate: each client NIC's own speed (a bond counts its total; set FF_CLIENT_GBPS to override): $(awk 'NR > 1 {print $7}' "$COLLECT_DIR/clients.txt" | sort | uniq -c | awk '{printf "%s%s x %s", s, $1, $2; s = ", "}')"; fi
    fi

    lock_all touch   # preflight can be long (mesh); refresh before load
    collect_sysinfo
    rx_config > "$WORK/rxcfg"
    log "Rail NIC receive config: $(awk '{ n++; if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) r++
        if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) p++ } }
        END { printf "%d NICs read; rx ring below its maximum on %d, PCIe link below its maximum on %d", n, r, p }' "$WORK/rxcfg")"
    # --- 5. iperf3 servers ---
    ORDER=($(for k in "${ELIG[@]}"; do echo "$k ${T_HOST[$k]}"; done | sort -V -k2 | awk '{print $1}'))
    CL_K=1; (( ${#CLI[@]} )) && client_plan 1   # backend NICs that serve several client flows at once need a server each
    CL_K0=$CL_K   # servers started per backend IP; a later iteration plans the same shares, rotated
    LOADED=1
    if (( FF_SKIP_IPERF )); then
        log "FF_SKIP_IPERF=1: no iperf3 servers, no load; path checks, counters and system info only"; save_state
    else
        log "Stopping stray iperf3 and starting servers on port $FF_PORT$( (( CL_K > 1 )) && echo "-$(( FF_PORT + CL_K - 1 )) (backends: up to $CL_K client flows per NIC at once)")..."
        for k in "${ELIG[@]}" "${CLI[@]}"; do STARTED[$k]=1; done; save_state
        local -A WANT=()   # k -> "ip:port ..." that must listen
        for k in "${ELIG[@]}" "${CLI[@]}"; do
            local ips=() cnt=$CL_K j
            if [[ -n ${IS_CL[$k]} ]]; then cnt=1; for (( j = 0; j < CN[$k]; j++ )); do cl_ok $k $j && ips+=("${CIP[$k,$j]}"); done
            else for r in "${RAILS[@]}"; do rail_ok $k $r && ips+=("${RIP[$k,$r]}"); done; fi
            local ip q; WANT[$k]=""; for ip in "${ips[@]}"; do for (( q = 0; q < cnt; q++ )); do WANT[$k]+=" $ip:$(( FF_PORT + q ))"; done; done
            rbash "${T_TARGET[$k]}" "$FF_PORT" "$cnt" "${ips[@]}" <<<"$SERVER_SCRIPT" >> "$RUNLOG_SSH" 2>&1 &
        done
        wait
        for k in "${ELIG[@]}" "${CLI[@]}"; do
            ( for i in $(seq 20); do
                  l=$(rsh "${T_TARGET[$k]}" ss -Htln 2>&1)
                  all=1
                  for w in ${WANT[$k]}; do [[ $l != *"$w "* ]] && all=0; done
                  (( all )) && exit 0
                  sleep 0.5
              done
              echo "$k" ) > "$WORK/srv.$k" &
        done
        wait
        for k in "${ELIG[@]}" "${CLI[@]}"; do
            [[ -s $WORK/srv.$k ]] || continue
            if [[ -n ${IS_CL[$k]} ]]; then
                for (( j = 0; j < CN[$k]; j++ )); do
                    cl_ok $k $j || continue
                    CSTATE[$k,$j]="iperf3 server not listening on ${CIP[$k,$j]}:$FF_PORT"; DOWN_IP[${CIP[$k,$j]}]=1
                done
            else
                for r in "${RAILS[@]}"; do
                    rail_ok $k $r || continue
                    RSTATE[$k,$r]="iperf3 server not listening on ${RIP[$k,$r]}:$FF_PORT$( (( CL_K > 1 )) && echo "-$(( FF_PORT + CL_K - 1 ))")"; DOWN_IP[${RIP[$k,$r]}]=1
                done
            fi
            log "WARNING: ${T_HOST[$k]}: iperf3 server not listening; its paths are skipped"
        done
    fi

    # --- 6. iterations ---
    local RESULTS=$COLLECT_DIR/iperf3_results.txt DROP_TOTALS=$COLLECT_DIR/packet_drops.txt
    PATH_EXCL=$COLLECT_DIR/paths_excluded.txt
    : > "$RESULTS"; : > "$DROP_TOTALS"; : > "$COLLECT_DIR/link_flaps.txt"; : > "$PATH_EXCL"
    local FIRST_HOST=${T_HOST[${ORDER[0]}]}
    local n=${#ORDER[@]} p ck sk
    # cross-rail phase: on, off when the operator says the rails are separate fabrics, single with one rail
    CROSS=on; CROSS_UNROUTED=0
    if (( NR == 1 )); then CROSS=single; log "One rail: no cross-rail phase"
    elif [[ $FF_CROSS_RAIL == 0 ]]; then CROSS=off; log "Cross-rail phase off (FF_CROSS_RAIL=0): $( (( NR == 2 )) && echo "A<->B" || echo "rail to rail") is not tested"; fi
    # Rail groups: a host is paired only with hosts that hold the same rails. A rail a host lacks or does not
    # address is a host property (a 10-27 field run: 24 storage hosts on A,B and 215 GPU hosts on C drew each
    # other in 24 of 119 pairs, every path in those pairs skipped, phase 2 ran nothing); a DOWN rail keeps its
    # host in the group and its paths log a skip. Per group g: GROT[g] its round-robin circle ("-" = bye),
    # GRAILS[g] its rail indices, GUPAIRS[g] its rail pairs for phase 2 ("0 1;0 2;..."), GROUNDS/GPER/GPPP/GNUP.
    rail_groups
    local g rounds=0 per=0 total=0 NUP=1 cyc=0 ng=${#GKEYS[@]}
    for (( g = 0; g < ng; g++ )); do
        (( GROUNDS[g] > rounds )) && rounds=${GROUNDS[g]}
        (( GNUP[g] > NUP )) && NUP=${GNUP[g]}
        (( 2 * GROUNDS[g] * GNUP[g] > cyc )) && cyc=$(( 2 * GROUNDS[g] * GNUP[g] ))
        per=$(( per + GPER[g] )); total=$(( total + GN[g] * (GN[g] - 1) / 2 ))
    done
    (( rounds > 0 )) || rounds=1; (( cyc > 0 )) || cyc=1
    (( ITER_ALL )) && FF_ITER=$(( cyc > ${CL_ALL:-0} ? cyc : CL_ALL ))
    PAIRS_COVERED=0; PAIRS_TOTAL=$total; DIRECTED_TOTAL=0; local planned=0 gdesc="" lone="" t
    local -A DIRECTED=()
    for (( g = 0; g < ng; g++ )); do
        local gused=$(( FF_ITER < GROUNDS[g] ? FF_ITER : GROUNDS[g] ))
        PAIRS_COVERED=$(( PAIRS_COVERED + gused * GPER[g] ))
        if (( GN[g] == 1 )); then lone+=" ${T_HOST[${GROT[g]}]}"; gdesc+="; ${GKEYS[g]} 1 host, no partner"; continue; fi
        gdesc+="; ${GKEYS[g]} ${GN[g]} hosts, ${GPER[g]} pair$( (( GPER[g] != 1 )) && echo s)/iteration$( (( GN[g] % 2 )) && echo ", 1 sits out")"
        # directed NIC paths of the group: per host pair, over the rails both hold (a joined host has fewer)
        local -a gm=(${GROT[g]}); local i j
        for (( i = 0; i < ${#gm[@]}; i++ )); do for (( j = i + 1; j < ${#gm[@]}; j++ )); do
            [[ ${gm[i]} == - || ${gm[j]} == - ]] && continue
            pair_rails ${gm[i]} ${gm[j]}; local d=$PRN
            [[ $CROSS == on ]] && (( PRN > 1 )) && d=$(( PRN * PRN ))
            DIRECTED_TOTAL=$(( DIRECTED_TOTAL + 2 * d ))
        done; done
    done
    for (( t = 0; t < (FF_ITER < cyc ? FF_ITER : cyc); t++ )); do   # the paths the iterations will plan
        round_pairs $t; for (( p = 0; p < ${#PPATHS[@]}; p++ )); do planned=$(( planned + PPATHS[p] )); done
    done
    PATHS_PLANNED=0; DROP_READS_MIN=-1
    log "Pairing: round-robin within $ng rail group$( (( ng > 1 )) && echo s): ${gdesc#; }; $FF_ITER iteration$( (( FF_ITER != 1 )) && echo s) cover$( (( FF_ITER == 1 )) && echo s) $PAIRS_COVERED of $total host pairs$( (( FF_ITER < rounds )) && echo " (all pairs need FF_ITER=$rounds)")"
    if [[ -n $JOINED ]]; then
        local nj; nj=$(awk -F'; ' '{print NF}' <<<"$JOINED")
        log "$nj host$( (( nj > 1 )) && echo "s lack" || echo " lacks") a rail and pair$( (( nj == 1 )) && echo s) within the hosts holding the rails $( (( nj > 1 )) && echo they have || echo it has): $(awk -F'; ' '{for (i = 1; i <= NF && i <= 8; i++) printf "%s%s", (i > 1 ? "; " : ""), $i; if (NF > 8) printf "; and %d more", NF - 8}' <<<"$JOINED")"
    fi
    if [[ -n $lone ]]; then
        local nl; nl=$(wc -w <<<"$lone" | tr -d ' ')
        log "$nl host$( (( nl > 1 )) && echo s have || echo " has") no partner sharing $( (( nl > 1 )) && echo their || echo its) rails (not tested): $(awk '{for (i = 1; i <= NF && i <= 8; i++) printf "%s%s", (i > 1 ? " " : ""), $i; if (NF > 8) printf " and %d more", NF - 8}' <<<"$lone")"
    fi
    # pairing.txt (only when a host is tested on fewer rails or not at all): "host<TAB>why", for the dashboard's Not tested card
    if [[ -n $JOINED$lone ]]; then
        { [[ -n $JOINED ]] && awk -F'; ' '{for (i = 1; i <= NF; i++) { h = $i; sub(/:.*/, "", h); w = $i; sub(/^[^:]*: /, "", w); printf "%s\t%s\n", h, w }}' <<<"$JOINED"
          for sk in $lone; do printf '%s\tno partner sharing its rails\n' "$sk"; done; } > "$COLLECT_DIR/pairing.txt"
    fi
    # a pair's directed NIC paths (8 with two rails): cycle 1 runs half, cycle 2 (same pairings, client and server
    # swapped) the other half; with more rails, each further pair of cycles covers one more rail pair
    log "Directed NIC paths: $planned of $DIRECTED_TOTAL planned$( (( FF_ITER < cyc )) && echo " (every direction on every NIC pair needs FF_ITER=$cyc, or FF_ITER=all)")"
    (( FF_ITER > rounds && FF_ITER <= 2 * rounds )) && log "Iterations $(( rounds + 1 ))-$FF_ITER repeat the pairings with client and server swapped$( (( ng > 1 )) && echo " (largest group; a smaller group swaps sooner)")"
    (( NUP > 1 && FF_ITER > 2 * rounds )) && log "Iterations past $(( 2 * rounds )) repeat the pairings with the next rail pair for the cross-rail phase ($NUP rail pairs)"
    (( FF_ITER > cyc )) && log "Iterations past $cyc repeat the pairings from the start"
    [[ -n $FF_TOS ]] && log "Marking: iperf3 -S $FF_TOS = DSCP $(( FF_TOS >> 2 )), ECN bits $(( FF_TOS & 3 )) (TCP: the kernel owns the ECN bits)"
    : > "$COLLECT_DIR/pairs.txt"; : > "$COLLECT_DIR/prio_counters.txt"; : > "$COLLECT_DIR/fec_rates.txt"; : > "$COLLECT_DIR/host_counters.txt"
    echo "Iter Phase Start_UTC End_UTC" > "$COLLECT_DIR/phase_times.txt"
    (( FF_TEMPS )) && echo "Label Host Source Chip Dev Sensor Temp_C High_C Crit_C Status" > "$COLLECT_DIR/temps.txt"
    : > "$WORK/hc_reads"; HC_READS=0; : > "$WORK/paths_ok"
    # rail IP -> host/rail, and host_nic -> host, for the summary and UDP loss placement
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RIP[$k,$r]} != none ]] && echo "${RIP[$k,$r]} ${T_HOST[$k]} $(rail_letter $r)"
    done; done > "$WORK/ipmap"
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]}_${RNIC[$k,$r]} ${T_HOST[$k]} $(rail_letter $r)"
    done; done > "$WORK/nicmap"
    # the same with the client data NICs, for the UDP receivers
    local j; { cat "$WORK/ipmap"; for k in "${CLI[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do
        [[ ${CIP[$k,$j]} != none ]] && echo "${CIP[$k,$j]} ${T_HOST[$k]} client"; done; done; } > "$WORK/uipmap"
    { cat "$WORK/nicmap"; for k in "${CLI[@]}"; do for (( j = 0; j < CN[$k]; j++ )); do
        echo "${T_HOST[$k]}_${CNIC[$k,$j]} ${T_HOST[$k]} client"; done; done; } > "$WORK/unicmap"
    # ip -> line rate (Gbps, 0 = unknown), the receiving side of the UDP overload floor: a backend rail IP its
    # rail's line, a client data NIC FF_CLIENT_GBPS or its own speed
    { for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do [[ ${RIP[$k,$r]} != none ]] && echo "${RIP[$k,$r]} ${LINE[r]:-0}"; done; done
      (( ${#CLI[@]} )) && awk -v cg="${FF_CLIENT_GBPS:-0}" 'NR > 1 && $4 != "none" {s = $7; sub(/Mb\/s/, "", s); print $4, (cg > 0 ? cg : (s ~ /^[0-9]+$/ ? s / 1000 : 0))}' "$COLLECT_DIR/clients.txt"; } > "$WORK/iplines"
    UDP_RESULTS=$COLLECT_DIR/iperf3_udp_results.txt
    if [[ $FF_UDP == 1 ]]; then
        : > "$UDP_RESULTS"; : > "$COLLECT_DIR/udp_host_counters.txt"; : > "$COLLECT_DIR/udp_nic_drops.txt"; : > "$COLLECT_DIR/udp_expected.txt"; : > "$COLLECT_DIR/udp_tx.txt"
        log "UDP pass on: phases U1/U2 after the TCP phases$( (( ${#CLI[@]} )) && echo ", and a UDP twin of each client phase (UC1/UC2, UF1/UF2) after the client TCP phases"), ${FF_UDP_DURATION}s each, no rate cap"
    fi
    CRESULTS=$COLLECT_DIR/client_results.txt; CL_PLANNED=0
    if (( ${#CLI[@]} )); then
        : > "$CRESULTS"; : > "$WORK/cpaths_ok"
        local ncn=0; for k in "${CLI[@]}"; do ncn=$(( ncn + CN[$k] )); done
        log "Clients: ${#CLI[@]} clients, $ncn data NICs, to $NR rail$( (( NR > 1 )) && echo s) of ${#ELIG[@]} backends (FF_CLIENT_RATIO=$FF_CLIENT_RATIO), each iteration after the backend phases; each iteration moves every client NIC on to the next backend"
        log "Client NIC to backend NIC coverage: in $FF_ITER iterations each client NIC reaches $(( FF_ITER < CL_ALL ? FF_ITER : CL_ALL )) of $CL_ALL backend NICs$( (( CL_WAVES && !CL_FULL )) && echo " per rail")$( (( FF_ITER < CL_ALL )) && echo " (every client NIC to every backend NIC needs FF_ITER=$CL_ALL, or FF_ITER=all)")"
    fi
    local cross_decided=; [[ $CROSS == on ]] || cross_decided=1
    for (( ITER = 1; ITER <= FF_ITER; ITER++ )); do
        round_pairs $(( ITER - 1 ))   # every group's pairs for this iteration (swap cycle and rail pair per group)
        lock_all touch
        local xdesc="" sits=""
        for (( p = 0; p < ${#PC[@]}; p++ )); do PATHS_PLANNED=$(( PATHS_PLANNED + PPATHS[p] )); done
        if (( NR > 2 )) && [[ $CROSS == on ]]; then
            for (( g = 0; g < ng; g++ )); do [[ -n ${GXA[g]} ]] && xdesc+="${xdesc:+, }${GKEYS[g]}: $(rail_letter ${GXA[g]})<->$(rail_letter ${GXB[g]})"; done
        fi
        log "============ Iteration $ITER of $FF_ITER (${#PC[@]} pairs${xdesc:+; cross-rail $xdesc}) ============"
        for sk in $SITOUT; do sits+=" ${T_HOST[$sk]}"; done
        [[ -n $sits ]] && log "Sits out this iteration (odd host count):$sits"
        for (( p = 0; p < ${#PC[@]}; p++ )); do echo "$ITER ${T_HOST[${PC[p]}]} ${T_HOST[${PS[p]}]}"; done >> "$COLLECT_DIR/pairs.txt"
        PATHS=$WORK/paths.$ITER; mkdir -p "$PATHS"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            ck=${PC[p]}; sk=${PS[p]}
            p1_paths $p check
            [[ -n ${PXA[p]} ]] && { xpaths $p; check_path p2a_$p "${X1[@]}"; check_path p2b_$p "${X2[@]}"; }
            for r in ${PRAILS[p]}; do if (( r % 2 )); then DIRECTED["$sk $r $ck $r"]=1; else DIRECTED["$ck $r $sk $r"]=1; fi; done
            [[ -n ${PXA[p]} ]] && { DIRECTED["${X1[*]}"]=1; DIRECTED["${X2[*]}"]=1; }
        done
        wait
        if [[ -z $cross_decided && ${#PC[@]} -gt 0 ]]; then
            cross_decided=1
            local xn xr sr
            xn=$(ls "$PATHS" | grep -c '^p2'); xr=$(cat "$PATHS"/p2* | grep -c '^ROUTE'); sr=$(cat "$PATHS"/p1* | grep -c '^ROUTE')
            if (( xn > 0 && xr == xn && sr == 0 )); then
                CROSS_UNROUTED=1   # still counted: a site missing its inter-rail routes looks the same
                log "WARNING: rails are not routed to each other (all $xn $( (( NR == 2 )) && echo "A<->B" || echo cross-rail) path checks failed on routing, no same-rail one did): either separate fabrics by design (rerun with FF_CROSS_RAIL=0) or inter-rail routing missing on every host. The skips count until you say which."
            fi
        fi
        local bad nchk; bad=$(grep -Lx OK "$PATHS"/* | wc -l | tr -d ' '); nchk=$(ls "$PATHS" | wc -l | tr -d ' ')
        log "Path checks (egress route, ping, MTU no-fragment): $(( nchk - bad )) OK, $bad excluded"
        if (( FF_SKIP_IPERF )); then   # every planned path's check is recorded; the counters get one window, at the end
            for (( p = 0; p < ${#PC[@]}; p++ )); do
                PHASE=1; p1_paths $p run check
                [[ -n ${PXA[p]} ]] && { PHASE=2; xpaths $p; run_path p2a_$p "${X1[@]}" check; run_path p2b_$p "${X2[@]}" check; }
            done
            clients_iter   # client path checks, every iteration
            (( ITER < FF_ITER )) && { echo; continue; }
        fi

        local DROPS_PRE=$WORK/drops_pre DROPS_POST=$WORK/drops_post
        collect_drops "$DROPS_PRE"
        collect_counters "$PRIO_SCRIPT" "$WORK/prio_pre"
        collect_counters "$FEC_SCRIPT" "$WORK/fec_pre"; local fec_t0; fec_t0=$(date +%s)
        collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.pre"; local hc_prev=$WORK/hc.pre
        collect_temps "iter${ITER}_pre" ipmi   # the BMC (inlet) once per iteration: ipmitool sensor can take tens of seconds
        if (( FF_SKIP_IPERF )); then
            phase_start
            log "Observation window: ${FF_DURATION}s with no test load (FF_SKIP_IPERF=1), start $PT0; the counter changes below are the cluster's own traffic"
            sleep "$FF_DURATION"; phase_end obs
            collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.obs"; hostctr_delta "iter${ITER}_obs" "$hc_prev" "$WORK/hc.obs"; collect_temps "iter${ITER}_obs"
            hc_log "the observation window" "$WORK/hc.obs"
        else
            for PHASE in 1 2; do
                PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
                if [[ $PHASE == 2 && $CROSS != on ]]; then log "Phase 2: skipped (cross-rail $CROSS)"; phase_skip 2; continue; fi
                phase_start
                [[ $PHASE == 1 ]] && log "Phase 1: $(same_desc) at once, start $PT0" || log "Phase 2: cross-rail, $(cross_desc) at once, start $PT0"
                if [[ $PHASE == 1 ]]; then
                    echo "### iteration:${ITER} phase:${PHASE}" >> "$RESULTS"
                    for (( p = 0; p < ${#PC[@]}; p++ )); do
                        p1_paths $p run
                    done
                    wait
                    column -t < "$PHASE_OUT" | tee -a "$RESULTS"
                else xwaves "$RESULTS"; fi
                phase_end $PHASE
                local errs; errs=$(grep -c ',ERROR' "$PHASE_OUT")
                [[ $errs -gt 0 ]] && { log "WARNING: $errs runs in phase $PHASE returned no result (lines with ERROR above):"; log_hist "$PHASE_OUT"; }
                collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.$PHASE"; hostctr_delta "iter${ITER}_p$PHASE" "$hc_prev" "$WORK/hc.$PHASE"; hc_prev=$WORK/hc.$PHASE
                collect_temps "iter${ITER}_p$PHASE"
                hc_log "phase $PHASE" "$WORK/hc.$PHASE"
            done
        fi
        [[ $FF_UDP == 1 ]] && udp_phases
        collect_drops "$DROPS_POST"
        local nr; nr=$(wc -l < "$DROPS_POST" | tr -d ' ')   # "0 drops" only means something if NICs were read
        (( DROP_READS_MIN < 0 || nr < DROP_READS_MIN )) && DROP_READS_MIN=$nr
        collect_counters "$PRIO_SCRIPT" "$WORK/prio_post"
        collect_counters "$FEC_SCRIPT" "$WORK/fec_post"
        fec_deltas "iter$ITER" $(( $(date +%s) - fec_t0 > 0 ? $(date +%s) - fec_t0 : 1 ))
        # per-priority / pause / ECN counter increases: "iterN host_nic counter delta"
        awk -v it="iter$ITER" 'NR==FNR {pre[$1" "$2]=$3; next}
            ($1" "$2) in pre && $3 > pre[$1" "$2] {print it, $1, $2, $3 - pre[$1" "$2]}' \
            "$WORK/prio_pre" "$WORK/prio_post" > "$WORK/prio_delta"
        if [[ -s $WORK/prio_delta ]]; then
            cat "$WORK/prio_delta" >> "$COLLECT_DIR/prio_counters.txt"
            # which priority carried the bytes, per rail (shows where each rail's DSCP map put the traffic)
            log "Traffic by priority in iteration $ITER (rx+tx bytes): $(awk -v RL="${LETTERS:0:NR}" '
                NR == FNR { rail[$1] = $3; next }
                { l = tolower($3) } l ~ /byte/ && match(l, /pri(ority|o)?_?[0-9]/) {
                    p = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", p); r = ($2 in rail) ? rail[$2] : "?"
                    b[r " " p] += $4; n++ }
                END { RL = RL "?"; for (r = 1; r <= length(RL); r++) { R = substr(RL, r, 1); t = ""
                          for (p = 0; p <= 7; p++) if ((R " " p) in b) t = t sprintf(" prio%d %s", p, b[R " " p] < 5e7 ? "<0.1GB" : sprintf("%.1fGB", b[R " " p] / 1e9))
                          if (t != "") printf "rail %s:%s  ", R, t }
                      if (!n) printf "no per-priority byte counters" }' "$WORK/nicmap" "$WORK/prio_delta")"
            awk 'tolower($3) !~ /byte|packet/ || $3 ~ /^rdma:/' "$WORK/prio_delta" | sort -k4 -rn > "$WORK/prio_events"
            if [[ -s $WORK/prio_events ]]; then
                local ne; ne=$(wc -l < "$WORK/prio_events" | tr -d ' ')
                log "Pause/ECN/discard/RDMA counters that rose ($( (( ne > 10 )) && echo "top 10 of $ne" || echo "$ne")):"
                head -n 10 "$WORK/prio_events" | column -t | sed 's/^/#   /' >&2
            else
                log "No pause/ECN/discard/RDMA counter rose in iteration $ITER ($(wc -l < "$WORK/prio_post" | tr -d ' ') counters read, $(awk '$2 ~ /^rdma:/' "$WORK/prio_post" | wc -l | tr -d ' ') of them RDMA)"
            fi
        else
            log "No priority/pause/ECN/RDMA counter rose in iteration $ITER ($(wc -l < "$WORK/prio_post" | tr -d ' ') counters read, $(awk '$2 ~ /^rdma:/' "$WORK/prio_post" | wc -l | tr -d ' ') of them RDMA)"
        fi
        local iter_drops; iter_drops=$(compute_drops "$DROPS_PRE" "$DROPS_POST" "iter${ITER}")
        if [[ -n $iter_drops ]]; then
            log "Drops during iteration $ITER:"; echo "$iter_drops" | awk '{NF--; print}' | column -t | sed 's/^/#   /' >&2
            echo "$iter_drops" >> "$DROP_TOTALS"
        else
            log "No drop counter increases in iteration $ITER ($(wc -l < "$DROPS_POST" | tr -d ' ') NICs read)"
        fi
        # a rail link that went down during the iteration: its runs measured a flap, not the fabric
        local flaps; flaps=$(awk -v it="iter$ITER" 'NR == FNR {c[$1] = $6; next}
            ($1 in c) && $6 ~ /^[0-9]+$/ && c[$1] ~ /^[0-9]+$/ && $6 > c[$1] {print it, $1, $2, $6 - c[$1]}' "$DROPS_PRE" "$DROPS_POST")
        if [[ -n $flaps ]]; then
            log "WARNING: rail links went down during iteration $ITER (host_nic ip carrier-down count):"
            echo "$flaps" | cut -d' ' -f2- | column -t | sed 's/^/#   /' >&2
            echo "$flaps" >> "$COLLECT_DIR/link_flaps.txt"
        fi
        (( FF_SKIP_IPERF )) || clients_iter   # load runs: after the backend phases and their counters
        echo
    done

    collect_temps end ipmi
    temp_summary
    collect_klog
    host_rx "$RESULTS"

    # --- 7. summary ---
    local LABEL=${FF_LABEL:-$FIRST_HOST}
    LABEL=${LABEL//[^A-Za-z0-9_.-]/_}
    {
        echo ""
        echo "=================================================================="
        echo " $LABEL DATA PLANE VALIDATION SUMMARY: $(date)"
        echo "=================================================================="
        local map=$WORK/ipmap
        # heat before fabric: a hot host can cap throughput, resend and flap links on its own
        if (( FF_TEMPS )) && [[ -s $COLLECT_DIR/temps_summary.txt ]]; then
            local ts=$COLLECT_DIR/temps_summary.txt
            echo "Temperatures (temps_summary.txt; hwmon$( (( FF_IPMI )) && echo " and BMC via ipmitool"); flags: crit, high, near = within ${FF_TEMP_MARGIN}C of high, rise = up more than ${FF_TEMP_RISE}C over the run):"
            awk 'NR > 1 && $6 != "none" {n++; if (!($1 in h)) {h[$1] = 1; nh++}; if ($12 != "-") {f++; if (!($1 in fh)) {fh[$1] = 1; nf++}}}
                 END {printf "  %d sensors on %d hosts; %d flagged on %d hosts\n", n, nh, f, nf}' "$ts"
            # per host the hottest reading of each type
            awk 'NR > 1 && $6 != "none" {if (!(($1, $3) in m) || $8 > m[$1, $3]) m[$1, $3] = $8; hs[$1] = 1; if ($12 != "-") fl[$1] = fl[$1] (fl[$1] == "" ? "" : ",") $3 ":" $12}
                 END {print "Host CPU_max NVMe_max NIC_max Other_max BMC_max Flags"
                      for (x in hs) printf "%s %s %s %s %s %s %s\n", x, (((x, "cpu") in m) ? m[x, "cpu"] : "-"), (((x, "nvme") in m) ? m[x, "nvme"] : "-"),
                          (((x, "nic") in m) ? m[x, "nic"] : "-"), (((x, "other") in m) ? m[x, "other"] : "-"), (((x, "bmc") in m) ? m[x, "bmc"] : "-"), (x in fl ? fl[x] : "-")}' "$ts" \
                | { read -r hdr; echo "$hdr"; sort -k7,7r -k1,1V; } | column -t | sed 's/^/  /'
            if awk 'NR > 1 && $12 != "-" && $12 !~ /^nodata/ {f = 1} END {exit !f}' "$ts"; then
                echo "  Flagged sensors (Host Source Type Chip Dev Sensor First Max Last High Crit Flag):"
                awk 'NR > 1 && $12 != "-" && $12 !~ /^nodata/' "$ts" | sort -k12,12 -k8,8nr | column -t | sed 's/^/    /'
            fi
            awk 'NR > 1 && $12 ~ /^nodata/ {printf "  NO TEMPERATURE DATA: %s %s (%s)\n", $1, $2, substr($12, 8)}' "$ts"
            echo ""
        elif (( FF_TEMPS )); then
            local tn; tn=$(( $(wc -l < "$COLLECT_DIR/temps.txt") - 1 ))
            if (( tn > 0 )); then echo "Temperatures: ERROR: temps.txt has $tn readings but temps_summary.txt is empty (summary failed); read temps.txt"
            else echo "Temperatures: NO TEMPERATURE DATA from any host (temps.txt empty)"; fi; echo ""
        fi
        # data NIC map: ip role host nic rail line_gbps (clients: FF_CLIENT_GBPS, else the NIC's own speed, 0 = unknown)
        if (( ${#CLI[@]} )); then
            awk -v cg="${FF_CLIENT_GBPS:-0}" 'NR > 1 && $4 != "none" {s = $7; sub(/Mb\/s/, "", s); print $4, $1, $3, (cg > 0 ? cg : (s ~ /^[0-9]+$/ ? s / 1000 : 0))}' \
                "$COLLECT_DIR/clients.txt" > "$WORK/cmap"
        else : > "$WORK/cmap"; fi
        # every expected data NIC gets a row, an unusable one too (no address, link down): key ip line_gbps mtu state;
        # a rail the host lacks or does not address is no row (the rails block counted it; rails.txt keeps it)
        local k r; : > "$WORK/cres0"
        { for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do case ${RSTATE[$k,$r]} in "no NIC "*|"no IPv4 on "*) continue ;; esac
              echo "$( [[ ${RIP[$k,$r]} == none ]] && echo "none_${T_HOST[$k]}_$(rail_letter $r)" || echo "${RIP[$k,$r]}") backend ${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r) ${LINE[r]:-0} ${RMTU[$k,$r]:-1500} ${RSTATE[$k,$r]// /_}"; done; done
          (( ${#CLI[@]} )) && awk -v cg="${FF_CLIENT_GBPS:-0}" 'NR > 1 {s = $7; sub(/Mb\/s/, "", s)
              print ($4 == "none" ? "none_" $1 "_" $3 : $4), "client", $1, $3, "-", (cg > 0 ? cg : (s ~ /^[0-9]+$/ ? s / 1000 : 0)), ($5 ~ /^[0-9]+$/ ? $5 : 1500), $6}' "$COLLECT_DIR/clients.txt"; } > "$WORK/dnmap"
        if grep -q 'Gbits/sec' "$RESULTS" || { (( ${#CLI[@]} )) && grep -q 'Gbits/sec' "$CRESULTS"; }; then
            echo "Throughput per data NIC, backends and clients, worst first (Gbps; Same: backend to backend on its rail$( (( NR > 1 )) && echo "; Cross: $( (( NR == 2 )) && echo "A<->B" || echo "rail-to-rail") runs, judged at the slower rail's rate")$( (( ${#CLI[@]} )) && echo "; CB_Out / CB_In: client<->backend runs this NIC sent / received; All_: the all-at-once phase"); Expect: the lowest expected rate over its runs; Status: each column's average share of its expected rate, worst, (retr) when Retr_% is above $FF_RETR_PCT (FF_RETR_PCT); Retr: TCP retransmits over the runs it sent, Retr_% of the segments it sent; a NIC with no runs shows its rail state):"
            awk -F'[, ]+' -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT" -v rl="$FF_RETR_PCT" -v cl=${#CLI[@]} "$NIC_SUM_AWK" "$WORK/dnmap" "$RESULTS" "$( (( ${#CLI[@]} )) && echo "$CRESULTS" || echo "$WORK/cres0")" \
                | { read -r hdr; echo "$hdr"; sort -k1,1nr -k2,2n -k4,4V; } | cut -d' ' -f3- | column -t | sed 's/^/  /'
        fi
        if grep -q 'Gbits/sec' "$RESULTS"; then
            cross_summary "$map" "$RESULTS"
            uplink_summary "$map" "$LLDP_DATA" "$NIC_DIAG" "$RESULTS"
        else
            if (( FF_SKIP_IPERF )); then
                echo "Bandwidth not tested (FF_SKIP_IPERF=1). Path checks (route, ping, MTU no-fragment): $(wc -l < "$WORK/paths_ok" | tr -d ' ') of $PATHS_PLANNED planned OK; the rest are in paths_excluded.txt."
            else echo "  No iperf3 results collected."; fi
        fi
        echo ""
        # receive side: flagged hosts only; every host's row is in host_rx.txt and on the dashboard
        local nrx nfl; nrx=$(( $(wc -l < "$COLLECT_DIR/host_rx.txt") - 1 )); nfl=$(awk 'NR > 1 && $NF != "-"' "$COLLECT_DIR/host_rx.txt" | wc -l | tr -d ' ')
        echo "Host-side receive: $nfl of $nrx hosts flagged (host_rx.txt; PCIe as GT/s x width, current/max; CPU: iperf3 process %, max over runs, and per thread (iperf3 3.16+: one thread per stream), flagged at 90):"
        (( nfl > 0 )) && awk 'NR == 1 || $NF != "-"' "$COLLECT_DIR/host_rx.txt" | column -t | sed 's/^/  /'
        if [[ -f $COLLECT_DIR/client_rx.txt ]]; then   # the same columns for the clients, NIC 1..N in clients.txt order
            nrx=$(( $(wc -l < "$COLLECT_DIR/client_rx.txt") - 1 )); nfl=$(awk 'NR > 1 && $NF != "-"' "$COLLECT_DIR/client_rx.txt" | wc -l | tr -d ' ')
            echo "Client-side receive: $nfl of $nrx clients flagged (client_rx.txt; columns as above, _1.._N = the client's data NICs in clients.txt order):"
            (( nfl > 0 )) && awk 'NR == 1 || $NF != "-"' "$COLLECT_DIR/client_rx.txt" | column -t | sed 's/^/  /'
        fi
        echo ""
        echo "  Hosts on the rails: ${#ELIG[@]}, $( (( FF_SKIP_IPERF )) && echo "with a passed path check: $(awk 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" "$WORK/paths_ok" | sort -u | grep -c .)" || echo "with a result: $(grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" - | sort -u | grep -c .)") | Rails unusable: $(awk 'NR > 1 {for (i = 6; i <= NF; i += 4) n += ($i != "ok")} END {print n + 0}' "$COLLECT_DIR/rails.txt") (rails.txt) | TCP paths skipped: $(awk '$2 ~ /^[12]$/' "$PATH_EXCL" | wc -l | tr -d ' ') (paths_excluded.txt)"
        echo "  Runs with no result: $(grep -c ',ERROR' "$RESULTS")$( grep -q ',ERROR' "$RESULTS" && echo " (iperf3's reason, runs, destinations):")"
        err_hist "$RESULTS" | sed 's/^/    /'
        echo "  Directed NIC paths planned: ${#DIRECTED[@]} of $DIRECTED_TOTAL$( (( ${#DIRECTED[@]} < DIRECTED_TOTAL )) && echo " (all of them: FF_ITER=all)")"
        if [[ $FF_UDP == 1 ]]; then
            echo ""
            if grep -q 'Gbits/sec' "$UDP_RESULTS"; then
                echo "UDP (-b 0) by receiving host: avg Gbps per run, datagrams lost/sent, loss %:"
                echo "  Expected_% = the loss the offered load alone guarantees: what the senders sent into a NIC above its line rate"
                # udp_expected.txt: iterN phase wave src dst offered rx expected lost sent gbps tx
                awk 'NR == FNR { host[$1] = $2; next }
                    { h = host[$5]; gs[h] += $11; c[h]++; l[h] += $9; s[h] += $10; e[h] += $8 * ($10 - $12) }
                    END { print "Host Avg_Gbps Lost/Sent Loss_% Expected_%"
                          for (h in c) printf "%s %.1f %d/%d %.3f %.3f\n", h, gs[h] / c[h], l[h], s[h], s[h] ? 100 * l[h] / s[h] : 0, s[h] ? 100 * e[h] / s[h] : 0 }' \
                    "$WORK/uipmap" "$COLLECT_DIR/udp_expected.txt" | { read -r hdr; echo "$hdr"; sort -k4 -rn; } | column -t | sed 's/^/  /'
                local r; read -r -a r <<<"$(udp_attr "")"
                echo "  Lost datagrams ${r[0]} of ${r[1]}: sender TX ${r[9]}, receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
                echo "  Expected from overload: ${r[7]}; unaccounted beyond it (likely fabric): ${r[8]}"
            else
                echo "  No UDP results collected."
            fi
            echo "  UDP runs with no result: $(grep -c ',ERROR' "$UDP_RESULTS")$( grep -q ',ERROR' "$UDP_RESULTS" && echo " (iperf3's reason, runs, destinations):")"
            err_hist "$UDP_RESULTS" | sed 's/^/    /'
        fi
        if (( ${#CLI[@]} )); then
            echo ""
            cat "$WORK/ipmap" > "$WORK/cipmap"; awk '{print $1, $2, "client"}' "$WORK/cmap" >> "$WORK/cipmap"
            if grep -q 'Gbits/sec' "$CRESULTS"; then
                echo "Clients (per client NIC rows are in the per data NIC table above):"
                awk -F'[, ]+' -v lines="$RAIL_LINES" -v ok="$FF_OK_PCT" -v slow="$FF_SLOW_PCT" "$CLIENT_SUM_AWK" "$WORK/cmap" "$WORK/ipmap" "$CRESULTS" > "$WORK/csum"
                awk 'function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
                     $1 == "#TOTAL" {printf "  All at once, %s: %s flows, %s in total%s\n", ($2 == "F1" ? "clients -> backends" : "backends -> clients"), $3, bw($4), ($6 > 1 ? sprintf(" on average over %d iterations (lowest %s)", $6, bw($5)) : "")}' "$WORK/csum"
                # client leaves: the client runs against each leaf's side
                uplink_summary client "$WORK/cipmap" "$LLDP_DATA" "$NIC_DIAG" "$CRESULTS"
            elif (( FF_SKIP_IPERF )); then
                echo "Clients: bandwidth not tested (FF_SKIP_IPERF=1). Client path checks: $(wc -l < "$WORK/cpaths_ok" | tr -d ' ') of $CL_PLANNED OK; the rest are in paths_excluded.txt."
            else echo "  No client iperf3 results collected."; fi
            echo "  Client runs with no result: $(grep -c ',ERROR' "$CRESULTS") | client paths skipped: $(awk '$2 ~ /^[CF][12]$/' "$PATH_EXCL" | wc -l | tr -d ' ') (paths_excluded.txt) | undeclared client routes: $(awk '$6 == "undeclared"' "$COLLECT_DIR/client_routes.txt" | wc -l | tr -d ' '), clients with routes unread: $(awk '$6 == "unread"' "$COLLECT_DIR/client_routes.txt" | wc -l | tr -d ' ') (client_routes.txt)"
                err_hist "$CRESULTS" | sed 's/^/    /'
        fi
        # leaves that serve clients and backends (LLDP)
        if (( ${#CLI[@]} )); then
            awk 'NR == FNR {kind[$1] = $3; next} ($3 in kind) && $4 != "unknown" && $4 != "" {if (kind[$3] == "client") c[$4]++; else b[$4]++}
                 END {for (l in c) if (l in b) printf "%s shared_leaf switch serves %d client NICs and %d backend NICs; judged as a backend leaf\n", l, c[l], b[l]}' \
                "$WORK/cipmap" "$LLDP_DATA" >> "$COLLECT_DIR/rail_anomalies.txt"
        fi
        echo "=================================================================="
    } >&2

    # --- 8. coverage verdict: never a clean result on partial or empty data ---
    local expect hosts_tested paths_ok skipped noresult coverage cov_rc
    if [[ -n $FF_EXPECT_HOSTS ]]; then expect=$FF_EXPECT_HOSTS
    elif (( INPUT_RANGES )); then expect=$(( ${#ELIG[@]} + NUNUSE_B ))   # a host that answered but can't run the steps is missing, not normal
    else expect=$(( NHT - (dups - cdups) )); fi
    if (( FF_SKIP_IPERF )); then   # no load: a path counts once its check passed
        hosts_tested=$(awk 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" "$WORK/paths_ok" | sort -u | grep -c .)
        paths_ok=$(wc -l < "$WORK/paths_ok" | tr -d ' ')
    else
        hosts_tested=$(grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" - | sort -u | grep -c .)
        paths_ok=$(grep -c 'Gbits/sec' "$RESULTS")
    fi
    skipped=$(awk '$2 ~ /^[12]$/' "$PATH_EXCL" | wc -l | tr -d ' ')
    noresult=$(grep -c ',ERROR' "$RESULTS")
    # clients: tested = a client with a result (a passed path check with FF_SKIP_IPERF=1); expected as for hosts
    local cl_expect=0 cl_tested=0 cl_paths_ok=0 cl_done=1
    if [[ $CLIENT_MODE != none ]]; then
        if [[ -n $FF_EXPECT_CLIENTS ]]; then cl_expect=$FF_EXPECT_CLIENTS
        elif (( CL_RANGES )); then cl_expect=$(( ${#CLI[@]} + NUNUSE_C ))
        else cl_expect=$(( ${#CL_T[@]} - cdups )); fi
        local cok; if (( FF_SKIP_IPERF )); then cok=$(cat "$WORK/cpaths_ok"); else cok=$(grep 'Gbits/sec' "$CRESULTS" | awk -F'[, ]+' '{print $1, $2}'); fi
        cl_paths_ok=$(grep -c . <<<"$cok")
        cl_tested=$(awk 'NR == FNR {h[$1] = $2; next} ($1 in h) {print h[$1]} ($2 in h) {print h[$2]}' "$WORK/cmap" - <<<"$cok" | sort -u | grep -c .)
        (( cl_tested >= cl_expect && cl_paths_ok >= CL_PLANNED )) || cl_done=
    fi
    if (( paths_ok == 0 )); then coverage=NONE; cov_rc=4
    elif (( hosts_tested >= expect && paths_ok >= PATHS_PLANNED )) && [[ -n $cl_done ]]; then coverage=COMPLETE; cov_rc=0
    else coverage=PARTIAL; cov_rc=3; fi
    local RESULT_LINE="RESULT coverage=$coverage hosts=$hosts_tested/$expect paths=$paths_ok/$PATHS_PLANNED skipped=$skipped no_result=$noresult"
    [[ $CLIENT_MODE != none ]] && RESULT_LINE+=" clients=$cl_tested/$cl_expect client_paths=$cl_paths_ok/$CL_PLANNED client_no_result=$(grep -c ',ERROR' "$CRESULTS")"
    RESULT_LINE+=" cross_rail=$( (( CROSS_UNROUTED )) && echo unrouted || echo "$CROSS")"
    (( FF_SKIP_IPERF )) && RESULT_LINE+=" iperf=skipped (FF_SKIP_IPERF=1: paths = path checks passed, no bandwidth tested)"
    (( INPUT_RANGES )) && [[ -z $FF_EXPECT_HOSTS ]] && RESULT_LINE+=" (hosts expected = hosts found on the rails; set FF_EXPECT_HOSTS to check for missing ones)"

    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    {
        echo "label=$LABEL"
        echo "timestamp=$START_TS"
        echo "end_timestamp=$ts"
        echo "duration=$FF_DURATION"
        echo "iterations=$FF_ITER"
        echo "parallel_streams=$FF_STREAMS"
        echo "total_hosts=${#ELIG[@]}"
        echo "targets_input=$NHT"
        echo "targets_reachable=${#REACH[@]}"
        echo "rail_mode=$RAIL_MODE"
        echo "rail_count=$NR"
        for r in "${RAILS[@]}"; do L=$(rail_letter $r); echo "rail_$(tr 'A-Z' 'a-z' <<<"$L")=${RAIL_SPEC[r]// /,}"; done
        echo "line_rate_gbps=${LINE_GBPS:-unknown}"
        for r in "${RAILS[@]}"; do L=$(rail_letter $r); echo "line_rate_$(tr 'A-Z' 'a-z' <<<"$L")_gbps=${LINE[r]:-unknown}"; done
        echo "clients=$( [[ $CLIENT_MODE != none ]] && echo 1 || echo 0)"
        if [[ $CLIENT_MODE != none ]]; then
            echo "client_mode=$CLIENT_MODE"
            echo "client_spec=$(IFS=,; echo "${CLIENT_SPEC[*]}")"
            echo "client_ratio=$FF_CLIENT_RATIO"
            echo "client_line_gbps=${FF_CLIENT_GBPS:-nic}"
            echo "client_targets=${#CL_T[@]}"
            echo "clients_expected=$cl_expect"
            echo "clients_tested=$cl_tested"
            echo "client_paths_planned=$CL_PLANNED"
            echo "client_paths_ok=$cl_paths_ok"
            echo "client_waves=$CL_NW"
            echo "client_servers_per_nic=$CL_K"
            echo "client_spine_links=${FF_CLIENT_SPINE_LINKS:-none}"
            echo "client_spine_gbps=${FF_CLIENT_SPINE_GBPS:-none}"
        fi
        echo "ok_pct=$FF_OK_PCT"
        echo "slow_pct=$FF_SLOW_PCT"
        echo "retr_pct=$FF_RETR_PCT"
        echo "temps=$FF_TEMPS"
        echo "ipmi=$FF_IPMI"
        echo "temp_margin=$FF_TEMP_MARGIN"
        echo "temp_rise=$FF_TEMP_RISE"
        echo "spines=${FF_SPINES:-none}"
        echo "spine_links=${FF_SPINE_LINKS:-none}"
        echo "spine_gbps=${FF_SPINE_GBPS:-none}"
        echo "busy_hosts=${#BUSY[@]}"
        echo "port=$FF_PORT"
        echo "tos=${FF_TOS:-none}"
        echo "pairing=round-robin"
        echo "pairs_covered=$PAIRS_COVERED"
        echo "pairs_total=$PAIRS_TOTAL"
        echo "udp=$FF_UDP"
        echo "iperf=$( (( FF_SKIP_IPERF )) && echo skipped || echo run)"
        echo "udp_duration=$FF_UDP_DURATION"
        echo "coverage=$coverage"
        echo "hosts_expected=$expect"
        echo "hosts_tested=$hosts_tested"
        echo "paths_planned=$PATHS_PLANNED"
        echo "directed_paths=${#DIRECTED[@]}"
        echo "directed_paths_total=$DIRECTED_TOTAL"
        echo "cross_max=${FF_CROSS_MAX:-none}"
        echo "sysinfo_hosts=$( [[ -d $SI ]] && ls "$SI" | wc -l | tr -d " " || echo 0)"
        echo "cross_rail=$( (( CROSS_UNROUTED )) && echo unrouted || echo "$CROSS")"
        echo "paths_ok=$paths_ok"
        echo "drop_nics_read_min=$DROP_READS_MIN"
        local ncl=0; for k in "${CLI[@]}"; do ncl=$(( ncl + CN[$k] )); done
        # the rail NICs that exist (a host lacking a rail has none there: a 10-27 field run read 478 of a hosts x rails 717)
        local nex=0; for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do [[ ${RNIC[$k,$r]} != - ]] && nex=$(( nex + 1 )); done; done
        echo "drop_nics_expected=$(( nex + ncl ))"
        echo "nic_diag_lines=$(wc -l < "$NIC_DIAG" | tr -d ' ')"
        echo "mesh_pings=${MESH_PINGS:-}"
        echo "mesh_failures=${MESH_FAILS:-}"
        echo "mesh_client_pings=${MESH_CPINGS:-}"
        echo "mesh_client_failures=${MESH_CFAILS:-}"
        echo "tool=fabric_ferret"
    } > "$COLLECT_DIR/metadata.txt"
    for k in "${ELIG[@]}"; do
        local hl="${T_HOST[$k]} ${T_TARGET[$k]}"; for r in "${RAILS[@]}"; do hl+=" ${RIP[$k,$r]}"; done; for r in "${RAILS[@]}"; do hl+=" ${RNIC[$k,$r]}"; done
        echo "$hl"
    done | sort -V > "$COLLECT_DIR/host_list.txt"
    printf '%s\n' "${!DOWN_IP[@]}" | grep . | sort -V > "$COLLECT_DIR/down_ips.txt"

    local tarball=$FF_OUT_DIR/fabric_ferret_${LABEL}_${ts}.tgz
    stop_servers
    DONE=1; save_state
    [[ -n $FF_RUNLOG && -f $FF_RUNLOG ]] && cp "$FF_RUNLOG" "$COLLECT_DIR/run.log"
    COPYFILE_DISABLE=1 tar czf "$tarball" -C "$(dirname "$COLLECT_DIR")" "$(basename "$COLLECT_DIR")" || die "tar failed; data left in $COLLECT_DIR"
    log "Data archive: $tarball ($(du -h "$tarball" | cut -f1))"
    local abs; abs=$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")
    if [[ -n $SSH_CONNECTION ]]; then   # ran on a jump host: say how to fetch it
        local srv; srv=$(awk '{print $3}' <<<"$SSH_CONNECTION")
        # SSH_CONNECTION shows the address this host sees; behind NAT that is private, so name the host too
        log "Fetch and render: scp $(id -un)@$srv:$abs . && python3 generate_dashboard.py $(basename "$tarball")"
        log "  ($srv is this jump host's own address; from outside use the address you ssh to, e.g. $(hostname -f 2>&1 | head -n1))"
    else
        log "Render: python3 generate_dashboard.py $abs"
    fi
    rm -rf "${COLLECT_DIR:?}"
    echo "$RESULT_LINE" >&2
    exit $cov_rc   # exit, not return: bash 5.1 drops a piped function's return status under an EXIT trap
}

START_TS=$(date -u +%Y%m%dT%H%M%SZ)
# Run when executed or fed on stdin (ssh jump 'bash -s' < script: BASH_SOURCE is empty); not when sourced.
# stderr is copied to the run log by tee in a pipeline, not a process substitution: bash 5.1's
# bare `wait` also waits for a process substitution, which never exits while main runs.
# tee ignores INT/TERM/HUP (Ctrl-C, group kill, dropped session) so cleanup can still write.
if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    FF_RUNLOG=$(mktemp "${TMPDIR:-/tmp}/ff_runlog.XXXXXX") || exit 2
    STATE_FILE=$FF_RUNLOG.state
    trap ':' INT TERM HUP   # keep waiting for main's cleanup on Ctrl-C or a group kill (a no-op trap, so main gets its own)
    { main "$@" 2>&1 1>&3 3>&- | ( trap '' INT TERM HUP; exec tee -a "$FF_RUNLOG" >&2 3>&- ); rc=${PIPESTATUS[0]}; } 3>&1
    if [[ -s $STATE_FILE ]]; then   # main ended without finishing its cleanup: do it here, with main's state and exit code
        echo "# Run ended (rc=$rc) without its cleanup; finishing it now" | tee -a "$FF_RUNLOG" >&2
        ( source "$STATE_FILE"; (exit "$rc"); cleanup )
    fi
    rm -f "$FF_RUNLOG" "$STATE_FILE.tmp"
    exit "$rc"
fi
