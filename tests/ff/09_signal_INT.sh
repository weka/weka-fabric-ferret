#!/opt/homebrew/bin/bash
# signal INT mid-run; the body is shared by the four 09_signal_* groups
# checks: 3
SIGS=INT; source "$(dirname "${BASH_SOURCE[0]}")/_signal.sh" "$@"
