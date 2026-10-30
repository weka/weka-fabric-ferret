#!/opt/homebrew/bin/bash
# cross-rail runs in their own Cross column; every cross run slow (positive control). The dashboard on stored archives
# (fixtures/bundles/11_*, made by this group's two runs at c8ffd59; 10-26): the Status rules are units in 60
# (ff_nic_sum), the table header and RESULT's cross_rail=on are checked on golden-B (50)
# tier: fast
# checks: 3
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# cross-rail runs ride whichever NIC the routes pick (fsLab R2 /32 shape): kept out of Rail_A/Rail_B, own Cross column
python3 $P $S/fixtures/bundles/11_routed32.tgz $W/xc.html > $W/p.out 2>&1
chk "dashboard: Cross column in the per data NIC view, rail map not octet parity" "grep -q 'Cross<small>rail to rail' $W/xc.html && grep -qE '\"ip\": \"198\\.19\\.2\\.1\", \"role\": \"backend\", \"host\": \"h1\", \"nic\": \"[^\"]*\", \"rail\": \"B\"' $W/xc.html && ! grep -q 'cross-rail (A&lt;-&gt;B) runs below' $W/xc.html"
# positive control: same-rail healthy, every cross run slow -> the dashboard raises a problem
python3 $P $S/fixtures/bundles/11_xcrit.tgz $W/xs.html > $W/p.out 2>&1
chk "dashboard: slow cross runs are a problem" "grep -q 'cross-rail (A&lt;-&gt;B) runs below 300 Gbps' $W/xs.html"
# tab dots (criterion 3) on the every-cross-run-slow page: Connection Health red, Needs Repair amber, NIC / Optics amber with
# its drop count in the label (control: the label counted once on the page, twice with a planted copy)
chk "tab dots (11_xcrit, A4): connections red, slow RED (2 CRITICAL NICs need repair: header '<b class=\"stat-bad\">2</b> need repair |', label 'Needs Repair (<span class=\"stat-bad\">2</span>)', card 'NICs that need repair — 2'), temps green, nic amber with 'NIC / Optics (<span class=\"stat-warn\">1 with drops</span>)', topology amber, checks red; control: the drops label counts 1 on the page and 2 with a planted copy" \
    "[ \"\$(grep -o '<a class=\"nav-link[^>]*href=\"#tab-[a-z]*\">[^<]*\(<span[^>]*>[^<]*</span>[^<]*\)*</a>' $W/xs.html | while IFS= read -r l; do t=\$(sed -E 's/.*href=\"#tab-([a-z]*)\".*/\\1/' <<<\"\$l\"); c=\$(grep -o 'tab-dot\" style=\"background:#[0-9a-f]*' <<<\"\$l\" | sed 's/.*background://'); printf '%s:%s ' \"\$t\" \"\${c:--}\"; done)\" = 'connections:#e94560 slow:#e94560 temps:#4ecca3 nic:#ffc107 distribution:- topology:#ffc107 checks:#e94560 all:- ' ] && grep -qF '<b class=\"stat-bad\">2</b> need repair |' $W/xs.html && grep -qF 'href=\"#tab-slow\">Needs Repair (<span class=\"stat-bad\">2</span>) <span class=\"tab-dot\"' $W/xs.html && grep -qF 'NICs that need repair — 2 (down, or CRITICAL' $W/xs.html && grep -qF '<th>Host</th><th>NIC</th><th>IP</th><th>Leaf</th><th>Worst column</th><th>Status</th>' $W/xs.html && [ \$(grep -o '<td>CRITICAL[^<]*</td>' $W/xs.html | wc -l) -ge 2 ] && grep -q 'NIC / Optics (<span class=\"stat-warn\">1 with drops</span>) <span class=\"tab-dot\"' $W/xs.html && [ \$(grep -c 'with drops' $W/xs.html) = 1 ] && [ \$({ cat $W/xs.html; echo 'NIC / Optics (<span class=\"stat-warn\">1 with drops</span>)'; } | grep -c 'with drops') = 2 ]" \
    "$(grep -o 'NIC / Optics ([^)]*)' $W/xs.html | head -n 1) | $(grep -o 'href=\"#tab-[a-z]*\">[^<]*' $W/xs.html | tr '\n' '|')"
finish
