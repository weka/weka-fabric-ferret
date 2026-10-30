#!/opt/homebrew/bin/bash
# moving to FF_RAILS 'a;b': FF_RAIL_A/FF_RAIL_B and the old comma form stop naming the ';' form; the subnet listing's FF_NICS hint
# checks: 6
# secs: 10
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
semi='[0-9]/[0-9]+;[0-9]'   # a CIDR, ';', the next rail: the ';' form spelled out

out=$(cd $W && FF_RAIL_A=198.19.1.0/24 FF_RAIL_B=198.19.2.0/24 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); rc=$?
chk "FF_RAIL_A+B stop and name the FF_RAILS ';' form" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -q 'FF_RAILS' <<<\"\$out\" && grep -qE '$semi' <<<\"\$out\" && ! grep -q 'unknown setting' <<<\"\$out\"" "rc=$rc $out"
out=$(cd $W && FF_RAIL_B=198.19.2.0/24 FF_HOSTS=198.18.0.21 $B $C --list 2>&1); rc=$?
chk "FF_RAIL_B alone stops too (guard before the unknown-setting check)" "[ $rc = 2 ] && grep -q 'FF_RAILS' <<<\"\$out\" && ! grep -q 'unknown setting' <<<\"\$out\"" "rc=$rc $out"

# the old two-rail comma form: both subnets now make one rail, every host has two NICs in it (AMBIGUOUS)
out=$(cd $W && PATH=$S/fake:$PATH FF_RAILS=198.19.1.0/24,198.19.2.0/24 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1 2>&1); rc=$?
chk "old comma form FF_RAILS=a,b stops naming the ';' form" "[ $rc = 2 ] && grep -q 'RESULT coverage=STOPPED' <<<\"\$out\" && grep -qE '$semi' <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR|RESULT' <<<"$out")"
# positive control: the ';' form of the same subnets runs
out=$(xrun semi FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1); rc=$?
chk "';' form of the same subnets runs (control)" "[ $rc = 0 ] && grep -q '^RESULT coverage=COMPLETE' <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR|RESULT' <<<"$out")"

# subnet listing, no rails set: both data NICs in one /16 -> suggest FF_NICS and show each NIC's /24
out=$(cd $W && PATH=$S/fake:$PATH FAKE_SAME16=1 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 timeout 60 $B $C 1 2>&1); rc=$?
chk "same /16 on both NICs: stop suggests FF_NICS" "[ $rc = 2 ] && grep -q 'FF_NICS' <<<\"\$out\" && ! grep -q 'FF_RAIL_A' <<<\"\$out\"" "rc=$rc $(grep -E 'ERROR|FF_' <<<"$out" | head -n 3)"
chk "same /16 on both NICs: listing shows each NIC's /24" "grep -q '198.19.1.0/24' <<<\"\$out\" && grep -q '198.19.2.0/24' <<<\"\$out\"" "$(grep '^#' <<<"$out" | head -n 6)"
# (control: the fake hands out /16 masks here, so a /24 can only come from the collector's per-NIC hint; b1fd7f7 lists only 198.19.0.0/16)
finish
