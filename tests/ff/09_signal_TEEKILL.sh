#!/opt/homebrew/bin/bash
# signal TEEKILL mid-run; the body is shared by the four 09_signal_* groups
# checks: 3
# secs: 9
SIGS=TEEKILL; source "$(dirname "${BASH_SOURCE[0]}")/_signal.sh" "$@"
