function c(m) { return m == "-" ? "-" : sprintf("%.1f", m / 1000) }
    $1 == "@@HWMON" { print t, $2, "hwmon", $3, $4, $5, ($5 == "none" ? "-" : c($6)), c($7), c($8), ($5 == "none" ? "no_hwmon_temperature_sensors" : "-") }
    $1 == "@@IPMI" && $3 == "none" { print t, $2, "ipmi", "bmc", "-", "none", "-", "-", "-", $4 }
    $1 == "@@IPMI" && $3 != "none" { print t, $2, "ipmi", "bmc", "-", $3, $4, $6, $7, $5 }
