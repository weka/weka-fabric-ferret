#!/opt/homebrew/bin/bash
# ssh retry on resets, timeouts not retried, jump-host fetch line
# checks: 5
# secs: 42
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

rm -f $FAKE_STATE/flaky.*
# SSH_CONNECTION only feeds the closing fetch line, so the jump-host check rides on this run (was its own run)
out=$(SSH_CONNECTION="192.0.2.9 50000 192.0.2.10 22" FAKE_FLAKY="198.18.0.2 198.18.0.3" FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3 FF_ITER=3 frunfull)
chk "ssh retry recovers resets" "grep -q 'Retry recovered 2 of 2' <<<\"\$out\" && grep -q 'coverage=COMPLETE hosts=3/3' <<<\"\$out\"" "$(grep -E 'Retry|RESULT' <<<"$out")"
chk "resets retried: 'Retrying' logged (control for 'timeouts not retried')" "grep -q 'Retrying' <<<\"\$out\"" "$(grep -c 'Retrying' <<<"$out") Retrying lines"
# since the run renders its own page (10-29 16:43): one scp line per file, tgz then html, the old "Fetch and render" line only
# when no html was written (19_render covers that case)
chk "jump-host fetch lines: 'Fetch: scp <user>@192.0.2.10:<tgz> .' then 'Fetch: scp ...:<html> .' (same base name, in that order), 0 'Fetch and render' lines (control: a planted one counts 1)" \
    "f=\$(grep -n -E '^# Fetch: scp [^@ ]+@192\.0\.2\.10:.*/fabric_ferret_h1_[0-9TZ]+\.(tgz|html) \.\$' <<<\"\$out\"); [ \$(wc -l <<<\"\$f\") = 2 ] && [ \"\$(sed -E 's/.*\.(tgz|html) \.$/\1/' <<<\"\$f\" | tr '\n' ' ')\" = 'tgz html ' ] && [ \$(sed -E 's/.*(fabric_ferret_h1_[0-9TZ]+)\.(tgz|html) \.$/\1/' <<<\"\$f\" | sort -u | wc -l) = 1 ] && [ \$(grep -c 'Fetch and render' <<<\"\$out\") = 0 ] && [ \$({ printf '%s\n' \"\$out\"; echo '# Fetch and render: planted'; } | grep -c 'Fetch and render') = 1 ]" \
    "$(grep -E 'Fetch' <<<"$out" | cut -c1-140 | tr '\n' '|')"
out=$(FAKE_FLAKY_FOREVER="198.18.0.3" FF_HOSTS=198.18.0.1,198.18.0.2,198.18.0.3 FF_ITER=3 frunfull)
chk "persistent reset stays unreachable" "grep -q 'Retry recovered 0 of 1' <<<\"\$out\" && grep -q 'coverage=PARTIAL hosts=2/3' <<<\"\$out\""
out=$(FF_HOSTS=198.18.0.1,198.18.0.6 frunfull); chk "timeouts not retried" "! grep -q 'Retrying' <<<\"\$out\""
finish
