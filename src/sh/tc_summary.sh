# ---------- the temperature summary, one for both tools ----------

# temps_summary.txt, one row per sensor over the samples: "Host Source Type Chip Dev Sensor First_C Max_C Last_C
# High_C Crit_C Flag" (TYPE_AWK adds Min_C). Flag, worst first: crit, high (or the BMC's status), near (within
# FF_TEMP_MARGIN of high), +rise (over FF_TEMP_RISE); nodata:<why> when a host/source gave nothing
TEMP_SUM_AWK='
#@awk temp_summary'

# Type by what a sensor measures: nvidia-smi and amdgpu rows gpu; a BMC sensor by its name (the awk lists the
# words); hwmon drivetemp nvme, jc42/spd5118 mem. Appends Min_C. A gpu nodata row on a host whose BMC gave
# GPU rows becomes note:, not a no-data
TYPE_AWK='
#@awk tc_type'

# stdout, one row per host: gpu cells nvidia-smi's, else the BMC's; other types the BMC's, hwmon's where the BMC lacks one;
# Source = sources used; cell = hottest, mean of latest; Sensors = all; Flags = every flagged sensor, "/source" on
# one behind no shown cell
SRC_AWK='#@awk tc_src'

# summarize_temps temps.txt adjusted summary: high = 95% of crit where high is missing (to <adjusted>, the caller's
# to keep or move over temps.txt), the summary, its nodata rows sorted after the data rows (awk hash order differs),
# then the types and Min_C
summarize_temps() {
    local in=$1 hi=$2 out=$3
    awk '#@awk tc_main.crit_high' "$in" > "$hi"
    awk -v margin="$FF_TEMP_MARGIN" -v rise="$FF_TEMP_RISE" "$TEMP_SUM_AWK" "$hi" > "$out.raw"
    { awk '$12 !~ /^nodata/' "$out.raw"; awk '$12 ~ /^nodata/' "$out.raw" | sort -k1,1 -k2,2; } > "$out.sorted"
    awk "$TYPE_AWK" "$hi" "$out.sorted" > "$out"
    rm -f "$out.raw" "$out.sorted"
}
