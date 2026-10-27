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
# rbash [-T secs] target args...: stdin as a bash script on the target, under SUDO; -T: cut off after secs
rbash() {
    local -a to=(); [[ $1 == -T ]] && { to=(timeout "$2"); shift 2; }
    local t=$1; shift
    "${to[@]}" ssh "${SSH_OPTS[@]}" -l "${TL[$t]:-$FF_SSH_USER}" "$t" $SUDO bash -s -- "$@"
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
    if have lldpcli; then lldp=$(lldpcli show neighbors ports "$nic" 2>&1); else lldp=""; fi
    chassis=$(echo "$lldp" | awk -F': *' '/SysName:/{gsub(/ /,"_",$2); print $2; exit}')
    portid=$(echo "$lldp" | awk '/PortID:/{print $NF; exit}')
    portdesc=$(echo "$lldp" | awk -F': *' '/PortDescr:/{gsub(/ /,"_",$2); print $2; exit}')
    sysdesc=$(echo "$lldp" | awk -F': *' '/SysDescr:/{gsub(/ /,"_",$2); print $2; exit}')
    echo "@@LLDP $h $nic ${ip:-none} ${chassis:-unknown} ${portid:-unknown} ${portdesc:-unknown} ${sysdesc:-unknown}"
    f() { echo "$inf" | awk -F': ' -v k="$1" '$1==k {print $2; exit}'; }
    drv=$(f driver); ver=$(f version); ver=${ver// /_}; fw=$(f firmware-version); bus=$(f bus-info)
    echo "@@DRV $h $nic ${ip:-none} ${drv:-unknown} ${ver:-unknown} ${fw:-unknown} ${bus:-unknown}"
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
