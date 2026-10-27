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
