#!/opt/homebrew/bin/bash
# A stand-in viewer: says what FF_FERRET and FF_SSH_USER it sees in its environment, then copies the log (both
# suites: a -t file's settings must reach a child as the command line's would).
echo "# viewer sees FF_FERRET=${FF_FERRET-UNSET} FF_SSH_USER=${FF_SSH_USER-UNSET}"; cat
