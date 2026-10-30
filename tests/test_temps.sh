# TEMP_SCRIPT on a fake sysfs: test_temps.sh <collector.sh> <workdir> <case>
# case all: coretemp (package + core, high/crit), k10temp (Tctl, no thresholds), nvme (Composite, max/crit),
# mlx5 hwmon on a PCI device with net/enp5s0np0, ice on net/ens1f0, a power-only chip (no temp inputs);
# ipmitool stub with inlet/exhaust (thresholds), a fan line (not degrees C) and a "na" reading.
# case nochips: hwmon class present, no temp inputs; ipmitool missing.  case nohwmon: no hwmon dir; ipmitool fails.
C=$1; T=$2/fakesys_temps_$3; rm -rf "${T:?}"; mkdir -p $T/class/hwmon $T/devices/pci0/net/enp5s0np0 $T/devices/pci1/net/ens1f0 $T/devices/nvme0 $T/devices/coretemp.0 $T/devices/k10
mk() { local d=$T/class/hwmon/$1; mkdir -p $d; echo "$2" > $d/name; ln -s ../../../devices/$3 $d/device; }   # as sysfs: relative to the hwmon dir
sv() { echo "$3" > $T/class/hwmon/$1/$2; }
case $3 in
all)
    mk hwmon0 coretemp coretemp.0; sv hwmon0 temp1_label 'Package id 0'; sv hwmon0 temp1_input 71000; sv hwmon0 temp1_max 80000; sv hwmon0 temp1_crit 100000
    sv hwmon0 temp2_label 'Core 0'; sv hwmon0 temp2_input 68000; sv hwmon0 temp2_max 80000; sv hwmon0 temp2_crit 100000
    mk hwmon1 k10temp k10; sv hwmon1 temp1_label Tctl; sv hwmon1 temp1_input 55125
    mk hwmon2 nvme nvme0; sv hwmon2 temp1_label Composite; sv hwmon2 temp1_input 44850; sv hwmon2 temp1_max 84850; sv hwmon2 temp1_crit 84850
    mk hwmon3 mlx5 pci0; sv hwmon3 temp1_input 62000; sv hwmon3 temp1_crit 105000
    mk hwmon4 ice pci1; sv hwmon4 temp1_input 58000; sv hwmon4 temp1_max 96000; sv hwmon4 temp1_crit 102000
    mk hwmon5 acpi_power_meter k10; sv hwmon5 power1_input 350000000
    ipmitool() { cat <<'IPMI'
Inlet Temp       | 24.000     | degrees C  | ok    | na        | -7.000    | -2.000    | 38.000    | 42.000    | na
Exhaust Temp     | 52.000     | degrees C  | nc    | na        | 3.000     | 8.000     | 50.000    | 55.000    | na
Fan1             | 8400.000   | RPM        | ok    | na        | 600.000   | 840.000   | na        | na        | na
Temp             | na         | degrees C  | na    | na        | na        | na        | 85.000    | 90.000    | na
IPMI
    } ;;
nochips) mk hwmon0 acpi_power_meter k10; sv hwmon0 power1_input 1
         mkdir -p $T/bin; for c in cat tr readlink head cut awk date printf mkdir; do ln -s "$(command -v $c)" $T/bin/$c; done; PATH=$T/bin ;;   # no ipmitool
nohwmon) rmdir $T/class/hwmon; ipmitool() { echo "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0: No such file or directory"; return 1; } ;;
esac
source "$C"
# not root here (the reader runs as the login): its probe takes this dzdo stub, first in its list, so this Mac's sudo is never run
hostname() { echo hx; }; timeout() { shift; "$@"; }; dzdo() { [ "$1" = -n ] && shift; "$@"; }
export FF_SYSFS=$T; set -- ipmi 60
( eval "$TEMP_SCRIPT" )
