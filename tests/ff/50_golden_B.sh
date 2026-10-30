#!/opt/homebrew/bin/bash
# golden-B: one backend run with every backend fault that does not change another's numbers (10-26 item 7):
# hosts 198.18.0.1-8 (h4 rail B down, h5 rail A MTU 1500, 198.18.0.6 unreachable, .7 = h1, .8 a BMC), UDP on, 2 iterations,
# FAKE_FLAP=h2, FAKE_MESHFAIL=198.19.2.3 and 27's host-side set. Every check that only reads a backend run reads this
# one. Its bundle members are also the stored fixtures the unit groups read (fixtures/golden-B/): each is compared
# with the fresh one here (FIXTURE_UPDATE=1 rewrites them instead; review the diff before committing to them).
# checks: 104
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
FX=$S/fixtures/golden-B
out=$(xrun gb FF_HOSTS=198.18.0.1-8 FF_UDP=1 FF_UDP_DURATION=1 FF_TOS=106 FF_ITER=2 FAKE_FLAP=h2 FAKE_MESHFAIL=198.19.2.3 \
      FAKE_RING=h2 FAKE_PCIE=h3 FAKE_GOV=h1:powersave FAKE_SOFTNET_DROP=h3 FAKE_KLOG=h1 FAKE_RCVCPU=95.0 FAKE_NOTOOLS=h5 \
      FAKE_BUF_DISCARD=h4 FAKE_IPERF_OLD=h2 FF_SPINES=1 FF_SPINE_LINKS=1 FF_SPINE_GBPS=300 timeout 300 $B $C 1); rc=$?
echo "$out" > $W/gb.out
t=$(bundle gb)
# FF -> uplink wiring (was 14's runs; the uplink rules are units in 60, the dashboard card parses stored archives in 14)
chk "uplinks declared: FF calls the uplink check (an 'Uplinks leaf' line per leaf)" "[ \$(grep -c '^  Uplinks leaf' <<<\"\$out\") -ge 2 ]" "$(grep -i uplink <<<"$out")"
chk "uplinks recorded in metadata" "[ \"\$(tar xzf $t -O --include='*/metadata.txt' | grep '^spine')\" = \"\$(printf 'spines=1\nspine_links=1\nspine_gbps=300')\" ]" "$(tar xzf $t -O --include='*/metadata.txt' | grep '^spine')"
# (was 17's w0 run) FF_CROSS_MAX unset; the positive control is 17's FF_CROSS_MAX=8 run
chk "FF_CROSS_MAX unset: no waves, one phase 2 marker" "! grep -q 'waves of at most' <<<\"\$out\" && [ \"\$(bfile gb iperf3_results.txt | grep -c '^### iteration:1 phase:2\$')\" = 1 ]" "$(bfile gb iperf3_results.txt | grep -c '^### iteration:1 phase:2$') markers"
# positive control for 07's "FF_CROSS_RAIL=0: no cross-rail total": a cross-on run prints the line that check greps for
chk "cross-rail on: 'Cross-rail total' printed (control for 07's zero)" "grep -q 'Cross-rail total' <<<\"\$out\"" "$(grep -c 'Cross-rail' <<<"$out") Cross-rail lines"

# --- fixture freshness: the stored members the unit groups read, sorted, timestamps out ---
MEMBERS="iperf3_results.txt iperf3_udp_results.txt host_counters.txt prio_counters.txt packet_drops.txt udp_host_counters.txt
 udp_nic_drops.txt udp_expected.txt udp_tx.txt fec_rates.txt temps.txt temps_summary.txt host_rx.txt nic_diagnostics.txt
 lldp_neighbors.txt mesh_failures.txt link_flaps.txt rails.txt host_list.txt paths_excluded.txt rail_anomalies.txt metadata.txt"
norm() { case $1 in
    metadata.txt) grep -vE '^(timestamp|end_timestamp)=' ;;
    fec_rates.txt) awk '{$3 = "-"; if ($4 ~ /^[0-9]+$/) $4 = "-"; if ($6 ~ /^[0-9]+$/) $6 = "-"; print}' ;;   # seconds, blocks and bits scale with the wall clock
    *) cat ;; esac | sort; }
# a regeneration run says WRITTEN, never PASS, and run_all's total then says fixtures were written (exit 3): only a
# normal run against the stored fixtures counts (10-26)
if [[ -n $FIXTURE_UPDATE ]]; then
    fxupdate gb "$FX" golden-B $MEMBERS
else
    for m in $MEMBERS; do
        chk "golden-B fixture fresh: $m" "[ -e $FX/$m ] && [ \"\$(bfile gb $m | norm $m)\" = \"\$(norm $m < $FX/$m)\" ]" "$(diff <(norm $m < $FX/$m) <(bfile gb $m | norm $m) 2>&1 | head -n 4)"
    done
fi

# --- stored-archive drift (10-26 21:02): the archives 11-14 parse (fixtures/bundles) must have this FF's bundle
# format: member names (host paths folded), each member's header line (column header or '###' marker, digits folded)
# and metadata.txt's key set, compared with this fresh bundle. The loop takes *.tgz: an archive kept in an old format on
# purpose is named .tar.gz and stays out (12_old_v2_allAtoB, 14_ub_oldtypes; fixtures/bundles/README)
amembers() { tar tzf "$1" | sed -E 's#^[^/]*/##; /\/$/d; /^$/d; s#^raw_per_host/.*#raw_per_host/*#; s#^sysinfo/[^/]*/#sysinfo/*/#' | sort -u; }
aheader() { tar xzOf "$1" --include="*/$2" | awk 'NF {$1 = $1; print; exit}' | awk '/^### / || /^[A-Z][A-Za-z_]*( |$)/' | sed -E 's/[0-9]+/N/g'; }
# members FF writes only when the run has that case: an unreachable and an excluded host (golden-B has both, the archives
# don't), UDP (udp_*, iperf3_udp_results), the mesh (mesh_failures), clients (clients, client_*, their sysinfo NICs):
# 14_where and 14_clean (10-29) run with UDP and the mesh off, 14_where with clients. Headers are still compared where
# a member is in both; metadata's client_* keys are the clients' own
COND_RX='^[<>] (excluded|unreachable|udp_[a-z_]+|iperf3_udp_results|mesh_failures|clients|client_[a-z_]+)\.txt$|^> sysinfo/\*/nic-'
akeys() { tar xzOf "$1" --include='*/metadata.txt' | sed -n 's/=.*//p' | grep -v '^clients\?_' | sort -u; }   # client keys: a run with clients only
gm=$(amembers "$t"); gk=$(akeys "$t")
for a in $S/fixtures/bundles/*.tgz; do
    n=$(basename $a); am=$(amembers "$a"); hd=
    for m in $(comm -12 <(echo "$gm") <(echo "$am") | grep -v '\*'); do
        [ "$(aheader "$t" $m)" = "$(aheader "$a" $m)" ] || hd+="$m: '$(aheader "$a" $m)' vs fresh '$(aheader "$t" $m)'; "
    done
    md=$(diff <(echo "$gm") <(echo "$am") | grep '^[<>]' | grep -v -E "$COND_RX" | tr '\n' ' ')
    chk "stored archive $n: member names as this FF's bundle (bar the members a run's features decide)" "[ -z \"\$md\" ]" "$n: bundle format changed: regenerate with tools/mkbundles.sh; $md"
    chk "stored archive $n: member header lines as this FF's bundle" "[ -z \"\$hd\" ]" "$n: bundle format changed: regenerate with tools/mkbundles.sh; $hd"
    chk "stored archive $n: metadata.txt keys as this FF's bundle" "[ \"\$(akeys $a)\" = \"\$gk\" ]" "$n: bundle format changed: regenerate with tools/mkbundles.sh; $(diff <(echo "$gk") <(akeys $a) | grep '^[<>]' | tr '\n' ' ')"
done

# --- the run (was 04, 20) ---
chk "golden-B: rc 3, RESULT PARTIAL hosts=5/5 paths=10/16 skipped=6 (h4's dead B no longer blocks the cross run on its A)" \
    "[ $rc = 3 ] && grep -q '^RESULT coverage=PARTIAL hosts=5/5 paths=10/16 skipped=6 no_result=0 cross_rail=on' $W/gb.out" "rc=$rc $(grep '^RESULT' $W/gb.out)"
chk "golden-B: run.log in the bundle" "tar xzf \"$t\" -O --include='*/run.log' | grep -q '# Begin'"
# 232 (was 189): a phase 2 pair uses one NIC per host, so h4 (B down) and h5 (A MTU 1500) still run cross on the other NIC
chk "golden-B: UDP unaccounted 232" "grep -q 'unaccounted 232' $W/gb.out && grep -q 'unaccounted beyond it (likely fabric): 232' $W/gb.out" "$(grep 'Lost datagrams' $W/gb.out)"
chk "golden-B: pause counter seen" "grep -q 'rx_prio3_pause' $W/gb.out"
chk "golden-B: traffic by priority per rail" "grep -q 'Traffic by priority in iteration 1 (rx+tx bytes): rail A: prio3 42.0GB' $W/gb.out" "$(grep 'Traffic by priority' $W/gb.out | head -n 1)"
chk "golden-B: RDMA counter rose (packets name kept)" "grep -q -E 'h1_enp5s0np0 +rdma:np_ecn_marked_roce_packets +42' $W/gb.out"
# (was 13) the bundle is a .tgz, named in the log with its render line
# the run renders its own page beside the bundle (10-29 16:43): the same base name, 'Bundle:' and 'Dashboard:' log lines
chk "golden-B: a .tgz bundle, no .tar.gz, and the .html beside it with the same base name; the log's 'Bundle: ' line names the tgz and its 'Dashboard: ' line the html (data incomplete: PARTIAL); 0 'Render:' lines (control: a planted one counts 1)" "[ -s \"$t\" ] && ! ls $W/gb | grep -q 'tar\.gz' && [ -s \"\${t%.tgz}.html\" ] && [ \$(ls $W/gb | grep -c '\.html$') = 1 ] && grep -q -E '^# Bundle: .*/fabric_ferret_h1_[0-9TZ]+\.tgz \(' $W/gb.out && grep -q -E '^# Dashboard: .*/fabric_ferret_h1_[0-9TZ]+\.html \(data incomplete' $W/gb.out && [ \$(grep -c '^# Render: ' $W/gb.out) = 0 ] && [ \$({ cat $W/gb.out; echo '# Render: planted'; } | grep -c '^# Render: ') = 1 ]" "$(ls $W/gb | tr '\n' ' ') | $(grep -E '^# (Bundle|Dashboard|Render)' $W/gb.out | cut -c1-120 | tr '\n' '|')"
# (was 22's second run) the control for 22's preflight findings: a layout with none of them
chk "golden-B: clean layout: no swap/LLDP/gateway warnings" "! grep -q -E 'swapped_nics|lldp_wrong_rail|gateways that failed' $W/gb.out"
# (was 25) a run that finishes leaves no lock
chk "golden-B: a finished run leaves no lock" "[ \$(ls $FAKE_STATE/lock.* 2>&1 | grep -c -v 'No such') = 0 ]" "$(ls $FAKE_STATE/lock.* 2>&1)"

# --- flap (was 05) ---
chk "golden-B: link flap named per iteration" "[ \$(grep -c 'WARNING: rail links went down during iteration' $W/gb.out) = 2 ] && grep -q -E 'h2_enp196s0np0 +198.19.2.2 +[0-9]+\$' $W/gb.out"
chk "golden-B: drops log: label once" "! grep -q -E 'iter[0-9]+ +rx_drop.*iter[0-9]+\$' $W/gb.out"

# --- FEC (was 23) ---
chk "golden-B: FEC off counted" "grep -q 'rail NICs; FEC off on 1' $W/gb.out"
chk "golden-B: FEC uncorrectable warned" "grep -q 'uncorrectable FEC blocks .*h3_enp196s0np0(5)' $W/gb.out"

# --- mesh (was 24): on by default, one dead IP ---
chk "golden-B: mesh on by default; dead IP 198.19.2.3: 64 pings, 7 failed" "grep -q 'Mesh: 64 pings, 7 failed' $W/gb.out"

# --- host side (was 27's "bad" run) ---
rx() { bfile gb host_rx.txt | awk -v h=$1 -v c="$2" 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == c) k = i} $1 == h {print $k}'; }
items=$(tar -tzf "$t" | awk -F/ '$(NF-2) == "sysinfo" && $(NF-1) == "h1" && $NF != "" {print $NF}' | sort | tr '\n' ' ')
want="chrony cmdline cpu-governor df dmidecode epoch free ip ip-route-all ip-rule iperf3 irqbalance isolated kernel-log lscpu lspci meminfo mounts nic-enp196s0np0 nic-enp5s0np0 numactl ofed os-release softirqs sysctl uname uptime weka "
chk "golden-B: sysinfo: h1 has every item (wekatester set + receive path)" "[ \"$items\" = \"$want\" ]" "got: $items"
chk "golden-B: sysinfo: one dir per tested host (metadata sysinfo_hosts=5)" "bfile gb metadata.txt | grep -q -x 'sysinfo_hosts=5'"
chk "golden-B: host_counters labels are one token (4 columns)" "[ -n \"\$(bfile gb host_counters.txt)\" ] && bfile gb host_counters.txt | awk 'NF != 4 {b++} END {exit b > 0}'"
chk "golden-B: every TCP result carries cpu:S/R" "[ \$(bfile gb iperf3_results.txt | grep 'Gbits/sec' | grep -c -v -E ' cpu:[0-9.]+/[0-9.]+\$') = 0 ]"
chk "golden-B: 4 of 5 hosts flagged (h5 only lacks tools)" "grep -q 'Host-side receive: 4 of 5 hosts flagged' $W/gb.out" "$(grep 'Host-side receive' $W/gb.out)"
chk "golden-B: config line counts ring and PCIe" "grep -q 'Rail NIC receive config: 10 NICs read; rx ring below its maximum on 2, PCIe link below its maximum on 1' $W/gb.out"
chk "golden-B: h2 ring flags per rail" "rx h2 Flags | grep -q 'ringA<max,ringB<max'" "$(rx h2 Flags)"
chk "golden-B: h3 PCIe downtrained, softnet and TCP drops" "rx h3 Flags | grep -q 'pcieA<max,softnet_drop,tcp_rcv_drop'" "$(rx h3 Flags)"
chk "golden-B: h3 drop counts summed over phases (4 x 7)" "[ \"\$(rx h3 Softnet_drop) \$(rx h3 TCP_rcv_drop)\" = '28 28' ]" "$(rx h3 Softnet_drop) $(rx h3 TCP_rcv_drop)"
chk "golden-B: h1 governor and kernel log lead" "rx h1 Flags | grep -q 'gov:powersave,klog' && [ \"\$(rx h1 Klog)\" = 1 ]" "$(rx h1 Flags) klog=$(rx h1 Klog)"
chk "golden-B: h4 NIC buffer discards (rx_prio0_buf_discard)" "rx h4 Flags | grep -q nic_discard && [ \"\$(rx h4 NIC_discard)\" -gt 0 ]" "$(rx h4 Flags) $(rx h4 NIC_discard)"
chk "golden-B: old single-threaded iperf3 at 95% flagged" "rx h2 Flags | grep -q 'rcv_cpu>=90/thread' && [ \"\$(rx h2 RcvThr%)\" = 95.0 ]" "$(rx h2 RcvThr%) $(rx h2 Flags)"
chk "golden-B: iperf3 3.16 at 95% summed over 16 threads is not flagged" "! rx h4 Flags | grep -q rcv_cpu && [ \"\$(rx h4 RcvThr%)\" = 5.9 ]" "$(rx h4 RcvThr%) $(rx h4 Flags)"
chk "golden-B: h5 without tools shows '-', no ring flag" "[ \"\$(rx h5 Ring_A) \$(rx h5 Governor)\" = '- -' ] && ! rx h5 Flags | grep -q ring" "$(rx h5 Ring_A) $(rx h5 Governor) $(rx h5 Flags)"
chk "golden-B: h5 cpu-governor says n/a, not blank" "bfile gb sysinfo/h5/cpu-governor | grep -q '^n/a: '"
chk "golden-B: per-phase log names h3's drops" "grep -q 'Host receive drops in phase 1 .*h3 TCPRcvQDrop +7' $W/gb.out" "$(grep -m1 'receive drops' $W/gb.out)"
chk "golden-B: h1 kernel-log captured" "bfile gb sysinfo/h1/kernel-log | grep -q 'AER: Corrected error'"

# (was 11) the per data NIC table's header with no clients; RESULT says cross_rail=on when routed (checked above)
chk "golden-B: per data NIC table header: Role Host NIC IP Same Cross Retr Retr_% Expect Status" "grep -q -E '^ +Role +Host +NIC +IP +Same +Cross +Retr +Retr_% +Expect +Status\$' $W/gb.out" "$(grep -E '^ +Role ' $W/gb.out)"

# --- no clients (was 35's nc run): no client_rx.txt, no Client-side section, drop reads = backend NICs only ---
chk "golden-B: no clients: no client_rx.txt, no Client-side section, drop_nics_expected=10" "! tar -tzf \"$t\" | grep -q client_rx.txt && ! grep -q 'Client-side receive' $W/gb.out && bfile gb metadata.txt | grep -qx 'drop_nics_expected=10'" "$(bfile gb metadata.txt | grep drop_nics)"

# --- rows (was 41): h4 rail B link down keeps its row ---
chk "golden-B: h4 rail B link down: row with Status link_DOWN_on_enp196s0np0" "grep -qE '^ +backend +h4 +enp196s0np0 .* link_DOWN_on_enp196s0np0\$' $W/gb.out" "$(grep -E '^ +backend +h4 ' $W/gb.out)"

# --- the dashboard on it (was 04, 05, 20, 23, 24, 27) ---
render gb; prc=$?
chk "golden-B: parser rc 3 (PARTIAL) with the INCOMPLETE banner" "[ $prc = 3 ] && grep -q 'INCOMPLETE RESULT' $W/gb.html" "rc=$prc $(tail -n 3 $W/gb.pout)"
# (from 14, on a fresh render now that golden-B declares its uplinks) the card says the run declared them
chk "golden-B: dashboard uplink card: declared by the run, 1 x 1 x 300G" "grep -q 'Leaf uplinks, declared by the run: 1 spines x 1 links x 300G = 300.0 G per leaf' $W/gb.html" "$(grep -oE 'Leaf uplink[^<]*' $W/gb.html | head -n 2)"
chk "golden-B: dashboard: unaccounted beyond expected 232; uniform rails, no per-rail note" "grep -q 'unaccounted beyond expected (likely fabric) 232' $W/gb.html && ! grep -q 'rails differ' $W/gb.html"
chk "golden-B: dashboard: flap is a problem" "grep -q 'Rail links went down during the run' $W/gb.html"
chk "golden-B: dashboard: FEC card: 1 uncorrectable, 1 watch" "python3 -c \"import re;h=open('$W/gb.html').read();m=re.search(r'FEC during this run.*?</div>',h,re.S);t=re.sub(r'<[^>]+>','',m.group(0));exit(0 if re.search(r'1\s*uncorrectable.*0\s*over the FEC limit.*1\s*watch',t,re.S) else 1)\""
chk "golden-B: dashboard: FEC card: FEC off shown, not ok" "grep -q '(1 with FEC off)' $W/gb.html && grep -q 'h4_enp5s0np0</td><td><span class=.badge .>FEC off' $W/gb.html"
chk "golden-B: dashboard: slow link diagnosis from FEC rate" "grep -q 'Uncorrectable FEC blocks during the run' $W/gb.html && ! grep -q 'marginal fiber or dirty connector' $W/gb.html"
chk "golden-B: dashboard: IP with only cross-rail runs judged on them, marked" "grep -q '\"ip\": \"198.19.2.3\", \"avg\": 150.0, \"samples\": [0-9]*, \"cross_only\": true' $W/gb.html"
chk "golden-B: dashboard: mesh in card" "grep -q 'did not answer 7 of 7' $W/gb.html && grep -q 'mesh: 7 of 64 pings failed' $W/gb.html"
chk "golden-B: no clients: dashboard card has no client count (control)" "grep -qE 'Host-side receive: [0-9]+ of 5 hosts flagged<' $W/gb.html" "$(grep -oE 'Host-side receive: [^<]*' $W/gb.html)"
chk "golden-B: dashboard: card counts flagged hosts, flags shown" "grep -q 'Host-side receive: 4 of 5 hosts flagged' $W/gb.html && grep -q 'pcieA&lt;max, softnet_drop, tcp_rcv_drop' $W/gb.html"
finish
