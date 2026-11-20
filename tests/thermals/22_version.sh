#!/opt/homebrew/bin/bash
# --version (1.0.0, 2026-11-20): each tool prints "<name> <version>" and exits 0 before anything else runs (no -t file
# read, no prompt, no run log); both tools carry the same version; --help lists it
# tier: fast
# checks: 4
# secs: 2
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
mkdir -p $W/tmp
# a -t file that does not exist and FF_PW_PROMPT=1: either would stop or prompt if anything ran before --version
vf=$(TMPDIR=$W/tmp FF_PW_PROMPT=1 $B $FF --version -t $W/none.csv 2> $W/ff.err); vfrc=$?
vt=$(TMPDIR=$W/tmp FF_PW_PROMPT=1 $B $TC --version -t $W/none.csv 2> $W/tc.err); vtrc=$?
fv=$(sed -n 's/^FERRET_VERSION=\([^ ]*\).*/\1/p' $FF); tv=$(sed -n 's/^THERMALS_VERSION=\([^ ]*\).*/\1/p' $TC)
chk "fabric_ferret.sh --version: 'fabric_ferret.sh X.Y.Z' (its FERRET_VERSION), rc 0, no stderr, no temp file, the missing -t file not read" \
    "[[ \$(sed -n 's/^FERRET_VERSION=\([^ ]*\).*/\1/p' $FF) =~ ^[0-9]+\.[0-9]+\.[0-9]+\$ ]] && [ \"$vf\" = \"fabric_ferret.sh $fv\" ] && [ $vfrc = 0 ] && [ ! -s $W/ff.err ] && [ -z \"\$(ls -A $W/tmp)\" ]" \
    "rc=$vfrc [$vf] fv=$fv err=$(head -c 200 $W/ff.err)"
chk "thermals_capture.sh --version: 'thermals_capture.sh X.Y.Z' (its THERMALS_VERSION), rc 0, no stderr, no temp file, the missing -t file not read" \
    "[[ '$tv' =~ ^[0-9]+\.[0-9]+\.[0-9]+\$ ]] && [ \"$vt\" = \"thermals_capture.sh $tv\" ] && [ $vtrc = 0 ] && [ ! -s $W/tc.err ] && [ -z \"\$(ls -A $W/tmp)\" ]" \
    "rc=$vtrc [$vt] tv=$tv err=$(head -c 200 $W/tc.err)"
chk "both tools carry one version ($fv = $tv)" "[ -n '$fv' ] && [ '$fv' = '$tv' ]"
hf=$($B $FF --help 2>&1); ht=$($B $TC --help 2>&1)
chk "--help lists --version (both tools)" "grep -q -- '--version' <<<\"\$hf\" && grep -q -- '--version' <<<\"\$ht\""
finish
