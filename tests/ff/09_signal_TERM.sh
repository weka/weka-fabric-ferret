#!/opt/homebrew/bin/bash
# signal TERM mid-run; the body is shared by the four 09_signal_* groups
# checks: 3
SIGS=TERM; source "$(dirname "${BASH_SOURCE[0]}")/_signal.sh" "$@"
