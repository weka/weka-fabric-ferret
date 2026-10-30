#!/usr/bin/env bash
# A synthetic 253-host site for the groups that used to read a real one (02 rails, 22 LLDP; step b, 10-29): one awk,
# deterministic from the host index, written into <outdir>. usage: tools/mksite.sh <outdir> [hosts]   (hosts: default 253)
#   disc/<host>        a discovery file as fabric_ferret's discovery prints it (=== hostname / addr / link ===)
#   host_list.txt      host mgmt railA railB
#   subset.txt         the 16 hosts with a link down plus 8 healthy ones (the fast tier's 02)
#   lldp_neighbors.txt host nic ip leaf ifname port chassis - FE2/1 unknown, one row per rail NIC
#   lldp_swapped.txt   the same with host s001's two leaf names swapped: 2 lldp_wrong_rail anomalies (the control)
# Layout: racks of 32 hosts, a leaf per rail per rack (leaf-rNN-a, leaf-rNN-b, port swp<slot>s1); rail A = 198.19.{1,3,5,7}.0/24,
# rail B = 198.19.{2,4,6,8}.0/24 (subnet by i mod 4, /31 addresses as a routed site has), mgmt 198.18.100.i on eno1.100;
# every 15th host has rail B's link down (NO-CARRIER, state DOWN): 16 of 253. Every identifier is synthetic by
# construction: host names sNNN, locally administered MACs 02:00:00:0N:xx:xx, the 198.18/15 benchmarking space.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "mksite.sh: bash 4+ needed" >&2; exit 2; }
D=${1:?usage: tools/mksite.sh <outdir> [hosts]}; N=${2:-253}
mkdir -p "$D/disc" || exit 2
awk -v D="$D" -v N="$N" 'BEGIN {
    for (i = 1; i <= N; i++) {
        h = sprintf("s%03d", i); r = int((i - 1) / 32); slot = (i - 1) % 32 + 1; s = (i - 1) % 4; o = int((i - 1) / 4) + 1
        a = "198.19." (1 + 2 * s) "." o; b = "198.19." (2 + 2 * s) "." o; m = "198.18.100." i
        down = (i % 15 == 0)
        f = D "/disc/" h
        print "=== hostname ===" > f; print h > f
        print "=== addr ===" > f
        print "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever" > f
        print "2: eno1.100    inet " m "/23 scope global eno1.100\\       valid_lft forever" > f
        print "3: enp5s0np0    inet " a "/31 scope global enp5s0np0\\       valid_lft forever" > f
        print "4: enp196s0np0    inet " b "/31 scope global enp196s0np0\\       valid_lft forever" > f
        print "=== link ===" > f
        print "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT\\    link/loopback 00:00:00:00:00:00" > f
        print "2: eno1.100@eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT\\    link/ether 02:00:00:00:" sprintf("%02x:%02x", int(i / 256), i % 256) > f
        print "3: enp5s0np0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc mq state UP mode DEFAULT\\    link/ether 02:00:00:01:" sprintf("%02x:%02x", int(i / 256), i % 256) > f
        if (down) print "4: enp196s0np0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 9000 qdisc mq state DOWN mode DEFAULT\\    link/ether 02:00:00:02:" sprintf("%02x:%02x", int(i / 256), i % 256) > f
        else print "4: enp196s0np0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc mq state UP mode DEFAULT\\    link/ether 02:00:00:02:" sprintf("%02x:%02x", int(i / 256), i % 256) > f
        close(f)
        print h, m, a, b > (D "/host_list.txt")
        if (down || i <= 8) print h > (D "/subset.txt")
        la = sprintf("leaf-r%02d-a", r + 1); lb = sprintf("leaf-r%02d-b", r + 1); port = "swp" slot "s1"
        if (i == 1) { xa = lb; xb = la } else { xa = la; xb = lb }
        print h, "enp5s0np0", a, la, "ifname", port, la ".example", "-", "FE2/1", "unknown" > (D "/lldp_neighbors.txt")
        print h, "enp196s0np0", b, lb, "ifname", port, lb ".example", "-", "FE2/1", "unknown" > (D "/lldp_neighbors.txt")
        print h, "enp5s0np0", a, xa, "ifname", port, xa ".example", "-", "FE2/1", "unknown" > (D "/lldp_swapped.txt")
        print h, "enp196s0np0", b, xb, "ifname", port, xb ".example", "-", "FE2/1", "unknown" > (D "/lldp_swapped.txt")
    }
}' || exit 2
echo "mksite: $N hosts in $D ($(ls "$D/disc" | wc -l | tr -d ' ') discovery files, $(grep -c '' "$D/subset.txt") in the subset)"
