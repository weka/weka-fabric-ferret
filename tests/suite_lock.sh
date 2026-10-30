# One test suite at a time on this machine (10-26 19:42): every runner of every checkout sources this and takes ONE
# machine-wide lock, $HOME/.cache/fabric_ferret/suite.lock (FFT_SUITE_LOCK overrides), never a path under a tree.
# suite_lock <name> takes the lock or exits 2 naming the holder; the lock goes on EXIT.
# The holder file is "pid start name"; a lock whose pid is gone is stale and taken over, with a note.
SUITE_LOCK=${FFT_SUITE_LOCK:-$HOME/.cache/fabric_ferret/suite.lock}
mkdir -p "$(dirname "$SUITE_LOCK")" || { echo "suite lock: cannot make $(dirname "$SUITE_LOCK")" >&2; exit 2; }
suite_lock() {
    local m who pid k i got=0
    for i in $(seq 50); do
        m=$(mkdir "$SUITE_LOCK" 2>&1) && { got=1; break; }
        who=$(cat "$SUITE_LOCK/holder" 2>&1); pid=${who%% *}
        if [[ ! $pid =~ ^[0-9]+$ ]]; then sleep 0.1; continue; fi   # mkdir done, holder not written yet
        if k=$(kill -0 "$pid" 2>&1); then echo "suite lock held by: $who ($SUITE_LOCK); one suite at a time" >&2; exit 2; fi
        echo "# suite lock: taking over a stale lock ($who: pid gone)" >&2
        rm -rf "${SUITE_LOCK:?}"
    done
    (( got )) || { echo "suite lock: cannot take $SUITE_LOCK (holder never written: $(cat "$SUITE_LOCK/holder" 2>&1)); remove it if no suite runs" >&2; exit 2; }
    echo "$$ $(date +%Y-%m-%dT%H:%M:%S) $1" > "$SUITE_LOCK/holder"
    trap suite_unlock EXIT
}
suite_unlock() { local who; who=$(cat "$SUITE_LOCK/holder" 2>&1); [[ ${who%% *} == "$$" ]] && rm -rf "${SUITE_LOCK:?}"; }
