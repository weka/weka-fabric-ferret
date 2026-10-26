# ---------- helpers on discovery files ----------

section() {  # file name -> lines of "=== name ===" section
    awk -v s="=== $2 ===" '$0==s {on=1; next} /^=== .* ===$/ {on=0} on' "$1"
}

# rail_lookup k r: sets RNIC/RIP/RMTU/RSTATE for host k rail r from its discovery file
rail_lookup() {
    local k=$1 r=$2 f=${DISC[$1]} nic="" ip="" n
    if [[ $RAIL_MODE == nic ]]; then
        nic=${RAIL_SPEC[$r]}
        if ! section "$f" link | awk -v n="$nic" '{sub(/:$/,"",$2); sub(/@.*/,"",$2)} $2==n {f=1} END {exit !f}'; then
            RSTATE[$k,$r]="no NIC $nic"; RNIC[$k,$r]=-; RIP[$k,$r]=none; return
        fi
        ip=$(section "$f" addr | awk -v n="$nic" '$2==n {split($4,a,"/"); print a[1]; exit}')
        [[ -n $ip ]] || { RNIC[$k,$r]=$nic; RIP[$k,$r]=none; RSTATE[$k,$r]="no IPv4 on $nic"; return; }
    else
        local -a hits=()
        local c
        while read -r n a; do
            for c in ${RAIL_SPEC[$r]}; do in_cidr "$a" "$c" && { hits+=("$n $a"); break; }; done
        done < <(section "$f" addr | awk '{split($4,a,"/"); print $2, a[1]}')
        if (( ${#hits[@]} == 0 )); then
            RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="no address in ${RAIL_SPEC[$r]// /,}"; return
        fi
        nic=${hits[0]% *}; ip=${hits[0]#* }
        for n in "${hits[@]}"; do
            [[ ${n% *} == "$nic" ]] || { RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="AMBIGUOUS: ${#hits[@]} NICs in ${RAIL_SPEC[$r]// /,}"; return; }
        done
    fi
    RNIC[$k,$r]=$nic; RIP[$k,$r]=$ip
    local line; line=$(section "$f" link | awk -v n="$nic" '{x=$2; sub(/:$/,"",x); sub(/@.*/,"",x)} x==n {print; exit}')
    RMTU[$k,$r]=$(awk '{for (i = 1; i < NF; i++) if ($i == "mtu") print $(i+1)}' <<<"$line")
    if [[ $line != *LOWER_UP* ]]; then RSTATE[$k,$r]="link DOWN on $nic"
    else RSTATE[$k,$r]=ok; fi
}

rail_ok() { [[ ${RSTATE[$1,$2]} == ok ]]; }

# client_lookup k: client k's data NICs (CN, CNIC/CIP/CMTU/CSTATE by j) per FF_CLIENT_NETS or FF_CLIENT_NICS
client_lookup() {
    local k=$1 f=${DISC[$1]} n a c j=0 line
    local -A got=()
    while read -r n a; do
        [[ $n == lo || -n ${got[$n]} ]] && continue
        if [[ $CLIENT_MODE == nics ]]; then [[ " ${CLIENT_SPEC[*]} " == *" $n "* ]] || continue
        else local hit=; for c in "${CLIENT_SPEC[@]}"; do in_cidr "$a" "$c" && { hit=1; break; }; done; [[ -n $hit ]] || continue; fi
        got[$n]=1; CNIC[$k,$j]=$n; CIP[$k,$j]=$a
        line=$(section "$f" link | awk -v n="$n" '{x=$2; sub(/:$/,"",x); sub(/@.*/,"",x)} x==n {print; exit}')
        CMTU[$k,$j]=$(awk '{for (i = 1; i < NF; i++) if ($i == "mtu") print $(i+1)}' <<<"$line")
        if [[ $line != *LOWER_UP* ]]; then CSTATE[$k,$j]="link DOWN on $n"; else CSTATE[$k,$j]=ok; fi
        j=$(( j + 1 ))
    done < <(section "$f" addr | awk '{split($4,a,"/"); print $2, a[1]}')
    if [[ $CLIENT_MODE == nics ]]; then   # a named NIC with no IPv4 is a finding, not silence
        for c in "${CLIENT_SPEC[@]}"; do
            [[ -n ${got[$c]} ]] && continue
            section "$f" link | awk -v n="$c" '{sub(/:$/,"",$2); sub(/@.*/,"",$2)} $2==n {f=1} END {exit !f}' || continue
            CNIC[$k,$j]=$c; CIP[$k,$j]=none; CSTATE[$k,$j]="no IPv4 on $c"; j=$(( j + 1 ))
        done
    fi
    CN[$k]=$j
}
cl_ok() { [[ ${CSTATE[$1,$2]} == ok ]]; }

# list_subnets k...: the IPv4 subnets on hosts k (hosts, NIC, subnet); where two NICs on a host share
# a subnet, the mask can't tell them apart, so also each NIC's addresses by /24 and the FF_NICS hint
list_subnets() {
    local k
    for k in "$@"; do
        section "${DISC[$k]}" addr | awk '$2!="lo" {print $2, $4}' | while read -r n a; do
            local b; b=$(cidr_bounds "$a") && echo "$n $(int2ip ${b% *})/${a#*/}"
        done
    done | sort | uniq -c | sort -rn | sed 's/^/#   /' >&2
    local shared; shared=$(for k in "$@"; do
        section "${DISC[$k]}" addr | awk '$2!="lo" {print $2, $4}' | while read -r n a; do
            local b; b=$(cidr_bounds "$a") && echo "$k $n $(int2ip ${b% *})/${a#*/} ${a%/*}"
        done | awk '{h[$3] = h[$3] " " $2; c[$3]++; ip[$2] = $4} END {for (s in c) if (c[s] > 1) {n = split(h[s], x, " "); for (i = 1; i <= n; i++) {split(ip[x[i]], o, "."); print x[i], o[1] "." o[2] "." o[3] ".0/24"}}}'
    done)
    [[ -n $shared ]] || return 0
    log "Some hosts have several NICs in one subnet, so the subnet can't tell their rails apart. Those NICs' addresses by /24 (hosts, NIC, /24):"
    sort <<<"$shared" | uniq -c | sort -k2,2 -k1,1rn | sed 's/^/#   /' >&2
    log "Name the rails by NIC (FF_NICS=$(awk '{print $1}' <<<"$shared" | sort -u | paste -sd, -)) or by narrower subnets, ';' between rails"
}

# Swapped rails by NIC name (subnet mode): a host whose rail-A NIC is the name most hosts
# use for rail B, and the reverse, has its IPs or cables swapped.
rail_consistency() {
    [[ $RAIL_MODE == cidr ]] && (( NR >= 2 )) || return 0
    local maj k r n=0
    maj=$(for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do [[ ${RNIC[$k,$r]} != - ]] && echo "$r ${RNIC[$k,$r]}"; done; done |
        awk -v nr=$NR '#@awk ff_rail_consistency')
    if (( NR > 2 )); then   # a rail NIC that is the name most hosts use for another rail
        local -a M=($maj); local s
        for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
            [[ ${RNIC[$k,$r]} != - && ${RNIC[$k,$r]} != "${M[r]}" ]] || continue
            for s in "${RAILS[@]}"; do
                [[ $s != "$r" && ${RNIC[$k,$r]} == "${M[s]}" ]] || continue
                echo "${T_HOST[$k]} rail_nic_overlap rail $(rail_letter $r) on ${RNIC[$k,$r]}, the NIC most hosts use for rail $(rail_letter $s) (most use ${M[r]} for rail $(rail_letter $r))" >> "$COLLECT_DIR/rail_anomalies.txt"
                n=$(( n + 1 ))
            done
        done; done
        (( n )) && { log "WARNING: $n rail NICs are the NIC most hosts use for another rail:"; grep ' rail_nic_overlap ' "$COLLECT_DIR/rail_anomalies.txt" | sed 's/^/#   /' | head -n 10 >&2; }
        return 0
    fi
    local ma=${maj%% *} mb; mb=${maj#* }; mb=${mb%% *}
    [[ $ma != - && $mb != - && $ma != "$mb" ]] || return 0
    for k in "${ELIG[@]}"; do
        if [[ ${RNIC[$k,0]} == "$mb" && ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} swapped_nics rail A is on $mb and rail B on $ma, the reverse of most hosts (A=$ma, B=$mb): IPs or cables swapped" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        elif [[ ${RNIC[$k,0]} == "$mb" || ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} rail_nic_overlap rail A on ${RNIC[$k,0]}, rail B on ${RNIC[$k,1]}; most hosts use A=$ma, B=$mb" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        fi
    done
    (( n )) && { log "WARNING: $n hosts have rail NICs the other way round from most hosts:"; grep -E ' swapped_nics | rail_nic_overlap ' "$COLLECT_DIR/rail_anomalies.txt" | sed 's/^/#   /' | head -n 10 >&2; }
    return 0
}

# "mtu host" lines -> where they differ: "most at M; N on h1 h2;" (nothing when they agree)
mtu_odd() {
    awk '#@awk ff_mtu_odd'
}

# Client routes: each client asks its kernel for the route to one backend IP per rail and backend subnet;
# a route that leaves by a NIC that isn't a declared data NIC is flagged (client_routes.txt, rail_anomalies.txt)
client_routes() {
    local k j r ip
    local -A pick=() rl=()
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        rail_ok $k $r || continue
        local pfx; pfx=$(section "${DISC[$k]}" addr | awk -v ip="${RIP[$k,$r]}" '{split($4, a, "/"); if (a[1] == ip) {print a[2]; exit}}')
        local b; b=$(cidr_bounds "${RIP[$k,$r]}/${pfx:-32}") || continue
        [[ -n ${pick[$r,${b% *}]} ]] || { pick[$r,${b% *}]=${RIP[$k,$r]}; rl[${RIP[$k,$r]}]=$(rail_letter $r); }
    done; done
    local -a ips=("${pick[@]}")
    : > "$COLLECT_DIR/client_routes.txt"
    (( ${#ips[@]} )) || return 0
    for k in "${CLI[@]}"; do
        throttle
        ( rbash "${T_TARGET[$k]}" "${ips[@]}" <<<"$CROUTE_SCRIPT" > "$WORK/croute.$k" 2>&1 ) &
    done
    wait
    for k in "${CLI[@]}"; do
        local decl=" "; for (( j = 0; j < CN[$k]; j++ )); do decl+="${CNIC[$k,$j]} "; done
        awk -v h="${T_HOST[$k]}" -v decl="$decl" -v rl="$(for ip in "${!rl[@]}"; do printf '%s=%s ' "$ip" "${rl[$ip]}"; done)" '#@awk ff_client_routes' "$WORK/croute.$k"
    done | sort -V > "$WORK/croutes"
    cat "$WORK/croutes" > "$COLLECT_DIR/client_routes.txt"
    local bad; bad=$(awk '$6 == "undeclared"' "$WORK/croutes")
    local unread; unread=$(awk '$6 == "unread" {print $1}' "$WORK/croutes" | paste -sd' ' -)
    if [[ -n $unread ]]; then   # no answer is not a clean route: flag it like a bad one
        log "WARNING: client routes not read on: $unread"
        for k in $unread; do echo "$k client_route_unread no route answer from this client (ssh or ip route failed); its routes are unknown"; done >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
    if [[ -n $bad ]]; then
        awk '{r[$1] = r[$1] sprintf("%srail %s (%s) by %s", (r[$1] == "" ? "" : "; "), $3, $4, $5)} END {for (h in r) print h, "client_route_undeclared route to", r[h], "- not a declared data NIC"}' <<<"$bad" |
            sort -V >> "$COLLECT_DIR/rail_anomalies.txt"
        log "WARNING: $(awk '{print $1}' <<<"$bad" | sort -u | wc -l | tr -d ' ') clients route to a backend rail by a NIC that isn't a declared data NIC (client_routes.txt):"
        echo "$bad" | head -n 10 | column -t | sed 's/^/#   /' >&2
    else
        log "Client routes: every client reaches every backend rail by a declared data NIC ($(wc -l < "$WORK/croutes" | tr -d ' ') routes read)"
    fi
}

# Each usable rail's gateway(s) must answer a full-MTU no-fragment ping (routed rails only).
gateway_check() {
    local k r j
    : > "$COLLECT_DIR/gateways.txt"
    for k in "${ELIG[@]}"; do for r in "${RAILS[@]}"; do
        rail_ok $k $r || continue
        local -a peers=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] && rail_ok $j $r && peers+=("${RIP[$j,$r]}"); done
        (( ${#peers[@]} )) || continue
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" "${RIP[$k,$r]}" "${RNIC[$k,$r]}" $(( ${RMTU[$k,$r]:-1500} - 28 )) "${peers[@]}" <<<"$GW_SCRIPT" 2>&1)
          while read -r line; do [[ -n $line ]] && echo "${T_HOST[$k]} $(rail_letter $r) ${RIP[$k,$r]} $line"; done <<<"${out:-SSH no output}" > "$WORK/gw.$k.$r" ) &
    done; done
    wait
    cat "$WORK"/gw.* 2>&1 | grep -v 'No such file' | sort -V > "$COLLECT_DIR/gateways.txt"
    local direct ok bad
    direct=$(grep -c ' DIRECT$' "$COLLECT_DIR/gateways.txt"); ok=$(grep -c ' OK$' "$COLLECT_DIR/gateways.txt")
    bad=$(grep -v -E ' (DIRECT|OK)$' "$COLLECT_DIR/gateways.txt")
    log "Rail gateways: $ok answered a full-MTU no-fragment ping, $direct rails have no gateway (peers on-link)"
    if [[ -n $bad ]]; then
        log "WARNING: rail gateways that failed (MTU = answers only small pings):"; echo "$bad" | sed 's/^/#   /' >&2
        echo "$bad" | awk '{print $1, "gateway_" $NF, "rail", $2, $3, "gateway", $5}' >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}
