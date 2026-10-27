#!/usr/bin/env bash
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
  FF_SPINES        leaf-spine uplinks, all three or none (no defaults): spines, links from each
  FF_SPINE_LINKS   backend leaf to each spine, Gbps per link. The summary always sums each leaf's runs
  FF_SPINE_GBPS    to other leaves per phase (leaf = LLDP neighbour); with these set it judges them
                   against spines x links x Gbps per direction: oversubscribed by design, or a
                   lost link/spine. Status is unchanged.
  FF_CLIENT_SPINE_LINKS, FF_CLIENT_SPINE_GBPS  the same for client leaves (both or neither; they need
                   FF_SPINES: one spine layer serves both). A leaf that serves both clients and backends
                   is flagged and judged as a backend leaf.
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
# iperf3's prefix keeps its own text. Frank's 10-27 run: 138 rows, one reason, 48 destinations, 9 that answered.
err_hist() {
    cat "$@" | tr -s ' ' | awk -F, '$3 ~ /^ *ERROR/ {
        s = $0; sub(/^[^,]*,[^,]*, */, "", s); i = index(s, "iperf3: error - ")
        if (i) s = substr(s, i + 16); else sub(/^ERROR *(rc=[0-9]+)? */, "", s)
        if (!(s in n)) ord[++no] = s
        n[s]++; if (!(($2, s) in seen)) { seen[$2, s] = 1; nd[s]++; if (nd[s] <= 4) dl[s] = dl[s] " " $2 } }
        END { for (i = 1; i <= no; i++) { s = ord[i]; printf "%d x \"%s\" to %d destination%s (%s%s)\n", n[s], s, nd[s], (nd[s] == 1 ? "" : "s"), substr(dl[s], 2), (nd[s] > 4 ? " ..." : "") } }' | sort -t x -k1,1nr
}
log_hist() { err_hist "$@" | sed 's/^/#   /' >&2; }

# ---------- target expansion (pure bash, no ssh) ----------

#@include sh/ipaddr.sh

#@include sh/ff_in_cidr.sh

#@include sh/expand.sh

#@include sh/hostfile.sh

#@include sh/auth.sh

#@include sh/ff_rails.sh

#@include sh/ff_remote.sh

#@include sh/ff_discovery.sh

#@include sh/ff_locks.sh

#@include sh/ff_mesh.sh

#@include sh/ff_paths.sh

#@include sh/ff_collect.sh

#@include sh/ff_hostrx.sh

#@include sh/ff_results.sh

#@include sh/ff_clients.sh

#@include sh/ff_nicsum.sh

#@include sh/ff_teardown.sh

# Every FF_* setting this tool reads. Any other FF_* in the environment is a typo that would be silently
# ignored (a dropped letter, say), so it stops the run. A regress test keeps the list complete.
FF_KNOWN="FF_BUSY_CHECK FF_BUSY_OK FF_CLIENT_GBPS FF_CLIENT_NETS FF_CLIENT_NICS FF_CLIENT_RATIO FF_CLIENT_SPINE_GBPS FF_CLIENT_SPINE_LINKS FF_CLIENTS FF_CROSS_MAX FF_CROSS_RAIL FF_DURATION FF_EXPECT_CLIENTS FF_EXPECT_HOSTS FF_HOSTS FF_IGNORE_LOCK FF_ITER FF_LABEL FF_LINE_GBPS FF_LOCK_FILE FF_MAX_TARGETS FF_MESH FF_NICS FF_OK_PCT FF_OUT_DIR FF_PORT FF_RAILS FF_RETR_PCT FF_RUNLOG FF_SKIP_IPERF FF_SLOW_PCT FF_SPINE_GBPS FF_SPINE_LINKS FF_SPINES FF_SSH_PARALLEL FF_SSH_RETRY_PARALLEL FF_SSH_USER FF_STREAMS FF_SYSFS FF_SYSINFO_TIMEOUT FF_TEMP_MARGIN FF_TEMP_RISE FF_TEMPS FF_IPMI FF_IPMI_TIMEOUT FF_TOS FF_UDP FF_UDP_DURATION"

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

    : "${FF_ITER:=3}" "${FF_STREAMS:=16}" "${FF_PORT:=5201}" "${FF_SSH_USER:=$(id -un)}"
    : "${FF_SSH_PARALLEL:=64}" "${FF_SSH_RETRY_PARALLEL:=8}" "${FF_MAX_TARGETS:=4096}" "${FF_OUT_DIR:=.}"
    : "${FF_OK_PCT:=75}" "${FF_SLOW_PCT:=50}" "${FF_BUSY_OK:=0}" "${FF_SYSINFO_TIMEOUT:=300}" "${FF_RETR_PCT:=0.1}"
    [[ $FF_RETR_PCT =~ ^([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] || die "FF_RETR_PCT must be a number (% of TCP segments sent), got '$FF_RETR_PCT'"
    : "${FF_TEMPS:=1}" "${FF_IPMI:=1}" "${FF_TEMP_MARGIN:=5}" "${FF_TEMP_RISE:=10}" "${FF_IPMI_TIMEOUT:=60}"
    [[ $FF_TEMPS == 0 || $FF_TEMPS == 1 ]] || die "FF_TEMPS must be 0 or 1, got '$FF_TEMPS'"
    [[ $FF_IPMI == 0 || $FF_IPMI == 1 ]] || die "FF_IPMI must be 0 or 1, got '$FF_IPMI'"
    local tv; for tv in FF_TEMP_MARGIN FF_TEMP_RISE FF_IPMI_TIMEOUT; do
        [[ ${!tv} =~ ^[0-9]+$ ]] || die "$tv must be a whole number, got '${!tv}'"
    done
    # Default busy check: any WEKA container in STATE Running (docs.weka.io CLI reference, `weka local ps`)
    : "${FF_BUSY_CHECK:=$WEKA_BUSY_CHECK}"
    [[ $FF_BUSY_CHECK == none ]] && FF_BUSY_CHECK=""
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
    [[ -n $dur ]] && FF_DURATION=$dur
    : "${FF_DURATION:=120}" "${FF_MESH:=1}" "${FF_SKIP_IPERF:=0}"
    [[ $FF_SSH_USER =~ ^[A-Za-z0-9._@-]+$ ]] || die "FF_SSH_USER: bad login (letters, digits . _ @ - only)"
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
    # line per rail and state, the first 8 hosts named (Frank's 10-27 fleet: 112 hosts, two such rails each); a host
    # with any other bad rail (link DOWN, no address in the subnet, AMBIGUOUS) keeps its full row
    local bad_rails; bad_rails=$(awk '#@awk ff_main.bad_rails' "$COLLECT_DIR/rails.txt")
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
    : > "$NIC_DIAG"; : > "$LLDP_DATA"; : > "$DRV_DATA"
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        throttle
        rbash "${T_TARGET[$k]}" $(host_nics $k) <<<"$DIAG_SCRIPT" > "$WORK/diag.$k" 2>&1 &
    done
    wait
    for k in "${ELIG[@]}" "${CLI[@]}"; do
        grep '^@@NIC_DIAG ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$NIC_DIAG"
        grep '^@@LLDP ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$LLDP_DATA"
        grep '^@@DRV ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$DRV_DATA"
        grep -v '^@@' "$WORK/diag.$k" > "$RAW_DIR/${T_HOST[$k]}.txt"
    done
    log "Diagnostics: $(wc -l < "$NIC_DIAG" | tr -d ' ') NIC, $(wc -l < "$LLDP_DATA" | tr -d ' ') LLDP, $(wc -l < "$DRV_DATA" | tr -d ' ') driver lines"
    lldp_rail_check "$LLDP_DATA"

    # line rate: per rail only when declared (FF_LINE_GBPS=A,B,...); otherwise the fastest rail's most common
    # speed for every rail, so a whole rail that came up slow is not judged against itself. Only a usable rail's
    # NIC votes (iprail: "host nic letter", rails in state ok); a NIC a host has but does not address, or a rail
    # it lacks, has no say and no rail letter (Frank's GPU fleet: 112 bond members with no IPv4 voted as rail B)
    local -a LINE=() MODE=() VOTE=() TOT=() fl=(); local LINE_GBPS k v
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do rail_ok $k $r && echo "${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r)"; done; done > "$WORK/iprail"
    if [[ -n $FF_LINE_GBPS ]]; then
        IFS=, read -r -a fl <<<"$FF_LINE_GBPS"
        for r in "${RAILS[@]}"; do LINE[r]=${fl[r]:-${fl[0]}}; done
    else
        # per rail "mode/voters/total": the most common speed, how many NICs run at it, how many voted
        read -r -a MODE <<<"$(awk -v L="${LETTERS:0:NR}" '#@awk ff_main.rail_speed' "$WORK/iprail" "$NIC_DIAG")"
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
        awk -v lines="$RAIL_LINES" '#@awk ff_main.speed_mismatch' \
            "$WORK/iprail" "$NIC_DIAG" > "$WORK/offspeed"
        if [[ -s $WORK/offspeed ]]; then
            if [[ -n $same ]]; then log "NICs not at ${LINE[0]}G:"; else log "NICs not at their rail's speed:"; fi
            cat "$WORK/offspeed" >&2
        fi
    else
        log "WARNING: no link speed from ethtool and FF_LINE_GBPS unset; no OK/SLOW status"
    fi
    if (( ${#CLI[@]} )); then   # clients.txt: the client table plus each data NIC's speed
        awk 'NR == FNR {sp[$1 " " $2] = $4; next} FNR == 1 {print $0, "Speed"; next} {print $0, (($1 " " $3) in sp && sp[$1 " " $3] ~ /^[0-9]+Mb\/s$/) ? sp[$1 " " $3] : "unknown"}' \
            "$NIC_DIAG" "$WORK/clients0" | column -t > "$COLLECT_DIR/clients.txt"
        if [[ -n $FF_CLIENT_GBPS ]]; then log "Client line rate: ${FF_CLIENT_GBPS}G (FF_CLIENT_GBPS)"
            awk -v w="$(( FF_CLIENT_GBPS * 1000 ))Mb/s" '#@awk ff_main.client_offspeed' "$COLLECT_DIR/clients.txt" > "$WORK/coffspeed"
            [[ -s $WORK/coffspeed ]] && { log "Client NICs not at ${FF_CLIENT_GBPS}G:"; cat "$WORK/coffspeed" >&2; }
        else log "Client line rate: each client NIC's own speed (a bond counts its total; set FF_CLIENT_GBPS to override): $(awk 'NR > 1 {print $7}' "$COLLECT_DIR/clients.txt" | sort | uniq -c | awk '{printf "%s%s x %s", s, $1, $2; s = ", "}')"; fi
    fi

    lock_all touch   # preflight can be long (mesh); refresh before load
    collect_sysinfo
    rx_config > "$WORK/rxcfg"
    log "Rail NIC receive config: $(awk '#@awk ff_main.rxcfg' "$WORK/rxcfg")"
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
    ROT=("${ORDER[@]}"); (( n % 2 )) && ROT+=(-)
    local rounds=$(( ${#ROT[@]} - 1 )) per=$(( n / 2 )) total=$(( n * (n - 1) / 2 ))
    # cross-rail phase: on, off when the operator says the rails are separate fabrics, single with one rail
    CROSS=on; CROSS_UNROUTED=0
    if (( NR == 1 )); then CROSS=single; log "One rail: no cross-rail phase"
    elif [[ $FF_CROSS_RAIL == 0 ]]; then CROSS=off; log "Cross-rail phase off (FF_CROSS_RAIL=0): $( (( NR == 2 )) && echo "A<->B" || echo "rail to rail") is not tested"; fi
    # rail pairs for phase 2: one per pairing cycle (2 x rounds iterations); with two rails always A,B
    UPAIRS=(); local ua ub; for (( ua = 0; ua < NR; ua++ )); do for (( ub = ua + 1; ub < NR; ub++ )); do UPAIRS+=("$ua $ub"); done; done
    local NUP=$(( ${#UPAIRS[@]} > 0 ? ${#UPAIRS[@]} : 1 )); [[ $CROSS == on ]] || NUP=1
    (( ITER_ALL )) && FF_ITER=$(( 2 * rounds * NUP > ${CL_ALL:-0} ? 2 * rounds * NUP : CL_ALL ))
    local used=$(( FF_ITER < rounds ? FF_ITER : rounds ))
    PAIRS_COVERED=$(( used * per )); PAIRS_TOTAL=$total
    PATHS_PLANNED=0; DROP_READS_MIN=-1
    log "Pairing: round-robin, $per pairs per iteration; $FF_ITER iterations cover $PAIRS_COVERED of $total host pairs$( (( FF_ITER < rounds )) && echo " (all pairs need FF_ITER=$rounds)")"
    # a pair's directed NIC paths (8 with two rails): cycle 1 runs half, cycle 2 (same pairings, client and server
    # swapped) the other half; with more rails, each further pair of cycles covers one more rail pair
    local -A DIRECTED=(); local dper=$(( NR * NR )); [[ $CROSS == on ]] || dper=$NR
    local cyc=$(( 2 * rounds * NUP )) ppp=$(( NR + ($( [[ $CROSS == on ]] && echo 2 || echo 0 )) ))
    DIRECTED_TOTAL=$(( n * (n - 1) * dper ))
    log "Directed NIC paths: $(( (FF_ITER < cyc ? FF_ITER : cyc) * per * ppp )) of $DIRECTED_TOTAL planned$( (( FF_ITER < cyc )) && echo " (every direction on every NIC pair needs FF_ITER=$cyc, or FF_ITER=all)")"
    (( FF_ITER > rounds && FF_ITER <= 2 * rounds )) && log "Iterations $(( rounds + 1 ))-$FF_ITER repeat the pairings with client and server swapped"
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
        RND=$(( (ITER - 1) % rounds )); round_pairs $RND
        if (( (ITER - 1) / rounds % 2 )); then local -a tmp=("${PC[@]}"); PC=("${PS[@]}"); PS=("${tmp[@]}"); fi
        local up=(${UPAIRS[$(( (ITER - 1) / (2 * rounds) % NUP ))]}); XA=${up[0]:-0}; XB=${up[1]:-1}
        lock_all touch
        local per=$ppp
        PATHS_PLANNED=$(( PATHS_PLANNED + per * ${#PC[@]} ))
        log "============ Iteration $ITER of $FF_ITER (${#PC[@]} pairs$( (( NR > 2 )) && [[ $CROSS == on ]] && echo "; cross-rail $(rail_letter $XA)<->$(rail_letter $XB)")) ============"
        [[ -n $SITOUT ]] && log "Sits out this iteration (odd host count): ${T_HOST[$SITOUT]}"
        for (( p = 0; p < ${#PC[@]}; p++ )); do echo "$ITER ${T_HOST[${PC[p]}]} ${T_HOST[${PS[p]}]}"; done >> "$COLLECT_DIR/pairs.txt"
        PATHS=$WORK/paths.$ITER; mkdir -p "$PATHS"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            ck=${PC[p]}; sk=${PS[p]}
            p1_paths $p check
            [[ $CROSS == on ]] && { xpaths $p; check_path p2a_$p "${X1[@]}"; check_path p2b_$p "${X2[@]}"; }
            for r in "${RAILS[@]}"; do if (( r % 2 )); then DIRECTED["$sk $r $ck $r"]=1; else DIRECTED["$ck $r $sk $r"]=1; fi; done
            [[ $CROSS == on ]] && { DIRECTED["${X1[*]}"]=1; DIRECTED["${X2[*]}"]=1; }
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
                [[ $CROSS == on ]] && { PHASE=2; xpaths $p; run_path p2a_$p "${X1[@]}" check; run_path p2b_$p "${X2[@]}" check; }
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
        awk -v it="iter$ITER" '#@awk ff_main.prio' \
            "$WORK/prio_pre" "$WORK/prio_post" > "$WORK/prio_delta"
        if [[ -s $WORK/prio_delta ]]; then
            cat "$WORK/prio_delta" >> "$COLLECT_DIR/prio_counters.txt"
            # which priority carried the bytes, per rail (shows where each rail's DSCP map put the traffic)
            log "Traffic by priority in iteration $ITER (rx+tx bytes): $(awk -v RL="${LETTERS:0:NR}" '#@awk ff_main.prio_traffic' "$WORK/nicmap" "$WORK/prio_delta")"
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
        local flaps; flaps=$(awk -v it="iter$ITER" '#@awk ff_main.flaps' "$DROPS_PRE" "$DROPS_POST")
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
            awk '#@awk ff_main.temp_counts' "$ts"
            # per host the hottest reading of each type
            awk '#@awk ff_main.temp_hosts' "$ts" \
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
          (( ${#CLI[@]} )) && awk -v cg="${FF_CLIENT_GBPS:-0}" '#@awk ff_main.client_map' "$COLLECT_DIR/clients.txt"; } > "$WORK/dnmap"
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
                awk '#@awk ff_main.udp_hosts' \
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
                awk '#@awk ff_main.client_totals' "$WORK/csum"
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
            awk '#@awk ff_main.shared_leaf' \
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
        echo "drop_nics_expected=$(( ${#ELIG[@]} * NR + ncl ))"
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
