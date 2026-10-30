#!/opt/homebrew/bin/bash
# static checks, target expansion, round robin (no fake runs)
# tier: fast
# checks: 30
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"

# --- static ---
chk "bash -n (5.x)" "$B -n $C"
chk "no /dev/null in collector" "[ \$(grep -c /dev/null $C) = 0 ]"
chk "no /dev/null in parser" "[ \$(grep -c /dev/null $P) = 0 ]"
chk "parser compiles (python3)" "python3 -c 'import ast,sys; ast.parse(open(\"$P\").read())'"
# every warning an error: an invalid escape in a non-raw string (\d in the page template, 10-27) is a SyntaxWarning in 3.12
chk "parser compiles with warnings as errors (python3 -W error; the .pyc goes to the work dir, not the repo)" "python3 -W error -c 'import py_compile; py_compile.compile(\"$P\", cfile=\"$W/gd.pyc\", doraise=True)'" "$(python3 -W error -c "import py_compile; py_compile.compile('$P', cfile='$W/gd.pyc', doraise=True)" 2>&1 | tail -n 2)"
# ferret_view.py (FF_FERRET's display layer, beside the collector): compiles clean; piped with no terminal on stdout it
# copies stdin to stderr, nothing on stdout, no escape byte, rc 0. The escape count's control is a real viewer run
# captured on a pty (fixtures/units/ferret_pty.txt, the demo's synthetic lines), which must hold escapes.
V=$(dirname "$C")/ferret_view.py
chk "viewer compiles with warnings as errors (python3 -W error)" "python3 -W error -c 'import py_compile; py_compile.compile(\"$V\", cfile=\"$W/fv.pyc\", doraise=True)'" "$(python3 -W error -c "import py_compile; py_compile.compile('$V', cfile='$W/fv.pyc', doraise=True)" 2>&1 | tail -n 2)"
chk "no /dev/null in viewer" "[ \$(grep -c /dev/null $V) = 0 ]"
printf '# a\n# b\n' | python3 "$V" > $W/fv.out 2> $W/fv.err; fvrc=$?
chk "viewer without a terminal: the two lines on stderr, nothing on stdout, 0 escape bytes, rc 0" "[ $fvrc = 0 ] && [ \"\$(cat $W/fv.err)\" = \$'# a\n# b' ] && [ ! -s $W/fv.out ] && [ \$(LC_ALL=C tr -cd '\033' < $W/fv.err | wc -c) = 0 ]" "rc $fvrc; stderr: $(cat $W/fv.err); stdout bytes $(wc -c < $W/fv.out)"
FP=$S/fixtures/units/ferret_pty.txt
chk "control: the pty capture of a real viewer run holds escape bytes and the demo's lines" "[ \$(LC_ALL=C tr -cd '\033' < $FP | wc -c) -gt 1000 ] && [ \$(LC_ALL=C grep -a -c 'fabric_ferret.sh: 4 backends' $FP) -gt 0 ]" "esc $(LC_ALL=C tr -cd '\033' < $FP | wc -c)"
# the roll, live on a pty (/usr/bin/expect, fixtures/units/ferret_roll.exp): 50 synthetic lines over 4 s, "r" after 1 s,
# FF_FERRET=over (the roll-over travels and bounces, 10-28) and FF_FERRET=ball (the control): the viewer ends with
# rc 0, no Traceback, escapes on the pty, and the plain copy at the end holds all 50 lines in both
RX=$S/fixtures/units/ferret_roll.exp; lines() { LC_ALL=C grep -a -o '# line [0-9]* fabric_ferret.sh: 4 backends' "$1" | sort -u; }
/usr/bin/expect -f $RX over $W/roll_over.cap "$V"; orc=$?
/usr/bin/expect -f $RX ball $W/roll_ball.cap "$V"; brc=$?
chk "roll-over on a pty (FF_FERRET=over, r sent): rc 0, 0 Traceback lines (planted control counts 1), escape bytes > 1000, all 50 lines in the plain copy" \
    "[ $orc = 0 ] && [ \$(LC_ALL=C grep -a -c Traceback $W/roll_over.cap) = 0 ] && [ \$(cat <(echo 'Traceback (planted)') $W/roll_over.cap | LC_ALL=C grep -a -c Traceback) = 1 ] && [ \$(LC_ALL=C tr -cd '\033' < $W/roll_over.cap | wc -c) -gt 1000 ] && [ \$(lines $W/roll_over.cap | wc -l | tr -d ' ') = 50 ]" \
    "rc $orc; bytes $(wc -c < $W/roll_over.cap | tr -d ' ') esc $(LC_ALL=C tr -cd '\033' < $W/roll_over.cap | wc -c | tr -d ' ') lines $(lines $W/roll_over.cap | wc -l | tr -d ' ')"
chk "control: the ball roll (FF_FERRET=ball, r sent) on the same pty run: rc 0, 0 Traceback, escapes > 1000, 50 lines; both plain copies hold the same line set" \
    "[ $brc = 0 ] && [ \$(LC_ALL=C grep -a -c Traceback $W/roll_ball.cap) = 0 ] && [ \$(LC_ALL=C tr -cd '\033' < $W/roll_ball.cap | wc -c) -gt 1000 ] && [ \$(lines $W/roll_ball.cap | wc -l | tr -d ' ') = 50 ] && cmp -s <(lines $W/roll_over.cap) <(lines $W/roll_ball.cap)" \
    "rc $brc; bytes $(wc -c < $W/roll_ball.cap | tr -d ' ') esc $(LC_ALL=C tr -cd '\033' < $W/roll_ball.cap | wc -c | tr -d ' ') lines $(lines $W/roll_ball.cap | wc -l | tr -d ' ')"
# the collector is built from src/ (README, Source): it must equal what ./build makes of src/ now (./build writes
# hostlist.example.csv from the built tool's usage text, so it needs a bash 4.3+ first on PATH)
mkdir -p $W/build; bo=$(cd "$(dirname "$C")" && PATH=/opt/homebrew/bin:$PATH ./build "$W/build" 2>&1); brc=$?
chk "built: $(basename $C) equals ./build's output from src/" "[ $brc = 0 ] && cmp -s $C $W/build/fabric_ferret.sh" "build rc=$brc $bo $(diff $C $W/build/fabric_ferret.sh 2>&1 | head -n 5)"
chk "built: the committed hostlist.example.csv equals what ./build writes from the usage text (every FF_ setting at its default)" "[ $brc = 0 ] && cmp -s $(dirname $C)/hostlist.example.csv $W/build/hostlist.example.csv && [ \$(grep -c '^# FF_[A-Z0-9_]*=' $W/build/hostlist.example.csv) -ge 40 ]" "$(diff $(dirname $C)/hostlist.example.csv $W/build/hostlist.example.csv 2>&1 | head -n 5)"
{ cat $C; echo '# a hand edit'; } > $W/hand_edit.sh
chk "built check control: a hand edit of the built file differs from ./build's output" "[ -s $W/build/fabric_ferret.sh ] && [ \$(diff $C $W/hand_edit.sh | grep -c '^>') = 1 ] && ! cmp -s $W/hand_edit.sh $W/build/fabric_ferret.sh"
# a function defined twice in one assembly (a shared module beside a copy) runs as whichever came last: ./build refuses
# it by name. Control: a copy of src/ with log() appended to a shared module fails the build naming log, and writes nothing
mkdir -p $W/dup/out; cp -R "$(dirname "$C")/build" "$(dirname "$C")/src" $W/dup/; printf 'log() { :; }\n' >> $W/dup/src/sh/ipaddr.sh
dbo=$(cd $W/dup && PATH=/opt/homebrew/bin:$PATH ./build "$W/dup/out" 2>&1); dbrc=$?
chk "build refuses a function defined twice (planted log() in a shared module: rc 1, the message names log, no file written); the clean build above passed (rc 0)" "[ $brc = 0 ] && [ $dbrc = 1 ] && grep -q '^build: a function defined twice in the fabric_ferret.sh assembly: log\$' <<<\"\$dbo\" && [ ! -e $W/dup/out/fabric_ferret.sh ]" "rc=$dbrc $dbo"
# field tool: the bash first on PATH, and a bash 3.2 there (macOS /bin/bash) is refused by name
chk "shebang is #!/usr/bin/env bash" "[ \"\$(head -n 1 $C)\" = '#!/usr/bin/env bash' ]" "$(head -n 1 $C)"
o5=$(cd $W && PATH=/opt/homebrew/bin:/usr/bin:/bin FF_HOSTS=198.18.0.1 $C --list 2>&1); rc5=$?
o3=$(cd $W && PATH=/usr/bin:/bin FF_HOSTS=198.18.0.1 $C --list 2>&1); rc3=$?
chk "run as ./script: bash 5 first on PATH works; only macOS 3.2 on PATH is refused (needs bash 4.3+)" "[ $rc5 = 0 ] && grep -qx 198.18.0.1 <<<\"\$o5\" && [ $rc3 = 2 ] && grep -q 'needs bash 4.3+' <<<\"\$o3\"" "rc5=$rc5 [$o5] rc3=$rc3 [$o3]"
# 10-26 20:04: the version check comes first, so bash 3.2 prints the refusal and the RESULT line, nothing else
v32=$(/bin/bash -c 'echo $BASH_VERSION')
chk "bash 3.2: the refusal is the only output (no 'declare: -A' lines before it)" "[ \"\$o3\" = \"\$(printf 'fabric_ferret.sh: needs bash 4.3+ (this is bash %s)\nRESULT coverage=STOPPED (needs bash 4.3+)' \"$v32\")\" ]" "$o3"

# --- target expansion ---
n=$(FF_HOSTS="198.18.30.10-198.18.31.20" $B $C --list 2>&1 | grep -vc '^#'); chk "full range = 267" "[ $n = 267 ]" "got $n"
n=$(FF_HOSTS="198.18.64-65.1-30" $B $C --list 2>&1 | grep -vc '^#'); chk "nmap octets = 60" "[ $n = 60 ]" "got $n"
n=$(FF_HOSTS="198.18.30.0/24" $B $C --list 2>&1 | grep -vc '^#'); chk "cidr /24 = 254" "[ $n = 254 ]" "got $n"
out=$(FF_HOSTS="198.18.0.0/8" $B $C --list 2>&1); chk "cap refuses /8" "[[ \"$out\" == *FF_MAX_TARGETS* ]]"
out=$(FF_HOSTS="198.18.0.1,198.18.0.300" $B $C --list 2>&1); chk "a bad entry is refused naming the setting it came from (FF_HOSTS: bad octet)" "grep -q \"^ERROR: FF_HOSTS: bad octet '300' in '198.18.0.300'\" <<<\"\$out\"" "$out"
out=$(FF_HOSTS=198.18.0.1 FF_CLIENTS="198.18.1.0/33" $B $C --list 2>&1); chk "... and FF_CLIENTS: bad CIDR" "grep -q \"^ERROR: FF_CLIENTS: bad CIDR: '198.18.1.0/33'\" <<<\"\$out\"" "$out"
out=$(FF_HOSTS=198.18.0.1,198.18.0.2 $B -s -- --list < $C 2>&1); chk "stdin launch runs main" "[[ \"$out\" == *'2 targets'* ]]" "got: $out"
printf '%s\n' '# a plain host list' '198.18.0.1' '198.18.0.2' '198.18.0.0/30' > $W/plain.lst
out=$(env -u FF_HOSTS $B -s -- -t $W/plain.lst --list < $C 2>&1); chk "stdin launch with -t: a plain host list (2 named + a /30 overlapping them) = 2 targets" "[[ \"$out\" == *'# 2 targets'* ]] && ! grep -q '^client' <<<\"\$out\"" "got: $out"

# --- round robin ---
out=$($B $S/test_rr.sh 2>&1); chk "round-robin full coverage 2..9" "! grep -q 'dup=[1-9]' <<<\"\$out\" && [ \$(grep -c 'distinct=\([0-9]*\) of \1' <<<\"\$out\") = 8 ]" "$out"
chk "round-robin, two rail groups: each its own circle and bye, no pair across; the second cycle swaps client and server" \
    "grep -qx 'two groups t=0: a1>a4(AB) a2>a3(AB) c2>c3(C) sits=c1' <<<\"\$out\" && grep -qx 'two groups t=3: a4>a1(AB) a3>a2(AB) c3>c2(C) sits=c1' <<<\"\$out\" && [ \$(grep -c '^two groups' <<<\"\$out\") = 4 ] && ! grep -E '^two groups' <<<\"\$out\" | grep -q 'a[0-9]>c\|c[0-9]>a'" "$(grep '^two groups' <<<"$out" | tr '\n' '|')"

# --- dashboard: every CDN library at an exact version (an unpinned URL changes dashboards on its own) ---
cdn=$(grep -oE '<(script|link) [^>]*https?://[^"]+' $P | sed -E 's/.*(https?:)/\1/'); unp=$(grep -vE '@[0-9]+\.[0-9]+\.[0-9]+/|/[0-9]+\.[0-9]+\.[0-9]+/|-[0-9]+\.[0-9]+\.[0-9]+\.min\.js$' <<<"$cdn")
chk "dashboard CDN URLs all version-pinned" "[ \$(wc -l <<<\"\$cdn\") -ge 8 ] && [ -z \"\$unp\" ]" "unpinned: $unp"
nosri=$(grep -E '<(script|link) [^>]*https?://' $P | grep -vE 'integrity="sha384-[A-Za-z0-9+/]{64}" crossorigin="anonymous"')
chk "dashboard CDN tags all carry SRI + crossorigin" "[ -z \"\$nosri\" ]" "no SRI: $nosri"

finish
