#!/opt/homebrew/bin/bash
# the one results table (scope 4 D, the operator 11-07): on Test Distribution every backend run, client run and failed
# run in one table, worst first (failed runs, then the lowest share of expected), 50 a page with a page-size dropdown,
# an All / Backends / Clients toggle that the title, pager and CSV follow; "Bottom 50" is gone. The page's own JS builds
# it at load; fixtures/units/pageload_probe.js "results" mode reads the rows and drives the page's own setters
# tier: fast
# checks: 8
# secs: 8
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
X=$S/fixtures/bundles
mkdir -p $W/gcsrc $W/gesrc && cp -R $S/fixtures/golden-C $W/gcsrc/dp_validation_goldenC && tar -czf $W/gc.tgz -C $W/gcsrc dp_validation_goldenC
# ge: golden-C with one failed backend run and one failed client run planted (iperf3's "Connection refused" line)
cp -R $S/fixtures/golden-C $W/gesrc/dp_validation_goldenC
echo '198.19.1.21,198.19.2.21,ERROR rc=1 iperf3: error - unable to connect to server: Connection refused' >> $W/gesrc/dp_validation_goldenC/iperf3_results.txt
echo '198.19.10.3,198.19.1.21,ERROR rc=1 iperf3: error - unable to connect to server: Connection refused' >> $W/gesrc/dp_validation_goldenC/client_results.txt
tar -czf $W/ge.tgz -C $W/gesrc dp_validation_goldenC
cp $X/14_where.tgz $W/uw.tgz
for p in gc ge uw; do python3 $P $W/$p.tgz $W/$p.html > $W/$p.pout 2>&1; echo "rc=$?" >> $W/$p.pout
    node $S/fixtures/units/pageload_probe.js $W/$p.html results > $W/$p.res 2>&1; done
rj() { grep '^{"results"' $W/$1.res | jq -r ".results | $2"; }   # rj <page> <jq path>
re() { grep '^{"results"' $W/$1.res | jq -r '.results_errors'; }
# golden-C: 8 backend runs (iperf3_results.txt) + 60 client runs (client_results.txt); 14_where: 6 + 20
chk "4D: one table (golden-C): the card header 'Individual Test Results (68 runs, worst first)' once; 0 'Bottom 50 Individual Test Results', 0 id=\"bottomTable\", 0 bottom_50.csv (control: a planted copy counts 1 of each); the CSV file is test_results.csv" \
    "[ \$(grep -c 'Individual Test Results (68 runs, worst first)' $W/gc.html) = 1 ] && [ \$(grep -c 'Bottom 50 Individual Test Results' $W/gc.html) = 0 ] && [ \$(grep -c 'id=\"bottomTable\"' $W/gc.html) = 0 ] && [ \$(grep -c 'bottom_50.csv' $W/gc.html) = 0 ] && [ \$({ cat $W/gc.html; echo 'Bottom 50 Individual Test Results id=\"bottomTable\" bottom_50.csv'; } | grep -c 'Bottom 50 Individual Test Results.*id=\"bottomTable\".*bottom_50.csv') = 1 ] && grep -q 'test_results.csv' $W/gc.html" \
    "$(grep -o 'Individual Test Results ([^)]*)' $W/gc.html | head -n 1) bottom: $(grep -c 'Bottom 50' $W/gc.html) $(tail -n 1 $W/gc.pout)"
chk "4D: rows at load (golden-C, 8 backend + 60 client runs): 50 rows in the body by default (0 probe errors), pager 'page 1 of 2, 68 rows', title '(68 runs, worst first)'; page size All shows 68 (8 backend, 60 client, 0 failed)" \
    "[ \$(re gc) = 0 ] && [ \$(rj gc .load.rows) = 50 ] && [ \"\$(rj gc .load.pager)\" = 'page 1 of 2, 68 rows' ] && [ \"\$(rj gc .load.title)\" = 'Individual Test Results (68 runs, worst first)' ] && [ \"\$(rj gc '[.all.rows, .all.backend, .all.client, .all.failed] | join(\" \")')\" = '68 8 60 0' ]" \
    "errors=$(re gc) load: $(rj gc '.load | [.rows, .pager, .title] | join(" | ")') all: $(rj gc '.all | [.rows, .backend, .client, .failed] | join(" ")')"
chk "4D: worst first (golden-C, every view): the share of expected never decreases down the table, and the first measured row carries the table's lowest share (load, All, Backends, Clients, page 2)" \
    "[ \"\$(rj gc '[.load, .all, .backends, .clients, .page2] | map(.sorted) | join(\" \")')\" = 'true true true true true' ] && [ \"\$(rj gc '.load.first_share == .all.min_share')\" = true ] && [ \"\$(rj gc '.all.first_share == .all.min_share')\" = true ] && [ \"\$(rj gc '.all.min_share != null')\" = true ]" \
    "sorted: $(rj gc '[.load, .all, .backends, .clients, .page2] | map(.sorted) | join(" ")') first/min: $(rj gc '[.load.first_share, .all.min_share] | join("/")')"
chk "4D: failed runs first (ge: golden-C with one backend and one client failure planted): All 70 with 2 failed rows at the top, the first reading ERROR and iperf3's reason 'unable to connect to server: Connection refused'; Backends 9 (1 failed), Clients 61 (1 failed); control: golden-C counts 0 failed on each view" \
    "[ \$(re ge) = 0 ] && [ \"\$(rj ge '[.all.rows, .all.failed, .all.failed_first] | join(\" \")')\" = '70 2 true' ] && grep -q 'ERROR' <<<\"\$(rj ge .all.first_text)\" && grep -q 'unable to connect to server: Connection refused' <<<\"\$(rj ge .all.first_text)\" && [ \"\$(rj ge '[.backends.rows, .backends.failed, .clients.rows, .clients.failed] | join(\" \")')\" = '9 1 61 1' ] && [ \"\$(rj gc '[.all.failed, .backends.failed, .clients.failed] | join(\" \")')\" = '0 0 0' ]" \
    "errors=$(re ge) all: $(rj ge '.all | [.rows, .failed, .failed_first] | join(" ")') first: $(rj ge .all.first_text | cut -c1-120) b/c: $(rj ge '[.backends.rows, .clients.rows] | join("/")') $(tail -n 1 $W/ge.pout)"
chk "4D: the toggle (golden-C): Backends 8 rows all backend, Clients 60 all client, 8 + 60 = All 68; the title and pager follow the filter ('(8 runs, worst first)', 'page 1 of 1, 8 rows' at page size All)" \
    "[ \"\$(rj gc '[.backends.rows, .backends.backend, .backends.client] | join(\" \")')\" = '8 8 0' ] && [ \"\$(rj gc '[.clients.rows, .clients.backend, .clients.client] | join(\" \")')\" = '60 0 60' ] && [ \"\$(rj gc '.backends.rows + .clients.rows == .all.rows')\" = true ] && [ \"\$(rj gc .backends.title)\" = 'Individual Test Results (8 runs, worst first)' ] && [ \"\$(rj gc .backends.pager)\" = 'page 1 of 1, 8 rows' ] && [ \"\$(rj gc .clients.title)\" = 'Individual Test Results (60 runs, worst first)' ]" \
    "backends: $(rj gc '.backends | [.rows, .backend, .client, .title, .pager] | join(" | ")') clients: $(rj gc '.clients | [.rows, .backend, .client] | join(" ")')"
chk "4D: paging: golden-C page 2 of 2 at 50 a page holds 18 rows (pager 'page 2 of 2, 68 rows'); 14_where (6 backend + 20 client runs) is one page: 26 rows at load, pager 'page 1 of 1, 26 rows', 0 probe errors" \
    "[ \"\$(rj gc '[.page2.rows, .page2.pager] | join(\" | \")')\" = '18 | page 2 of 2, 68 rows' ] && [ \$(re uw) = 0 ] && [ \"\$(rj uw '[.load.rows, .load.backend, .load.client, .load.pager] | join(\" | \")')\" = '26 | 6 | 20 | page 1 of 1, 26 rows' ]" \
    "gc page2: $(rj gc '.page2 | [.rows, .pager] | join(" | ")') uw load: $(rj uw '.load | [.rows, .backend, .client, .pager] | join(" | ")') errors=$(re uw) $(tail -n 1 $W/uw.pout)"
chk "4D: the CSV follows the toggle: resultsCsvText() lines = rows + 1 header: golden-C 69 (All) / 9 (Backends) / 61 (Clients), ge 71; the header starts with Role and names 11 columns" \
    "[ \"\$(rj gc '[.csv_all, .csv_backends, .csv_clients] | join(\" \")')\" = '69 9 61' ] && [ \$(rj ge .csv_all) = 71 ] && [ \$(rj gc .csv_head | awk -F, '{print NF}') = 11 ] && [ \"\$(rj gc .csv_head | cut -d, -f1 | tr -d '\"')\" = Role ]" \
    "csv: $(rj gc '[.csv_all, .csv_backends, .csv_clients] | join(" ")') ge $(rj ge .csv_all) head: $(rj gc .csv_head | cut -c1-120)"
# D2 (11-07): a backend run's Expected is its path's line rate, the slower of its two ends' rail rates, so backend and
# client rows interleave by share. golden-C (400G both rails): 325 and 385 Gbps runs are 81.25 and 96.25 % of 400, the
# client runs 92 / 92.5 % (unchanged); gm = golden-C with rail B at 200G: cross and rail-B runs read against 200.
# Shares sit on .x5 ties, so they are matched within 0.06, never pinned at one decimal (the page rounds half to even)
mkdir -p $W/gmsrc && cp -R $S/fixtures/golden-C $W/gmsrc/dp_validation_goldenC && sed -i '' 's/^line_rate_b_gbps=400$/line_rate_b_gbps=200/' $W/gmsrc/dp_validation_goldenC/metadata.txt && tar -czf $W/gm.tgz -C $W/gmsrc dp_validation_goldenC
python3 $P $W/gm.tgz $W/gm.html > $W/gm.pout 2>&1; echo "rc=$?" >> $W/gm.pout; node $S/fixtures/units/pageload_probe.js $W/gm.html results > $W/gm.res 2>&1
near() { rj $1 "([.all.$2[] | ($(for v in "${@:3}"; do printf '((. - %s | fabs) < 0.06) or ' $v; done) false)] | all) and (.all.$2 | length) == $(( $# - 2 ))"; }   # near <page> shares... : every share within 0.05 of one of the values, every value present
chk "4D2: backend share = gbps / path line rate (golden-C, 400G rails): the 8 backend rows read 81.25 and 96.25 % (±0.06) with Expected 400; the client shares stay 92 / 92.5 (control); under All the 4 runs at 81.25 come first (first share = min, within 0.06 of 81.25) and the first page holds 4 backend + 46 client rows; gm (rail B 200G): backend shares 81.25, 96.25, 162.5, 192.5 with Expected 200 and 400" \
    "[ \$(near gc backend_shares 81.25 96.25) = true ] && [ \"\$(rj gc '.all.backend_expected | map(sub(\"\\\\.0\$\"; \"\")) | join(\" \")')\" = 400 ] && [ \"\$(rj gc '.all.client_shares | join(\" \")')\" = '92 92.5' ] && [ \"\$(rj gc '.load.first_share == .all.min_share and ((.all.min_share - 81.25) | fabs) < 0.06')\" = true ] && [ \"\$(rj gc '[.load.backend, .load.client] | join(\" \")')\" = '4 46' ] && [ \$(near gm backend_shares 81.25 96.25 162.5 192.5) = true ] && [ \"\$(rj gm '.all.backend_expected | map(sub(\"\\\\.0\$\"; \"\")) | join(\" \")')\" = '200 400' ] && [ \$(re gm) = 0 ]" \
    "gc backend: $(rj gc '.all.backend_shares | join(" ")') exp $(rj gc '.all.backend_expected | join(" ")') client: $(rj gc '.all.client_shares | join(" ")') load b/c $(rj gc '[.load.backend, .load.client] | join("/")') | gm backend: $(rj gm '.all.backend_shares | join(" ")') exp $(rj gm '.all.backend_expected | join(" ")') errors=$(re gm) $(tail -n 1 $W/gm.pout)"
finish
