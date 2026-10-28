# write_targets_template path: hostlist.example.csv, written by ./build from this script's own usage text so the
# example and the help never drift: the row rules and example rows, then every documented FF_ setting at its
# default under its help, as comments (FF_HOSTS and FF_CLIENTS are rows in this file, not settings). A default
# is the first "(N)", "(all)" or "(none)" in the setting's help; an "=1" (or "=0") switch defaults to the other value.
write_targets_template() {
    local p=$1
    { cat <<'EOF'
# hostlist.example.csv: a target file for fabric_ferret.sh -t and thermals_capture.sh -t (the same format).
# Copy it, keep the rows you need, and chmod 600 it when a row holds a password.
#
# Row format: <type>,<host>,<login>,<pw>
#   type   backend (or host) and client: ssh targets; bmc: one BMC address, read out of band (fabric_ferret.sh
#          skips bmc rows and says how many). A bare line (no comma) is a backend with the defaults, so a plain
#          host list works as it is. Type * means backend and client, never bmc.
#   host   an IP, hostname, CIDR or range (as FF_HOSTS); a bmc takes one IP or hostname. A host of * or a glob
#          (* ? [...], any case) makes a credential row: it adds no targets and needs a login or a password.
#          A row whose host field is empty or starts with # is skipped ("host,# ..." comments a row out).
#   login  the ssh login (a bmc: its user); empty = FF_SSH_USER, by default the user running the tool.
#   pw     everything after the third comma, verbatim; empty = key (passwordless) ssh, or an empty BMC password.
# Each target takes the most specific row that gives a login or a password: the row naming the one host, then a
# CIDR or range, then a glob, then <type>,*, then *,*. That row is its credential; there is no fallback to a less
# specific one. Passwords never appear on a command line, in an environment variable or in any output.
#
# Targets
backend,10.20.1.0/28
backend,10.20.1.16-23
backend,storage-09,svc-fabric
client,10.20.2.0/26
client,gpu-node-01
client,gpu-node-02
bmc,10.20.100.11
# Credential rows: the login (and password, if any) for every target a more specific row does not cover
backend,*,svc-fabric
*,gpu-node-*,admin
#
# Settings: a line FF_<setting>=value (the whole line; the value verbatim, commas and all) sets that setting for the
# run as on the command line, for both tools (read first, exported). A setting exported in the environment wins over the file; the other tool's names are
# skipped and named in one log line; an unknown name, or one that looks like a credential, stops the run with its
# line number. Below, every fabric_ferret.sh setting at its default under its help (from --help; empty = none):
EOF
      usage | awk '
        function flush(   i, k, nn) {
            if (cur == "") return
            if (match(txt, / \(([0-9.]+|all|none)[;)]/)) def = substr(txt, RSTART + 2, RLENGTH - 3)
            if (def == "" && flag != "") def = flag
            printf "%s", buf; k = split(cur, nn, " "); for (i = 1; i <= k; i++) print "# " nn[i] "=" def; print "#"
            cur = "" }
        /^Result:/ { flush(); exit }
        /^  FF_[A-Z0-9_]+/ { flush(); line = $0; sub(/^  /, "", line)
            n = split(line, w, /[ ,=(]+/); names = ""
            for (i = 1; i <= n && w[i] ~ /^FF_[A-Z0-9_]+$/; i++) names = names (names == "" ? "" : " ") w[i]
            if (names == "FF_HOSTS" || names == "FF_CLIENTS") next
            flag = ""; if (match(line, /^FF_[A-Z0-9_]+=[01] /)) flag = (substr(line, RLENGTH - 1, 1) == "1") ? "0" : "1"
            help = line; sub(/^FF_[A-Z0-9_]+(, FF_[A-Z0-9_]+)*(=[A-Za-z0-9]+)? */, "", help); sub(/^\([0-9]+\) +/, "", help)
            cur = names; def = ""; txt = line; buf = "#   " help "\n"; next }
        cur != "" && /^            / { h = $0; sub(/^ +/, "", h); txt = txt " " h; buf = buf "#   " h "\n"; next }
        cur != "" { flush() }
        /^$/ { next }
        END { flush() }'
    } > "$p"
}
