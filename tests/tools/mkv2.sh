#!/usr/bin/env bash
# A synthetic old-format (pre-ferret fabric_sleuth) archive of a 253-host site for the parser groups that used to read a
# real one (10, 23, 26; step b, 10-29). One awk writes the members, tar packs them. Deterministic from the host index.
# usage: tools/mkv2.sh <out.tar.gz> v2|v1|zero|new
#   v2    the v2 member set (host_list, iperf3_results, lldp_neighbors, nic_diagnostics, driver_info, down_ips, metadata,
#         raw_per_host/ for two hosts): 253 hosts on rails A/B (tools/mksite.sh's addressing, racks and leaves), one
#         iteration of two phases (phase 1 per rail between neighbours, phase 2 across rails), 380 Gbps runs on 400G
#         except every 5th host at 250 (slow on both rails), 16 hosts with rail B down (its IP in down_ips, speed
#         Unknown!, no runs), lifetime FEC corrected-bits counts on every NIC (never a rate), optics at 47.25 C
#   v1    the v1 member set (adds rails.txt, packet_drops.txt, paths_excluded.txt, run.log, ssh_errors.log and the v1
#         metadata keys; still no coverage counts, so the parser notes "without coverage counts")
#   zero  as v1 with every run at 0.00 Bytes / 0.00 Gbits/sec (the parser must render, not divide by zero)
#   rates as v2 plus fec_rates.txt (the ferret collector's per-run FEC deltas): every NIC a clean rate, s005's two NICs
#         (slow) over the FEC limit, so the parser blames their slowness on the pre-FEC BER (the control for "a lifetime
#         count is never blamed")
#   new   as v2, a later run of the same site for --compare: host s002 sends at half (its two NICs), s004's two NICs on
#         firmware 28.00.1000, s006 enp5s0np0 moved to swp9s1 (port id and description), s008 enp5s0np0's FEC count
#         below the old one (a counter reset), s010 enp5s0np0 with 3 link down events, and s012's rail B newly down;
#         every other value identical, so the compare lists only the plants
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "mkv2.sh: bash 4+ needed" >&2; exit 2; }
OUT=${1:?usage: tools/mkv2.sh <out.tar.gz> v2|v1|zero|new}; M=${2:?usage: tools/mkv2.sh <out.tar.gz> v2|v1|zero|new}
case $M in v2|v1|zero|new|rates) ;; *) echo "mkv2.sh: mode v2, v1, zero, new or rates" >&2; exit 2 ;; esac
T=$(mktemp -d) || exit 2; D=$T/dp_validation_synth; mkdir -p "$D/raw_per_host" || exit 2
awk -v D="$D" -v M="$M" 'function ipa(i) { return "198.19." (1 + 2 * ((i - 1) % 4)) "." (int((i - 1) / 4) + 1) }
    function ipb(i) { return "198.19." (2 + 2 * ((i - 1) % 4)) "." (int((i - 1) / 4) + 1) }
    function down(i) { return ((M == "v2" || M == "new" || M == "rates") && i % 15 == 0) || (M == "new" && i == 12) }   # v1/zero: nothing down (rc 0 on v1)
    function gb(i, j,   g) { g = ((M == "v2" || M == "new" || M == "rates") && (i % 5 == 0 || j % 5 == 0)) ? 250 : 380; if (M == "new" && i == 2) g = int(g / 2); if (M == "zero") g = 0; return g }   # v1: nothing slow (rc 0)
    function row(s, d, g,   r) { if (M == "zero") r = sprintf("%s,%s,[SUM]   0.00-2.00  sec  0.00  Bytes  0.00  Gbits/sec  receiver  retransmits:%d", s, d, 51)
                                 else r = sprintf("%s,%s,[SUM]    0.00-120.00  sec  %.2f  TBytes  %d  Gbits/sec  receiver  retransmits:%d", s, d, g * 120 / 8 / 1024, g, (g < 300 ? 2000000 : 1000) + 17)
                                 print r > (D "/iperf3_results.txt") }
    BEGIN {
        N = 253
        ts = (M == "new") ? "20261029T120000Z" : "20261029T000000Z"
        f = D "/metadata.txt"
        if (M == "v1" || M == "zero") print "label=synth-v1\ntimestamp=" ts "\nend_timestamp=" ts "\nduration=600\niterations=1\nparallel_streams=8\ntotal_hosts=" N "\ntargets_input=" N "\ntargets_reachable=" N "\nrail_mode=cidr\nrail_a=198.19.1.0/24,198.19.3.0/24,198.19.5.0/24,198.19.7.0/24\nrail_b=198.19.2.0/24,198.19.4.0/24,198.19.6.0/24,198.19.8.0/24\nline_rate_gbps=400\nok_pct=75\nslow_pct=50\nbusy_hosts=0\nport=5201" > f
        else print "timestamp=" ts "\nduration=600\ntotal_hosts=" N "\niterations=1\nparallel_streams=8" > f
        if (M == "v1" || M == "zero") { print "Host  Target     Rail_A_NIC  Rail_A_IP    MTU_A  State_A  Rail_B_NIC   Rail_B_IP    MTU_B  State_B" > (D "/rails.txt"); print "" > (D "/paths_excluded.txt"); print "# Begin synth-v1 " ts > (D "/run.log"); printf "" > (D "/ssh_errors.log") }
        for (i = 1; i <= N; i++) {
            h = sprintf("s%03d", i); a = ipa(i); b = ipb(i); m = "198.18.100." i; r = int((i - 1) / 32); slot = (i - 1) % 32 + 1
            la = sprintf("leaf-r%02d-a", r + 1); lb = sprintf("leaf-r%02d-b", r + 1); port = "swp" slot "s1"
            pa = (M == "new" && i == 6) ? "swp9s1" : port
            print h, m, a, b > (D "/host_list.txt")
            if (M == "v1" || M == "zero") print h, m, "enp5s0np0", a, 9000, "ok", "enp196s0np0", b, 9000, (down(i) ? "link_DOWN" : "ok") > (D "/rails.txt")
            fec = 100000000 + i * 1000003; if (M == "new" && i == 8) fec = 50000
            ld = (M == "new" && i == 10) ? 3 : 0
            fw = (M == "new" && i == 4) ? "28.00.1000" : "28.00.0000"
            print h, "enp5s0np0", a, "400000Mb/s", fec, 0, 0, 0, 0, ld, 0, "-0.91 -0.92 -0.93 -0.94", "47.25" > (D "/nic_diagnostics.txt")
            print h, "enp196s0np0", b, (down(i) ? "Unknown!" : "400000Mb/s"), fec + 7, 0, 0, 0, 0, 0, 0, "n/a n/a n/a n/a", "n/a" > (D "/nic_diagnostics.txt")
            print h, "enp5s0np0", a, "mlx5_core", "24.10-0.0.0", fw, "(EXA0000000001)", "0000:05:00.0" > (D "/driver_info.txt")
            print h, "enp196s0np0", b, "mlx5_core", "24.10-0.0.0", fw, "(EXA0000000001)", "0000:c3:00.0" > (D "/driver_info.txt")
            print h, "enp5s0np0", a, la, "ifname", pa, la ".example", "-", (pa == port ? "FE2/1" : pa), "unknown" > (D "/lldp_neighbors.txt")
            print h, "enp196s0np0", b, lb, "ifname", port, lb ".example", "-", "FE2/1", "unknown" > (D "/lldp_neighbors.txt")
            if (down(i)) print b > (D "/down_ips.txt")
            if (M == "v1" || M == "zero") { print h, "enp5s0np0", a, "rx_drop:0", "tx_drop:0", "rx_oob:0" > (D "/packet_drops.txt"); print h, "enp196s0np0", b, "rx_drop:0", "tx_drop:0", "rx_oob:0" > (D "/packet_drops.txt") }
            # fec_rates.txt: "label host_nic seconds d_corrected_blocks d_uncorrectable_blocks d_corrected_bits d_symbol_errors";
            # 2e10 corrected bits in 120 s at 400G = BER 4.2e-4, over the 2.4e-4 limit; 1e6 = 2e-8, clean
            if (M == "rates") { bits = (i == 5) ? 20000000000 : 1000000
                print "iter1_p1", h "_enp5s0np0", 120, 1000, 0, bits, 0 > (D "/fec_rates.txt"); print "iter1_p1", h "_enp196s0np0", 120, 1000, 0, bits, 0 > (D "/fec_rates.txt") }
        }
        # phase 1: neighbours (1,2), (3,4), ... on each rail, both directions; a down rail B runs nothing
        print "### iteration:1 phase:1" > (D "/iperf3_results.txt")
        for (i = 1; i + 1 <= N; i += 2) { j = i + 1
            row(ipa(i), ipa(j), gb(i, j)); row(ipa(j), ipa(i), gb(j, i))
            if (!down(i) && !down(j)) { row(ipb(i), ipb(j), gb(i, j)); row(ipb(j), ipb(i), gb(j, i)) } }
        # phase 2: across the rails, i A -> j B and j A -> i B
        print "### iteration:1 phase:2" > (D "/iperf3_results.txt")
        for (i = 1; i + 1 <= N; i += 2) { j = i + 1
            if (!down(j)) row(ipa(i), ipb(j), gb(i, j)); if (!down(i)) row(ipa(j), ipb(i), gb(j, i)) }
        close(D "/iperf3_results.txt")
    }' || exit 2
# two hosts'"'"' raw text (the parser lists raw host files; optics come from nic_diagnostics)
S=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"${BASH:-bash}" "$S/mkmlx5.sh" raw "$D/raw_per_host/s001.txt" s001 && "${BASH:-bash}" "$S/mkmlx5.sh" raw "$D/raw_per_host/s002.txt" s002 || exit 2
tar -czf "$OUT" -C "$T" dp_validation_synth || exit 2
rm -rf "${T:?}"
echo "mkv2: $M archive $OUT ($(tar tzf "$OUT" | wc -l | tr -d ' ') members)"
