source "${FF_C:-$(cd "$(dirname "$0")/.." && pwd)/fabric_ferret.sh}"
( set -- "$@"; eval "$IPERF_SCRIPT" )
