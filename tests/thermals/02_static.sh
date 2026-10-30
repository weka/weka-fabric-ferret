#!/opt/homebrew/bin/bash
# static: --list, bash 3.2, shebang, built from src/, run as ./script (from test_thermals.sh, split into sections 10-26)
# tier: fast
# checks: 7
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
chk "--list: expands like fabric_ferret.sh (198.19.100-101.1-2 -> 4)" "[ \"\$(FF_HOSTS=198.19.100-101.1-2 $B $TC --list | tr '\n' ' ')\" = '198.19.100.1 198.19.100.2 198.19.101.1 198.19.101.2 ' ]"
o32=$(FF_HOSTS=198.19.104.1 /bin/bash $TC 2>&1); rc=$?
chk "bash 3.2 (/bin/bash): refused, needs bash 4.3+ (rc 2)" "[ $rc = 2 ] && grep -q 'needs bash 4.3+' <<<\"\$o32\"" "rc=$rc $o32"
chk "shebang is #!/usr/bin/env bash (field tool: the bash first on PATH)" "[ \"\$(head -n 1 $TC)\" = '#!/usr/bin/env bash' ]"
# the script is built from src/ (README, Source): it must equal what ./build makes of src/ now (./build also writes
# hostlist.example.csv from the built fabric_ferret.sh's usage text, so it needs a bash 4.3+ first on PATH)
mkdir -p $W/build; bo=$(cd "$(dirname "$TC")" && PATH=/opt/homebrew/bin:$PATH ./build "$W/build" 2>&1); brc=$?
chk "built: thermals_capture.sh equals ./build's output from src/" "[ $brc = 0 ] && cmp -s $TC $W/build/thermals_capture.sh" "build rc=$brc $bo $(diff $TC $W/build/thermals_capture.sh 2>&1 | head -n 5)"
{ cat $TC; echo '# a hand edit'; } > $W/hand_edit.sh
chk "built check control: a hand edit of the built file differs from ./build's output" "[ -s $W/build/thermals_capture.sh ] && [ \$(diff $TC $W/hand_edit.sh | grep -c '^>') = 1 ] && ! cmp -s $W/hand_edit.sh $W/build/thermals_capture.sh"
o5=$(cd $W && PATH=/opt/homebrew/bin:/usr/bin:/bin FF_HOSTS=198.19.104.1 $TC --list 2>&1); rc5=$?
o3=$(cd $W && PATH=/usr/bin:/bin FF_HOSTS=198.19.104.1 $TC --list 2>&1); rc3=$?
chk "run as ./script: bash 5 first on PATH works; only macOS 3.2 on PATH is refused (needs bash 4.3+)" "[ $rc5 = 0 ] && [ \"\$o5\" = 198.19.104.1 ] && [ $rc3 = 2 ] && grep -q 'needs bash 4.3+' <<<\"\$o3\"" "rc5=$rc5 [$o5] rc3=$rc3 [$o3]"
# 10-26 20:04: the version check comes first, so bash 3.2 prints the refusal and the RESULT line, nothing else
v32=$(/bin/bash -c 'echo $BASH_VERSION')
chk "bash 3.2: the refusal is the only output (no 'declare: -A' lines before it)" "[ \"\$o3\" = \"\$(printf 'thermals_capture.sh: needs bash 4.3+ (this is bash %s)\nRESULT data=STOPPED (needs bash 4.3+)' \"$v32\")\" ]" "$o3"
finish
