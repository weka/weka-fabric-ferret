#!/opt/homebrew/bin/bash
# -t parser units (load_target_file, src/sh/hostfile.sh): types, bare lines, the five specificity tiers, equal-tier and
# unmatched warnings, * never reaching a bmc, case-insensitive globs, the default login, credential-less rows, refusals,
# and no password in any output. No thermals_capture run: the built script is sourced and the parser called alone.
# tier: fast
# checks: 44
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
me=$(id -un)
# lt <file> [deflogin] [script]: the parser's result, one line per target ("T target type login pw:set|- line") and
# per BMC ("B bmc login pw:set|- line"), after its warnings; a refusal prints the ERROR and RESULT lines
lt() { ( source "${3:-$TC}"; declare -ga T_LOGIN=() T_PW=() T_TYPE=() T_LINE=() T_FROM=() T_ROW=() BMCS=() B_LOGIN=() B_PW=() B_LINE=() B_ROW=()
         declare -gA _SEEN=(); TARGETS=(); HAVE_PW=0; INPUT_RANGES=0; FF_MAX_TARGETS=4096
         HF_KNOWN=$TC_KNOWN; HF_OTHER=$FF_KNOWN; HF_OTHER_NAME=fabric_ferret.sh   # as the wrapper sets them before settings_prepass
         settings_prepass "$1"; for pl in "${HF_PRELOG[@]}"; do log "$pl"; done   # the pre-pass, then main's first log lines
         env | awk -F= '/^FF_(FERRET|VIEWER|SSH_USER)=/ {print "E " $0}' | sort   # what a child sees of the file's settings
         load_target_file "$1" "${FF_SSH_USER:-${2:-deflt}}"
         for k in "${!TARGETS[@]}"; do echo "T ${TARGETS[$k]} ${T_TYPE[$k]} ${T_LOGIN[$k]} pw:$( [[ -n ${T_PW[$k]+x} ]] && echo set || echo -) ${T_LINE[$k]}"; done
         for k in "${!BMCS[@]}"; do echo "B ${BMCS[$k]} ${B_LOGIN[$k]} pw:$( [[ -n ${B_PW[$k]} ]] && echo set || echo -) ${B_LINE[$k]}"; done ) 2>&1; }
mk() { local f=$W/$1; shift; printf '%s\n' "$@" > "$f"; chmod 600 "$f"; echo "$f"; }   # mk <name> <line>...: a 600 file

# --- the repository's example file (hostlist.example.csv, 10-27): 87 ssh targets (23 backends, 64 clients),
# one bmc; storage-09 by its own row (line 20), the other backends by backend,* (line 26), gpu-node-01/02 by the
# glob (line 27), the /26 clients (62) by the default; no warning, no password anywhere ---
o=$(lt "$(dirname "$TC")/hostlist.example.csv" deflt)
chk "hostlist.example.csv: 87 targets and 1 bmc; credentials by row as the header says; no warning" \
    "[ \$(grep -c '^T ' <<<\"\$o\") = 87 ] && grep -qx 'B 10.20.100.11 $me pw:- default' <<<\"\$o\" && grep -qx 'T storage-09 backend svc-fabric pw:- 20' <<<\"\$o\" && [ \$(grep -c '^T 10.20.1.[0-9]* backend svc-fabric pw:- 26\$' <<<\"\$o\") = 22 ] && [ \$(grep -c '^T gpu-node-0[12] client admin pw:- 27\$' <<<\"\$o\") = 2 ] && [ \$(grep -c '^T 10.20.2.[0-9]* client deflt pw:- default\$' <<<\"\$o\") = 62 ] && ! grep -qE 'WARNING|ERROR' <<<\"\$o\"" "$(grep -v '^T 10\.' <<<"$o" | tr '\n' '|')"

# --- settings lines (10-27, step 2): FF_SSH_USER from the file is the rows' default login; fabric_ferret.sh's
# names are skipped and named; the environment wins; an unknown name stops by line number, value unprinted ---
o=$(lt "$(mk sl 'FF_SSH_USER=bob' 'FF_ITER=3' 'backend,198.19.140.1')")
chk "settings lines: FF_SSH_USER=bob is the default login; FF_ITER (fabric_ferret.sh's) skipped and named" "grep -qx 'T 198.19.140.1 backend bob pw:- default' <<<\"\$o\" && grep -q ': 1 setting line(s) for fabric_ferret.sh skipped: FF_ITER$' <<<\"\$o\"" "$o"
# FF_FERRET and FF_VIEWER work from the file like any setting (read first, exported: 10-28): a child sees them
fF=$(mk tF 'backend,198.19.140.1' 'FF_FERRET=1'); oF=$(lt "$fF"); oC=$(lt "$(mk tFc 'backend,198.19.140.1')")
chk "settings lines: FF_FERRET=1 on line 2 loads and a child sees FF_FERRET=1 (control: the file without it: no E FF_FERRET line, the row loads)" "grep -qx 'E FF_FERRET=1' <<<\"\$oF\" && grep -qx 'T 198.19.140.1 backend deflt pw:- default' <<<\"\$oF\" && ! grep -q 'ERROR' <<<\"\$oF\" && ! grep -q '^E FF_FERRET' <<<\"\$oC\" && grep -qx 'T 198.19.140.1 backend deflt pw:- default' <<<\"\$oC\"" "$oF | $oC"
fV=$(mk tV 'backend,198.19.140.1' 'FF_VIEWER=/bin/cat'); oV=$(lt "$fV"); oX=$(lt "$(mk tVx 'backend,198.19.140.1' 'FF_VIEWERX=1')")
chk "settings lines: FF_VIEWER (the test hook) on line 2 loads and is exported (E FF_VIEWER=/bin/cat); control: FF_VIEWERX on line 2 is an unknown setting, no row, no E line" "grep -qx 'E FF_VIEWER=/bin/cat' <<<\"\$oV\" && grep -qx 'T 198.19.140.1 backend deflt pw:- default' <<<\"\$oV\" && grep -q 'line 2: unknown setting FF_VIEWERX;' <<<\"\$oX\" && ! grep -q '^[TE] ' <<<\"\$oX\"" "$oV | $oX"
o=$(FF_SSH_USER=deflt lt "$(mk se 'FF_SSH_USER=bob' 'backend,198.19.140.1')")
chk "settings lines: FF_SSH_USER exported in the environment wins over the file (login stays the default, the line named)" "grep -qx 'T 198.19.140.1 backend deflt pw:- default' <<<\"\$o\" && grep -q 'line 1: FF_SSH_USER is set in the environment; the file.s value is ignored' <<<\"\$o\"" "$o"
o=$(lt "$(mk su 'backend,198.19.140.1' 'FF_FOO=topsecret')")
chk "settings lines: an unknown name stops with its line number and the known list, the value never printed" "grep -q 'line 2: unknown setting FF_FOO; this tool reads: FF_HOSTS, FF_SSH_USER, ' <<<\"\$o\" && ! grep -q topsecret <<<\"\$o\"" "$o"
o=$(lt "$(mk ss 'FF_SSH_USER = bob' 'backend,198.19.140.1' 'FF_MAX_TARGETS = abc')")
chk "settings lines: spaces around = are fine (FF_SSH_USER = bob applies); FF_MAX_TARGETS = abc stops by line number, no value" "grep -q 'line 3: FF_MAX_TARGETS must be a positive integer$' <<<\"\$o\" && ! grep -q abc <<<\"\$o\"" "$o"

# --- types and bare lines ---
o=$(lt "$(mk types 'backend,198.19.140.1' 'client,198.19.140.2' 'host,198.19.140.3' 'Client,198.19.140.5' '198.19.140.4' 'bmc,198.19.141.1')")
chk "types: backend, client, host = backend, type in any case, a bare line = backend, bmc" "[ \"\$(grep '^[TB] ' <<<\"\$o\" | awk '{print \$2, \$3}' | tr '\n' '|')\" = '198.19.140.1 backend|198.19.140.2 client|198.19.140.3 backend|198.19.140.5 client|198.19.140.4 backend|198.19.141.1 $me|' ]" "$o"
chk "no credentials anywhere: every target takes the default login, key, line 'default'; a bmc the current user, no pw" "[ \"\$(grep '^T ' <<<\"\$o\" | awk '{print \$4, \$5, \$6}' | sort -u)\" = 'deflt pw:- default' ] && grep -qx 'B 198.19.141.1 $me pw:- default' <<<\"\$o\"" "$o"

# --- specificity: one host > CIDR/range > glob > <type>,* > *,* > default, whatever the line order ---
H1='backend,198.19.142.1'
oA=$(lt "$(mk tA '*,*,l1' 'backend,*,l2' 'backend,198.19.142.*,l3' 'backend,198.19.142.0/30,l4' 'backend,198.19.142.1,l5')")
chk "tier 5: the line naming the host wins (l5, line 5); its neighbour .2 takes the range (l4, line 4)" "grep -qx 'T 198.19.142.1 backend l5 pw:- 5' <<<\"\$oA\" && grep -qx 'T 198.19.142.2 backend l4 pw:- 4' <<<\"\$oA\"" "$oA"
oB=$(lt "$(mk tB '*,*,l1' 'backend,*,l2' 'backend,198.19.142.*,l3' "$H1" 'backend,198.19.142.0/30,l4')")
chk "tier 4: no credentials on the host's line: the range (l4) over the glob, type-* and *-*" "grep -qx 'T 198.19.142.1 backend l4 pw:- 5' <<<\"\$oB\"" "$oB"
oC=$(lt "$(mk tC "$H1" 'backend,198.19.142.*,l3' 'backend,*,l2' '*,*,l1')")
chk "tier 3: the glob (l3) over type-* and *-*" "grep -qx 'T 198.19.142.1 backend l3 pw:- 2' <<<\"\$oC\"" "$oC"
oD=$(lt "$(mk tD '*,*,l1' "$H1" 'backend,*,l2')")
chk "tier 2: backend,* (l2) over *,*" "grep -qx 'T 198.19.142.1 backend l2 pw:- 3' <<<\"\$oD\"" "$oD"
oE=$(lt "$(mk tE "$H1" '*,*,l1')")
chk "tier 1: *,* (l1)" "grep -qx 'T 198.19.142.1 backend l1 pw:- 2' <<<\"\$oE\"" "$oE"
oF=$(lt "$(mk tF "$H1" 'client,*,cl')")
chk "no row for its type: the default login (client,* does not reach a backend)" "grep -qx 'T 198.19.142.1 backend deflt pw:- default' <<<\"\$oF\" && grep -q 'line 2 matches no target' <<<\"\$oF\"" "$oF"
oP=$(lt "$(mk tP "$H1" 'backend,*,,pwonly' '*,*,l1')")
chk "a pw-only row: the default login with that pw, and it is THE credential (no fallback to *,*'s login)" "grep -qx 'T 198.19.142.1 backend deflt pw:set 2' <<<\"\$oP\"" "$oP"

# --- warnings: equal level, different credentials -> the first, warned once with both line numbers; no match -> warned ---
oW=$(lt "$(mk tW 'backend,198.19.143.1' 'backend,198.19.143.*,ga' 'backend,198.19.14[3].*,gb' 'backend,198.19.14?.*,ga')")
chk "equal level, different: the first line (2, ga) is used and lines 2 and 3 named in one WARNING" "grep -qx 'T 198.19.143.1 backend ga pw:- 2' <<<\"\$oW\" && [ \$(grep -c 'WARNING: .*lines 2 and 3 give a target different credentials at the same specificity; line 2.s are used' <<<\"\$oW\") = 1 ]" "$oW"
chk "equal level, same credentials (lines 2 and 4, both ga): no warning (control)" "! grep -q 'lines 2 and 4' <<<\"\$oW\" && [ \$(grep -c WARNING <<<\"\$oW\") = 1 ]" "$oW"
oU=$(lt "$(mk tU 'backend,198.19.144.1' 'backend,zz*,x' 'backend,198.19.144.?,y')")
chk "a credential row matching nothing (line 2) is warned; the one that matches (line 3) is not" "grep -q 'WARNING: .* line 2 matches no target' <<<\"\$oU\" && ! grep -q 'line 3 matches' <<<\"\$oU\" && grep -qx 'T 198.19.144.1 backend y pw:- 3' <<<\"\$oU\"" "$oU"

# --- bmc: * never reaches one; bmc,* and a bmc glob do ---
oM=$(lt "$(mk tM 'bmc,198.19.145.1' 'backend,198.19.145.9' '*,*,star,spw')")
chk "*,* reaches the backend, never the bmc (current user, no pw)" "grep -qx 'B 198.19.145.1 $me pw:- default' <<<\"\$oM\" && grep -qx 'T 198.19.145.9 backend star pw:set 3' <<<\"\$oM\"" "$oM"
oN=$(lt "$(mk tN 'bmc,198.19.145.1' 'bmc,198.19.145.2,own' 'bmc,*,adm,apw' 'bmc,198.19.145.?,gl')")
chk "bmc,* and a bmc glob: the glob (gl) over bmc,* for .1; .2's own line over both" "grep -qx 'B 198.19.145.1 gl pw:- 4' <<<\"\$oN\" && grep -qx 'B 198.19.145.2 own pw:- 2' <<<\"\$oN\"" "$oN"

# --- globs match in any case ---
oI=$(lt "$(mk tI 'client,node-a' 'client,Node-B' 'client,NODE-*,cu')")
chk "glob NODE-* matches node-a and Node-B (any case); names kept as written" "grep -qx 'T node-a client cu pw:- 3' <<<\"\$oI\" && grep -qx 'T Node-B client cu pw:- 3' <<<\"\$oI\"" "$oI"

# --- the default login is the second argument (the spine passes FF_SSH_USER, default the current user) ---
oL=$(lt "$(mk tL '198.19.146.1' 'backend,198.19.146.2,,pw2')" svcacct)
chk "default login svcacct: a bare line and a pw-only line take it" "grep -qx 'T 198.19.146.1 backend svcacct pw:- default' <<<\"\$oL\" && grep -qx 'T 198.19.146.2 backend svcacct pw:set 2' <<<\"\$oL\"" "$oL"
o=$(lt "$(mk tL2 '198.19.146.1')" 'bad user')
chk "a bad default login is refused (FF_SSH_USER: bad login)" "grep -q 'ERROR: FF_SSH_USER: bad login' <<<\"\$o\"" "$o"
o=$(cd $W && FF_SSH_USER='a b' FF_HOSTS=198.19.146.1 $B "$TC" --list 2>&1)
chk "the spine checks FF_SSH_USER too (FF_HOSTS path)" "grep -q 'ERROR: FF_SSH_USER: bad login' <<<\"\$o\"" "$o"
chk "spine: FF_SSH_USER defaults to the current user, not root" "grep -qF ': \"\${FF_SSH_USER:=\$(id -un)}\"' $TC && ! grep -qF 'FF_SSH_USER:=root' $TC" "$(grep -n 'FF_SSH_USER:=' $TC)"

# --- credential-less rows and refusals ---
o=$(lt "$(mk tR1 'backend,*')")
chk "a wildcard row with no login or pw is refused (it would do nothing)" "grep -q 'line 1: a wildcard row adds no targets, so it needs a login or pw' <<<\"\$o\"" "$o"
o=$(lt "$(mk tR2 'client,198.19.147.0/30' 'backend,198.19.147.2')")
chk "a target listed as client and then backend is refused, naming both lines" "grep -q 'line 2: a target here is already listed as client on line 1' <<<\"\$o\"" "$o"
o=$(lt "$(mk tR3 '*,198.19.147.1,x')")
chk "type * with a plain host is refused" "grep -q 'line 1: type \\* takes a host of \\* or a glob' <<<\"\$o\"" "$o"
o=$(lt "$(mk tR5 'backend,198.19.147.1' 'backend,10.9 .47.2')")
chk "a plain host with a space inside is refused naming its line, never the text (expand.sh's messages carry where the entry came from)" "grep -q '^ERROR: -t .*tR5 line 2: not a hostname, IP, range or CIDR$' <<<\"\$o\" && ! grep -q '47.2' <<<\"\$o\"" "$o"
o=$(lt "$(mk tR4 'backend,198.19.147.[1-2]x/,x')")
chk "a bad host pattern is refused" "grep -q 'line 1: bad host pattern' <<<\"\$o\"" "$o"

# --- moved from 18 (they run no capture): --list and the refusals ---
d=$W/tpl; mkdir -p $d
printf '%s\n' "# One host per line, a comment" "  # indented comment" "" "198.19.117.1" "198.19.117.2" "node-a" > $d/plain.lst
printf '%s\n' "host,# One host per line assigns to that host; lines without a host apply to the" "host,# whole tuple." "host," "host,  " "host,198.19.117.1" "host,198.19.117.2" "bmc,198.19.117.100,admin" > $d/sed.lst
chk "-t plain host list: comments and blanks skipped, bare lines are hosts" "[ \"\$($B $TC --list -t $d/plain.lst 2> $W/tpl1.err | tr '\n' '|')\" = '198.19.117.1|198.19.117.2|node-a|' ]" "$($B $TC --list -t $d/plain.lst 2>&1)"
chk "-t 'host,# ...' and 'host,' lines skipped, the rest read" "[ \"\$($B $TC --list -t $d/sed.lst 2> $W/tpl2.err | tr '\n' '|')\" = '198.19.117.1|198.19.117.2|198.19.117.100 (bmc)|' ]" "$($B $TC --list -t $d/sed.lst 2>&1)"
printf '%s\n' "host,,root" > $d/nohost.lst
out=$($B $TC --list -t $d/nohost.lst 2>&1); rc=$?
chk "-t 'host,,root' (a login but no host) still refused (rc 2)" "[ $rc = 2 ] && grep -q 'line 1: no host' <<<\"\$out\"" "rc=$rc $out"
mkdir -p $W/tbad
for b in "nas,198.19.113.1,root,Hunter2pw|line 1: type must be backend, client, bmc (host = backend) or *" "bmc,198.19.113.0/24,admin,Hunter2pw|line 1: a bmc line takes one IP or hostname" "host,198.19.113.1,ro ot!,Hunter2pw|line 1: bad login" "host,,root,Hunter2pw|line 1: no host" "host,198.19.113.300,root,Hunter2pw|line 1: bad octet"; do
    printf '%s\n' "${b%%|*}" > $W/tbad/t.csv
    out=$(cd $W/tbad && env PATH=$H/fake:$PATH FAKE_TC=$W/tbad $B $TC -t $W/tbad/t.csv 2>&1); rc=$?
    chk "-t refused: '${b%%,*}…' -> ${b#*|} (rc 2), the line's password not echoed" "[ $rc = 2 ] && grep -qF -- \"${b#*|}\" <<<\"\$out\" && ! grep -q Hunter2pw <<<\"\$out\"" "rc=$rc $out"
done
out=$(cd $W && $B $TC -t $W/nonexistent.csv 2>&1); rc=$?
chk "-t missing file refused (rc 2)" "[ $rc = 2 ] && grep -q \"cannot read '$W/nonexistent.csv'\" <<<\"\$out\"" "rc=$rc $out"

# --- no password in --list, stdout or stderr: warnings, refusals and the list itself ---
P='Zq7-pw!x'; f=$(mk tS "backend,198.19.148.1,u1,$P" "backend,198.19.148.*,u2,$P" "backend,198.19.14[8].*,u3,other$P" "bmc,198.19.148.100,adm,$P" "*,nomatch*,u4,$P")
out=$($B $TC --list -t $f 2>&1; lt $f; lt "$(mk tS2 "backend,198.19.148.1,bad user,$P")"; lt "$(mk tS3 "backend,198.19.148.1,bad!user,$P")")
chk "no password in --list, warnings or a refusal (control: it is in the file 5 times, the warning fired, and both bad logins, 'bad user' (a space inside is not trimmed away) and 'bad!user', were refused)" "! grep -qF -- \"\$P\" <<<\"\$out\" && [ \$(grep -cF -- \"\$P\" $f) = 5 ] && grep -q 'matches no target' <<<\"\$out\" && [ \$(grep -c '^ERROR: .*line 1: bad login' <<<\"\$out\") = 2 ]" "leaks: $(grep -cF -- "$P" <<<"$out"); refusals: $(grep -c '^ERROR: .*line 1: bad login' <<<"$out")"

# --- planted bugs: a copy of the script with one rule broken must fail the checks above ---
perl -pe 's/then tier=3;/then tier=4;/; s/R_TIER\[r\]=4$/R_TIER[r]=3/' "$TC" > $W/swap.sh
chk "planted bug (glob and range tiers swapped): tier 4's case now picks the glob" "[ \$(diff $TC $W/swap.sh | grep -c '^>') = 2 ] && ! lt $W/tB deflt $W/swap.sh | grep -qx 'T 198.19.142.1 backend l4 pw:- 5'" "$(diff $TC $W/swap.sh) $(lt $W/tB deflt $W/swap.sh)"
perl -pe 's/n=0; g=\$\{R_H\[r\],,\}/n=0; g=\$\{R_H[r]\}/' "$TC" > $W/nocase.sh
chk "planted bug (glob not case-folded): NODE-* no longer matches node-a" "[ \$(diff $TC $W/nocase.sh | grep -c '^>') = 1 ] && ! lt $W/tI deflt $W/nocase.sh | grep -qx 'T node-a client cu pw:- 3'" "$(diff $TC $W/nocase.sh) $(lt $W/tI deflt $W/nocase.sh)"
perl -pe 's/if \[\[ \$\{R_TY\[r\]\} == bmc \]\]; then/if [[ \${R_TY[r]} == bmc || \${R_TY[r]} == "*" ]]; then/' "$TC" > $W/starbmc.sh
chk "planted bug (* reaches a bmc): the bmc takes *,*'s star" "[ \$(diff $TC $W/starbmc.sh | grep -c '^>') = 1 ] && lt $W/tM deflt $W/starbmc.sh | grep -qx 'B 198.19.145.1 star pw:set 3'" "$(diff $TC $W/starbmc.sh) $(lt $W/tM deflt $W/starbmc.sh)"
finish
