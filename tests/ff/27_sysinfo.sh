#!/opt/homebrew/bin/bash
# system info capture (sysinfo/<host>/<item>), per-phase receive counters, iperf3 CPU, kernel log, host_rx.txt
# flags and the dashboard card. Faults come from the fake: FAKE_RING FAKE_PCIE FAKE_GOV FAKE_SOFTNET_DROP FAKE_KLOG
# FAKE_RCVCPU FAKE_NOTOOLS FAKE_BUF_DISCARD.
# checks: 12
# secs: 38
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
tgz() { ls $W/$1/fabric_ferret_*.tgz | head -n1; }
member() { tar -xzOf $(tgz $1) --include="*/$2" 2>&1; }
rx() { member $1 host_rx.txt | awk -v h=$2 -v c="$3" 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == c) k = i} $1 == h {print $k}'; }

# the "bad" run's checks moved to 50_golden_B.sh and the clean run's to 52_golden_C.sh (clean backends) and 50 (sysinfo
# items, host_counters labels, cpu:S/R), 10-26
chk "iperf3 runs with -V (CPU line)" "grep -q -e '-f g -Z -V' $C"
# (the stored pre-ferret v2 archive has no sysinfo; step b, 10-29: was a real site's sample under FFT_SITE_DATA)
python3 $P $S/fixtures/bundles/12_old_v2_allAtoB.tar.gz $W/old.html > $W/po.out 2>&1; rc=$?
chk "parser: a bundle without system info says 'Not captured'" "[ -s $W/old.html ] && grep -q 'Not captured: this bundle is from a fabric_ferret without system info capture' $W/old.html" "rc=$rc $(tail -n 2 $W/po.out)"

# bounded capture: a stalled host is cut at FF_SYSINFO_TIMEOUT and kept; a timed-out item is named; a silent counter read is "-", not 0
# (cut-off 2x the run's 24 s under -j 8, 10-29 21:25)
xrun slow FF_HOSTS=198.18.0.1-5 FF_ITER=1 FF_SYSINFO_TIMEOUT=3 FAKE_SYSINFO_SLOW=h2 FAKE_ITEM_TIMEOUT=h3 FAKE_HOSTCTR_EMPTY=h4 FAKE_RCVCPU=1500.0 timeout 50 $B $C 1 > $W/slow.out
chk "slow: run goes on past a stalled host" "grep -q '^RESULT coverage=' $W/slow.out" "$(tail -n 2 $W/slow.out)"
chk "slow: stalled host cut with a WARNING" "grep -q 'WARNING: h2: system info cut off after 3s (FF_SYSINFO_TIMEOUT); the partial capture is kept' $W/slow.out"
chk "slow: partial capture kept" "member slow sysinfo/h2/epoch | grep -q -E '^[0-9]+\$' && ! tar -tzf \$(tgz slow) | grep -q sysinfo/h2/lspci"
chk "slow: cut host flagged sysinfo_partial" "rx slow h2 Flags | grep -q sysinfo_partial" "$(rx slow h2 Flags)"
chk "slow: timed-out item named" "grep -q 'WARNING: h3: system info items timed out: df' $W/slow.out"
chk "slow: unread counters are -, flagged" "[ \"\$(rx slow h4 Softnet_drop) \$(rx slow h4 TCP_rcv_drop) \$(rx slow h4 AER)\" = '- - -' ] && rx slow h4 Flags | grep -q counters_unread" "$(rx slow h4 Softnet_drop) $(rx slow h4 AER) $(rx slow h4 Flags)"
sat=$(member slow host_rx.txt | awk '$1 != "h2" && $10 == "93.8" && $NF ~ /rcv_cpu>=90\/thread/ {print $1}')   # h2: capture cut, version unknown
chk "slow: iperf3 3.16 saturated per thread (1500/16) flagged" "[ -n \"\$sat\" ]" "$(member slow host_rx.txt | awk '{print $1, $9, $10, $NF}' | tr '\n' ';')"
chk "slow: unknown iperf3 version (capture cut) judged single-threaded" "[ \"\$(rx slow h2 RcvThr%)\" = 1500.0 ] && rx slow h2 Flags | grep -q rcv_cpu" "$(rx slow h2 RcvThr%) $(rx slow h2 Flags)"
# (the control "clean: read counters are numbers, not -" is in 52_golden_C.sh, on golden-C's clean backends)
# the remote per-item timeout itself (the fake prints canned text, so run the script's cmd() here)
f=$(sed -n '/^to=""; have timeout/,/^}/p' $C); u=$($B -c "have() { [ -n \"\$(command -v \"\$1\")\" ]; }; $f; T=1 cmd sleep 5; cmd nosuchtool_x" 2>&1)
chk "cmd(): item timeout and missing tool say n/a" "grep -q '^n/a: sleep timed out after 1s' <<<\"\$u\" && grep -q '^n/a: nosuchtool_x not installed' <<<\"\$u\"" "$u"
out=$(cd $W && FF_HOSTS=198.18.0.1 FF_SYSINFO_TIMEOUT=abc $B $C 2>&1); chk "FF_SYSINFO_TIMEOUT must be a positive integer" "grep -q 'FF_SYSINFO_TIMEOUT must be a positive integer' <<<\"\$out\"" "$out"
finish
