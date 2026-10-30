#!/opt/homebrew/bin/bash
# the escalator probe's 5 s timeout: a hung dzdo is cut off and the next escalator used (moved out of 04_auth so the
# fast tier stays under 15 s alone, 10-26)
# checks: 1
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
# the fake's hung dzdo sleeps 30 s: a wall of 5-24 s proves both the wait for the 5 s cut and the cut itself; the old
# window [5-9] read 10 under a -j 8 full tier (10-29 16:20; alone the probe takes 7-8 s)
o=$(rx "$TC" esc_slow)
chk "probe: a hung dzdo (30 s) is cut at 5 s, then sudo -n is used: wall 5-24 s" "grep -qx '@@ESC n1 sudo_-n' <<<\"\$o\" && grep -qE 'esc: dzdo -n true;sudo -n true;sudo -n ipmitool sensor; secs: ([5-9]|1[0-9]|2[0-4])\$' <<<\"\$o\"" "$o"
finish
