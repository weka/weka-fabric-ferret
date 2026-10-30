# ---------- background jobs (both tools) ----------

throttle() { while (( $(jobs -rp | wc -l) >= FF_SSH_PARALLEL )); do wait -n; done; }
wait_all() { while [[ -n $(jobs -rp) ]]; do wait; done; }   # a trapped Ctrl-C ends a bare wait early
