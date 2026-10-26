
    NR==FNR { pre[$1]=$3" "$4" "$5; next }
    ($1 in pre) {
        split(pre[$1], p, " ")
        drx = ($3 ~ /^[0-9]+$/ && p[1] ~ /^[0-9]+$/) ? $3 - p[1] : 0
        dtx = ($4 ~ /^[0-9]+$/ && p[2] ~ /^[0-9]+$/) ? $4 - p[2] : 0
        doob = ($5 ~ /^[0-9]+$/ && p[3] ~ /^[0-9]+$/) ? $5 - p[3] : 0
        if (drx > 0 || dtx > 0 || doob > 0)
            printf "%s %s %s rx_drop:%d tx_drop:%d rx_oob:%d %s\n", $1, $2, label, drx, dtx, doob, label
    }
