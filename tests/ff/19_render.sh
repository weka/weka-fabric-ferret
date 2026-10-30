#!/opt/homebrew/bin/bash
# the run renders its own dashboard (10-29 16:43: "At the end of the run there should be a .tgz and a .html file
# created"): beside the bundle, same base name, the log says so; when it cannot (no python3, the generator not beside the
# tool as a bash -s run leaves it) the bundle still lands, the rc is unchanged and one line says how to render by hand.
# Log lines asserted as prefixes up to the first path (10-29 16:49). Three runs, 2 backends, no load extras.
# checks: 7
# secs: 85
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
RUN="FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 FF_MESH=0 FF_TEMPS=0 FF_LABEL=rtest"
# A: plain
out=$(xrun a env $RUN timeout 120 $B $C 1); arc=$?; printf '%s\n' "$out" > $W/a.out
tgz=$(ls $W/a | grep '^fabric_ferret_rtest_.*\.tgz$'); html=$(ls $W/a | grep '^fabric_ferret_rtest_.*\.html$')
chk "plain run: exactly one fabric_ferret_rtest_*.tgz and one .html with the same base name in FF_OUT_DIR; the html's title carries the label; the log has one 'Bundle: ' line and one 'Dashboard: ' line naming them; 0 Traceback lines (control: a planted Traceback counts 1)" \
    "[ \$(wc -l <<<\"\$tgz\") = 1 ] && [ -n \"\$tgz\" ] && [ \"\${tgz%.tgz}\" = \"\${html%.html}\" ] && grep -q '<title>[^<]*rtest' $W/a/\$html && [ \$(grep -c '^# Bundle: .*'\"\$tgz\" <<<\"\$out\") = 1 ] && [ \$(grep -c '^# Dashboard: .*'\"\$html\" <<<\"\$out\") = 1 ] && [ \$(grep -c Traceback <<<\"\$out\") = 0 ] && [ \$({ printf '%s\n' \"\$out\"; echo 'Traceback (planted)'; } | grep -c Traceback) = 1 ]" \
    "rc=$arc files: $(ls $W/a | tr '\n' ' ') | $(grep -E '^# (Bundle|Dashboard)' <<<"$out" | cut -c1-120 | tr '\n' '|')"
chk "plain run: no 'Dashboard not written' line, no 'Render:' line (the old local hint is gone); control: the Bundle line is there" \
    "[ \$(grep -c 'Dashboard not written' <<<\"\$out\") = 0 ] && [ \$(grep -c '^# Render: ' <<<\"\$out\") = 0 ] && grep -q '^# Bundle: ' <<<\"\$out\"" "$(grep -E 'Dashboard|Render' <<<"$out" | tr '\n' '|')"
# B: no python3 on PATH (links to /bin, /usr/bin and /opt/homebrew/bin minus python3*, plus the fake: the tool itself needs
# GNU timeout and bash 5 from homebrew, never python3)
mkdir -p $W/nopy; for b in /bin/* /usr/bin/* /opt/homebrew/bin/*; do n=$(basename "$b"); [[ $n == python3* ]] || ln -sf "$b" $W/nopy/$n; done
chk "control for run B: the no-python3 PATH holds timeout and bash and no python3 (the plain PATH does)" "[ -x $W/nopy/timeout ] && [ -x $W/nopy/bash ] && [ \$(ls $W/nopy | grep -c '^python3') = 0 ] && [ -n \"\$(command -v python3)\" ]" "$(ls $W/nopy | grep -c '') links"
out=$(fresh; mkdir -p $W/b; cd $W/b && env PATH=$S/fake:$W/nopy FF_RAILS='198.19.1.0/24;198.19.2.0/24' $RUN timeout 120 $B $C 1 2>&1); brc=$?
chk "no python3 on PATH: the .tgz lands, no .html, rc equal to the plain run's, one line 'Dashboard not written: python3 not found; render it with: python3 generate_dashboard.py ' naming the tgz (control: the plain run has 0 such lines, a planted one counts 1)" \
    "[ \$(ls $W/b | grep -c '^fabric_ferret_rtest_.*\.tgz$') = 1 ] && [ \$(ls $W/b | grep -c '\.html$') = 0 ] && [ $brc = $arc ] && [ \$(grep -c '^# Dashboard not written: python3 not found; render it with: python3 generate_dashboard.py .*fabric_ferret_rtest_.*\.tgz' <<<\"\$out\") = 1 ] && [ \$(grep -c 'Dashboard not written' $W/a.out 2>&1) = 0 ] && [ \$({ cat $W/a.out; echo '# Dashboard not written: planted'; } | grep -c 'Dashboard not written') = 1 ]" \
    "rc=$brc vs $arc files: $(ls $W/b | tr '\n' ' ') | $(grep -E '^# (Bundle|Dashboard)' <<<"$out" | cut -c1-140 | tr '\n' '|')"
# C: the built script alone (no generate_dashboard.py beside it), as `ssh jump bash -s < fabric_ferret.sh` leaves it
mkdir -p $W/alone; cp $C $W/alone/fabric_ferret.sh
out=$(xrun c env $RUN timeout 120 $B $W/alone/fabric_ferret.sh 1); crc=$?; printf '%s\n' "$out" > $W/c.out
chk "generator not beside the tool: the .tgz lands, no .html, rc equal to the plain run's, one line 'Dashboard not written: generate_dashboard.py not beside the tool (a bash -s run?); render it with: python3 generate_dashboard.py ' naming the tgz; control: the copy's dir holds no generate_dashboard.py and the plain run's does" \
    "[ \$(ls $W/c | grep -c '^fabric_ferret_rtest_.*\.tgz$') = 1 ] && [ \$(ls $W/c | grep -c '\.html$') = 0 ] && [ $crc = $arc ] && [ \$(grep -c '^# Dashboard not written: generate_dashboard.py not beside the tool (a bash -s run?); render it with: python3 generate_dashboard.py .*fabric_ferret_rtest_.*\.tgz' <<<\"\$out\") = 1 ] && [ ! -e $W/alone/generate_dashboard.py ] && [ -e $(dirname $C)/generate_dashboard.py ]" \
    "rc=$crc vs $arc files: $(ls $W/c | tr '\n' ' ') | $(grep -E '^# (Bundle|Dashboard)' <<<"$out" | cut -c1-140 | tr '\n' '|')"
chk "the rendered page is the generator's: rendering the plain run's bundle again by hand gives a page with the same title (control: the by-hand render exits 0 or 3)" \
    "python3 $P $W/a/\$tgz $W/a_again.html > $W/a_again.pout 2>&1; r=\$?; { [ \$r = 0 ] || [ \$r = 3 ]; } && [ \"\$(grep -o '<title>[^<]*' $W/a_again.html)\" = \"\$(grep -o '<title>[^<]*' $W/a/\$html)\" ]" "$(tail -n 1 $W/a_again.pout 2>&1)"
chk "signalled runs unchanged: this group made no partial collect dir (0 'partial data left' lines over its three runs; control: the signal groups assert that line)" \
    "[ \$(cat $W/a.out $W/c.out | grep -c 'partial data left') = 0 ] && [ \$({ cat $W/a.out; echo '# Run did not finish; partial data left in /x: tar czf x.tgz -C /p x && python3 generate_dashboard.py x.tgz'; } | grep -c 'partial data left') = 1 ]" "$(grep -c '' $W/a.out) log lines"
finish
