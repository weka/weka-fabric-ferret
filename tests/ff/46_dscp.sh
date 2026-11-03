#!/opt/homebrew/bin/bash
# the DSCP path check (FF_RDMA=1, or FF_TOS set; 11-03): per planned path one iperf3 UDP probe (ping when iperf3 is
# missing or sees nothing) read by tcpdump -p on the receiver; dscp_check.txt, the log lines, the Run checks card and
# the Where entries. h21 -> h22 on 2 rails (4 paths), one client; the fake's DSCP knobs are in tests/fake/ssh
# checks: 13
# secs: 40
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
G="FF_HOSTS=198.18.0.21-22 FF_ITER=1"
# drun <name> VAR=value ...: one run, its DSCP calls and scripts kept in $W/<name>.d (rx.log tx.log rx.script tx.<probe>.script)
drun() { local n=$1 f; shift; xrun $n "$@" > $W/$n.out; mkdir -p $W/$n.d; for f in $FAKE_STATE/dscp_*; do [[ -e $f ]] && cp "$f" $W/$n.d/${f##*/dscp_}; done; }
dr() { bfile $1 dscp_check.txt | grep '^[0-9]'; }   # its rows (a missing member prints tar's error, no row)
rows() { dr $1 | awk -v d=$2 '$2 == d'; }   # rows <run> <dst ip>
nr() { dr $1 | grep -c .; }
np() { grep -o '^# Directed NIC paths: [0-9]*' $W/$1.log | grep -o '[0-9]*$'; }
cnt() { if [[ -f $W/$1.d/$2 ]]; then grep -c -E "$3" $W/$1.d/$2; else echo 0; fi; }   # cnt <run> <file> <ERE>
has() { [[ -f $W/$1.d/$2 ]] && grep -qF -- "$3" $W/$1.d/$2; }
sumline() { grep '^# DSCP check: [0-9]* of ' $W/$1.log; }
wlines() { grep -o '<ul class="where-list mb-0">.*' "$1" | head -n 1 | sed 's#</ul>.*##; s#</li>#\n#g' | grep 'where-sev' | sed 's/<[^>]*>//g'; }

drun z $G FF_SKIP_IPERF=1 timeout 60 $B $C 1
drun k $G FF_RDMA=1 FF_SKIP_IPERF=1 FF_CLIENTS=198.18.1.1 FF_CLIENT_NETS=198.19.10.0/24 timeout 60 $B $C 1
drun m $G FF_TOS=104 FF_SKIP_IPERF=1 FAKE_DSCP_REWRITE=198.19.1.22:96,198.19.2.22:0 FAKE_DSCP_IPERF_FAIL=h21 timeout 60 $B $C 1
drun a $G FF_RDMA=1 FF_SKIP_IPERF=1 FAKE_NO_IPERF=h22 timeout 60 $B $C 1
drun u $G FF_RDMA=1 FF_SKIP_IPERF=1 FAKE_NOXROUTE=1 FAKE_DSCP_DEAD=198.19.1.22 timeout 60 $B $C 1
drun t $G FF_RDMA=1 FF_SKIP_IPERF=1 FAKE_NO_TCPDUMP=h22 timeout 60 $B $C 1
drun f $G FF_RDMA=1 timeout 90 $B $C 1
render k; krc=$?; render m; mrc=$?; render u; urc=$?

# --- the gate, the probes, the rows ---
chk "gate: no FF_RDMA and no FF_TOS: 0 receiver and 0 sender probe calls, no dscp_check.txt in the bundle, no 'DSCP check' log line (control: the FF_RDMA=1 run has each)" \
    "[ \$(cnt z rx.log .) = 0 ] && [ \$(cnt z tx.log .) = 0 ] && ! tar -tzf \$(bundle z) | grep -q '/dscp_check.txt\$' && [ \$(grep -c '^# DSCP check' $W/z.log) = 0 ] && [ \$(cnt k rx.log .) -ge 1 ] && tar -tzf \$(bundle k) | grep -q '/dscp_check.txt\$' && [ \$(grep -c '^# DSCP check' $W/k.log) -ge 1 ]" \
    "z: rx $(cnt z rx.log .) tx $(cnt z tx.log .) lines $(grep -c '^# DSCP check' $W/z.log); k: rx $(cnt k rx.log .) lines $(grep -c '^# DSCP check' $W/k.log)"
n=$(nr k)
chk "FF_RDMA=1, every path keeps DSCP 24: one row per planned path ($(np k) backend + the client's), each 'iperf3 96 96 kept -' (control: at least one client row, src 198.19.10.1)" \
    "[ $n -ge 2 ] && [ \$(dr k | awk '\$1 != \"198.19.10.1\"' | grep -c .) = '$(np k)' ] && [ \$(dr k | awk '\$1 == \"198.19.10.1\"' | grep -c .) -ge 1 ] && [ \$(dr k | awk '!(\$4 == \"iperf3\" && \$5 == 96 && \$6 == 96 && \$7 == \"kept\" && \$8 == \"-\")' | grep -c .) = 0 ]" "$(dr k | tr '\n' '|')"
chk "FF_RDMA=1 log: '# DSCP check: $n planned paths, DSCP 24 (default) as TOS 96, iperf3 UDP probe (1 Mbit/s, 2 s), ping fallback' and '# DSCP check: $n of $n paths kept DSCP 24 (default); 0 rewritten; 0 stripped; 0 unknown (dscp_check.txt)'; iperf3 got through everywhere, so 0 ping probes and no 'ping probe used' line" \
    "grep -qx '# DSCP check: $n planned paths, DSCP 24 (default) as TOS 96, iperf3 UDP probe (1 Mbit/s, 2 s), ping fallback' $W/k.log && [ \"\$(sumline k)\" = '# DSCP check: $n of $n paths kept DSCP 24 (default); 0 rewritten; 0 stripped; 0 unknown (dscp_check.txt)' ] && [ \$(cnt k tx.log ' ping\$') = 0 ] && [ \$(grep -c 'ping probe used' $W/k.log) = 0 ]" "$(grep '^# DSCP' $W/k.log | tr '\n' '|') ping calls $(cnt k tx.log ' ping$')"
chk "probe commands (FF_SKIP_IPERF=1): the receiver runs 'tcpdump -p -nn -v -l -i' (never promiscuous) and its own 'iperf3 -s -1'; the sender 'iperf3 -u -b 1M -t 2 -S'; every sender call carries TOS 96 and probe iperf3 ($(cnt k tx.log .) calls)" \
    "has k rx.script 'tcpdump -p -nn -v -l -i' && ! grep -qE 'tcpdump +-i' $W/k.d/rx.script && has k rx.script 'iperf3 -s -1' && has k tx.iperf3.script 'iperf3 -u -b 1M -t 2 -S' && [ \$(cnt k tx.log .) -ge 2 ] && [ \$(cnt k tx.log ' 96 iperf3\$') = \$(cnt k tx.log .) ]" "$(sort $W/k.d/tx.log 2>&1 | uniq -c | tr '\n' '|')"
r=$(rows m 198.19.1.22 | grep -c .); s=$(rows m 198.19.2.22 | grep -c .)
chk "FF_TOS=104 alone: '# FF_TOS=104 set: FF_RDMA=1 (DSCP check on)'; h21's iperf3 probes see nothing, so ping: the $r rows into 198.19.1.22 'ping 104 96 rewritten iperf3_failed', the $s into 198.19.2.22 'ping 104 0 stripped iperf3_failed'; '# DSCP check: 0 of $((r + s)) paths kept DSCP 26 (FF_TOS=104); $r rewritten; $s stripped; 0 unknown (dscp_check.txt)'" \
    "grep -qx '# FF_TOS=104 set: FF_RDMA=1 (DSCP check on)' $W/m.log && [ $r -ge 1 ] && [ $s -ge 1 ] && [ \$(nr m) = $((r + s)) ] && [ \$(rows m 198.19.1.22 | awk '!(\$4 == \"ping\" && \$5 == 104 && \$6 == 96 && \$7 == \"rewritten\" && \$8 == \"iperf3_failed\")' | grep -c .) = 0 ] && [ \$(rows m 198.19.2.22 | awk '!(\$4 == \"ping\" && \$5 == 104 && \$6 == 0 && \$7 == \"stripped\" && \$8 == \"iperf3_failed\")' | grep -c .) = 0 ] && [ \"\$(sumline m)\" = '# DSCP check: 0 of $((r + s)) paths kept DSCP 26 (FF_TOS=104); $r rewritten; $s stripped; 0 unknown (dscp_check.txt)' ]" "$(dr m | tr '\n' '|') $(sumline m)"
chk "iperf3 failed, ping got through: '# iperf3 DSCP probe failed on 1 hosts, ping probe used (dscp_check.txt)' once (control: the kept run has none); each path tried iperf3 then 'ping -c 5 -i 0.2 -W 1 -Q' with TOS 104" \
    "[ \$(grep -cx '# iperf3 DSCP probe failed on 1 hosts, ping probe used (dscp_check.txt)' $W/m.log) = 1 ] && [ \$(cnt m tx.log ' 104 iperf3\$') = $((r + s)) ] && [ \$(cnt m tx.log ' 104 ping\$') = $((r + s)) ] && has m tx.ping.script 'ping -c 5 -i 0.2 -W 1 -Q'" "$(grep 'ping probe used' $W/m.log) | $(sort $W/m.d/tx.log 2>&1 | uniq -c | tr '\n' '|')"
chk "no iperf3 on h22: every row 'ping 96 96 kept iperf3_absent', 0 iperf3 probes sent or listened for, and no 'ping probe used' line (iperf3 never ran)" \
    "[ \$(nr a) -ge 1 ] && [ \$(dr a | awk '!(\$4 == \"ping\" && \$5 == 96 && \$6 == 96 && \$7 == \"kept\" && \$8 == \"iperf3_absent\")' | grep -c .) = 0 ] && [ \$(cnt a tx.log ' iperf3\$') = 0 ] && [ \$(cnt a rx.log ' iperf3\$') = 0 ] && [ \$(grep -c 'ping probe used' $W/a.log) = 0 ]" "$(dr a | tr '\n' '|') tx $(cnt a tx.log ' iperf3$') rx $(cnt a rx.log ' iperf3$')"
pf=$(dr u | awk '$8 == "path_check_failed"' | grep -c .)
chk "unknown: the cross-rail paths fail their path check (FAKE_NOXROUTE) and are never probed ($pf rows 'none - - unknown path_check_failed'); 198.19.1.21 -> 198.19.1.22 sees no packet on either probe ('unknown both_failed'); all count in U: '... 0 rewritten; 0 stripped; $((pf + 1)) unknown'" \
    "[ $pf -ge 1 ] && [ \$(dr u | awk '\$8 == \"path_check_failed\" && !(\$4 == \"none\" && \$6 == \"-\" && \$7 == \"unknown\")' | grep -c .) = 0 ] && [ \$(dr u | awk '\$1 == \"198.19.1.21\" && \$2 == \"198.19.1.22\" && \$7 == \"unknown\" && \$8 == \"both_failed\"' | grep -c .) = 1 ] && [ \$(cat $W/u.d/rx.log $W/u.d/tx.log 2>&1 | awk '(\$1 ~ /^198\.19\.1\./) != (\$2 ~ /^198\.19\.1\./)' | grep -c .) = 0 ] && sumline u | grep -q '; 0 rewritten; 0 stripped; $((pf + 1)) unknown (dscp_check.txt)\$'" "$(dr u | tr '\n' '|') $(sumline u)"
chk "no tcpdump on the receiver h22: every row 'unknown tcpdump_absent' (control: the FF_RDMA=1 run's rows are kept)" \
    "[ \$(nr t) -ge 1 ] && [ \$(dr t | awk '!(\$7 == \"unknown\" && \$8 == \"tcpdump_absent\")' | grep -c .) = 0 ] && [ \$(dr k | awk '\$7 == \"kept\"' | grep -c .) -ge 1 ]" "$(dr t | tr '\n' '|')"
chk "a run with load (iperf3 servers up): the probe runs before 'Iteration 1 of', every row 'iperf3 96 96 kept -'" \
    "[ \$(nr f) -ge 1 ] && [ \$(dr f | awk '!(\$4 == \"iperf3\" && \$6 == 96 && \$7 == \"kept\")' | grep -c .) = 0 ] && [ \$(grep -n -m1 '^# DSCP check: [0-9]* planned' $W/f.log | cut -d: -f1) -lt \$(grep -n -m1 'Iteration 1 of' $W/f.log | cut -d: -f1) ]" "$(dr f | tr '\n' '|') lines: $(grep -n -m1 '^# DSCP check' $W/f.log | cut -c1-40) / $(grep -n -m1 'Iteration 1 of' $W/f.log | cut -c1-40)"

# --- the page ---
chk "dashboard, all kept: the Run checks card 'DSCP check — $n paths, DSCP 24 (default)' with heads Src host, Src IP, Dst host, Dst IP, NIC, Probe, TOS sent, TOS seen, Verdict, Note; 0 Where entries naming DSCP (control: the FF_TOS=104 page has some)" \
    "{ [ $krc = 0 ] || [ $krc = 3 ]; } && grep -qF 'DSCP check — $n paths, DSCP 24 (default)' $W/k.html && grep -qF '<th>Src host</th><th>Src IP</th><th>Dst host</th><th>Dst IP</th><th>NIC</th><th>Probe</th><th>TOS sent</th><th>TOS seen</th><th>Verdict</th><th>Note</th>' $W/k.html && [ \$(wlines $W/k.html | grep -c DSCP) = 0 ] && [ \$(wlines $W/m.html | grep -c DSCP) -ge 1 ]" "rc=$krc where: $(wlines $W/k.html | tr '\n' '|')"
chk "dashboard, rewritten and stripped: the Where entries '$r DSCP paths into leaf1.example: DSCP 26 rewritten to 24', '$s DSCP paths into leaf2.example: DSCP 26 stripped (0)' and 'iperf3 DSCP probe failed on 1 hosts; ping probe used'" \
    "{ [ $mrc = 0 ] || [ $mrc = 3 ]; } && [ \$(wlines $W/m.html | grep -cF '$r DSCP paths into leaf1.example: DSCP 26 rewritten to 24') = 1 ] && [ \$(wlines $W/m.html | grep -cF '$s DSCP paths into leaf2.example: DSCP 26 stripped (0)') = 1 ] && [ \$(wlines $W/m.html | grep -cF 'iperf3 DSCP probe failed on 1 hosts; ping probe used') = 1 ]" "rc=$mrc where: $(wlines $W/m.html | grep DSCP | tr '\n' '|')"
chk "dashboard, unknown: one Where entry '1 DSCP paths unknown: no probe got through (dscp_check.txt)', the probed path whose probes both failed; the $pf path-check failures are not in it" \
    "{ [ $urc = 0 ] || [ $urc = 3 ]; } && [ \$(wlines $W/u.html | grep -cF '1 DSCP paths unknown: no probe got through (dscp_check.txt)') = 1 ] && [ \$(wlines $W/u.html | grep -c 'DSCP paths unknown') = 1 ]" "rc=$urc where: $(wlines $W/u.html | grep DSCP | tr '\n' '|')"
finish
