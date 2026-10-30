# PRIO_SCRIPT ethtool filter on real mlx5 100G ethtool -S (fsLab canary 10-19): test_prio_real.sh <collector.sh>
source "$1"
ethtool() { tail -n +2 "${SITE_ETHTOOL:?set by the site data dir}"; }; hostname() { echo hx; }   # site data (03 says # needs: site-data)
export FF_SYSFS=/nonexistent; set -- ens800f0np0
( eval "$PRIO_SCRIPT" ) | awk '{print $2}'
