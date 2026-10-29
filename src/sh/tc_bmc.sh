# ---------- a BMC read out of band, from here (both tools) ----------

tmo_s() { local s=$1; shift; if [[ -n $TO ]]; then "$TO" "$s" "$@"; else "$@"; fi; }   # under timeout s, where timeout exists (TO)

# rbmc j: the BMC's sensors out of band from here (ipmitool lanplus); a password through -f from a one-use fifo, an
# empty one as -E with IPMI_PASSWORD empty (no secret in it)
rbmc() {
    local j=$1 rc; local -a a=(-I lanplus -H "${BMCS[$j]}" -U "${B_LOGIN[$j]}")
    if [[ -n ${B_PW[$j]} ]]; then pwfifo "b$j.$BASHPID" "${B_PW[$j]}" || return 1; a+=(-f "$PWFIFO"); else a+=(-E); export IPMI_PASSWORD=; fi
    tmo_s "$FF_IPMI_TIMEOUT" ipmitool "${a[@]}" sensor <<<""; rc=$?
    [[ -n ${B_PW[$j]} ]] && { exec 4>&-; rm -f "$PWFIFO"; }; return $rc
}

# ipmitool sensor output -> temps rows for one BMC (as the reader's @@IPMI lines), or one none row with the reason
BMC_AWK='#@awk tc_bmc'
