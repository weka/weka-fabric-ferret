# weka-fabric-ferret

WEKA pre-install/offline (stopped I/O) data plane investigation and performance testing tool.

`fabric_ferret.sh` tests a dual-rail backend fabric host to host with iperf3 and collects the NIC, switch-neighbour and host-side evidence needed to explain a slow path. `generate_dashboard.py` turns the bundle it leaves into a single interactive HTML dashboard.

- **Throughput:** every host pair on rail A, on rail B, and across rails (A↔B), with round-robin pairing so that, given enough iterations, every direction on every NIC pair gets tested.
- **Path checks:** route, ping and a full-MTU no-fragment ping on every planned path before any load.
- **Fabric evidence:** LLDP neighbours (which leaf each NIC lands on), link speed, optics, FEC rate, priority and pause counters, NIC and kernel drops, link flaps, rail gateways, and NICs that are swapped between rails.
- **Host side:** system info per host (OS, CPU, PCIe, NIC rings, IRQs and QoS, routes, sysctls, the kernel log over the run) and a receive-side table (drops, softnet, iperf3 CPU) with flags.
- **Optional:** a UDP pass with loss split by where it happened, a ping mesh, leaf-spine uplink totals, and a run that skips the bandwidth tests and still does every other check.

## Before you run it

- **It loads the fabric.** The default run sends line-rate iperf3 traffic between every host pair. Run it before WEKA is installed or with the cluster's I/O stopped.
- **WEKA running?** A busy check runs on every host before any load. By default a host counts as busy when a WEKA container is Running (`weka local ps`) or the check fails, and the tool stops if any host is busy. Use `FF_SKIP_IPERF=1` there: it runs every check except the bandwidth tests and watches the counters over the cluster's own traffic.
- **One run at a time.** A run takes a lock on each host. A second run against the same hosts stops instead of killing the first run's iperf3 servers.

## Requirements

| Where | Needs |
|---|---|
| The machine you run from (a jump host is fine) | bash 4.3+, ssh, timeout, column, sort, awk, tar |
| Where you render the dashboard | python3 (standard library only) |
| Viewing the dashboard | a browser with internet access: the page loads Bootstrap, DataTables, Plotly, jQuery and vis-network from public CDNs, each pinned to a version and checked with subresource integrity |
| Each tested host | key-based ssh (the tool uses `BatchMode=yes`); root, or a user with passwordless `sudo -n` (`FF_SSH_USER`); `iperf3` (not needed with `FF_SKIP_IPERF=1`); `ethtool` |
| Each tested host, optional | `lldpcli` (switch neighbours), `mlxconfig` (NIC firmware settings), `journalctl` (kernel log), `ibstat` |

A tool that's missing on a host is reported as not installed in its section, never as a clean reading. A missing `iperf3` stops the run (unless `FF_SKIP_IPERF=1`) and names the hosts.

## Quick start

```bash
# See what FF_HOSTS expands to (no ssh)
FF_HOSTS=10.1.0.10-40 ./fabric_ferret.sh --list

# Don't know the rail subnets yet? Leave them out: the tool sweeps the hosts, prints the subnets it found, and stops
FF_HOSTS=10.1.0.10-40 ./fabric_ferret.sh

# A test run: 120 s per iperf3 run
FF_HOSTS=10.1.0.10-40 FF_RAIL_A=10.20.1.0/24 FF_RAIL_B=10.20.2.0/24 ./fabric_ferret.sh 120

# Rails named by NIC instead of subnet, every direction on every NIC pair
FF_HOSTS=@hosts.txt FF_NICS=enp5s0np0,enp196s0np0 FF_ITER=all ./fabric_ferret.sh

# From a jump host: settings ride in the remote command, nothing to copy first
ssh jump 'FF_HOSTS=10.1.0.0/24 FF_RAILS=10.20.1.0/24,10.20.2.0/24 bash -s -- 120' < fabric_ferret.sh

# A cluster whose I/O can't stop: everything but the bandwidth tests
FF_HOSTS=@hosts.txt FF_RAILS=10.20.1.0/24,10.20.2.0/24 FF_SKIP_IPERF=1 FF_ITER=all FF_DURATION=120 ./fabric_ferret.sh

# Render the dashboard (writes <run>.html next to the bundle)
python3 generate_dashboard.py fabric_ferret_<label>_<timestamp>.tgz
```

A run ends by printing the `scp` and render command for the bundle it left behind.

## Settings

All settings are environment variables. A setting the tool doesn't know (a typo such as `FF_STREAM`) stops the run and suggests the closest name. The prefix used to be `FS_` (the tool's old name, fabric_sleuth); an `FS_` setting stops the run and names its `FF_` replacement.

### Hosts and rails (required)

| Setting | Meaning |
|---|---|
| `FF_HOSTS` | ssh targets, comma or space separated, any mix of: `10.1.0.5,node07` (IPs or hostnames), `10.1.0.0/24` (CIDR), `10.1.0.10-10.1.1.20` (full range), `10.1.0.10-40` (last-octet range), `10.1.0-1.10-40` (per-octet ranges, nmap style), `@hosts.txt` (a file; entries split on lines, commas or spaces; `#` comments) |
| `FF_RAIL_A`, `FF_RAIL_B` | each rail's data subnets, comma separated: `FF_RAIL_A=10.20.1.0/24,10.20.3.0/24` |
| or `FF_RAILS` | one subnet per rail, A first: `10.20.1.0/24,10.20.2.0/24` |
| or `FF_NICS` | the data NIC per rail, A first: `enp5s0np0,enp196s0np0` (wins over the subnet forms) |

With no rail setting, the tool sweeps the hosts, prints the IPv4 subnets it found, and stops.

### Test shape

| Setting (default) | Meaning |
|---|---|
| `FF_DURATION` (120) | iperf3 seconds per run; the first argument also sets it |
| `FF_ITER` (5) | iterations. Pairing is round robin: no pair repeats, every host pair is tested after n-1 iterations (n if n is odd), and the next n-1 swap client and server. `all` = 2(n-1): every direction on every NIC pair |
| `FF_STREAMS` (16) | iperf3 parallel streams, 2 or more |
| `FF_TOS` (0) | IP TOS byte for the test traffic, 0-255 (iperf3 `-S`); e.g. 106 = DSCP 26 + ECT(0) |
| `FF_CROSS_RAIL` (on) | `0` = the rails are separate fabrics by design: skip the A↔B phase and leave it out of coverage. By default unrouted A↔B paths count against coverage, since a missing inter-rail route can be the fault |
| `FF_CROSS_MAX` (all at once) | run at most N cross-rail flows at once, in balanced waves, so a shared inter-rail path doesn't cap every flow |
| `FF_SKIP_IPERF` | `1` = no iperf3 at all (see above). Path checks cover every planned path, and the counters cover one `FF_DURATION` window |
| `FF_UDP` | `1` = after the TCP phases, run the same pairs with UDP at no rate cap (datagrams sized to the path MTU). Loss is split into receiver socket, NIC, kernel backlog and unaccounted (likely fabric) |
| `FF_UDP_DURATION` (`FF_DURATION`) | seconds per UDP run |
| `FF_MESH` | `1` = before load, ping every tested host's rail IPs from every other tested host (same rail and cross-rail) |

### Judging results

| Setting (default) | Meaning |
|---|---|
| `FF_LINE_GBPS` (the faster rail's most common NIC speed) | link speed for the OK/SLOW cut-offs: `N` for both rails, or `A,B` when the rails differ by design (e.g. `100,50`). The default makes a rail that came up slow everywhere show as slow |
| `FF_OK_PCT` (75) | OK at or above this % of link speed |
| `FF_SLOW_PCT` (50) | SLOW at or above this %, CRITICAL below |
| `FF_SPINES`, `FF_SPINE_LINKS`, `FF_SPINE_GBPS` (none) | leaf-spine uplinks, all three or none: spines, links from each leaf to each spine, Gbps per link. The summary always totals each leaf's traffic to other leaves; with these set it judges the totals against the uplink capacity |
| `FF_EXPECT_HOSTS` | hosts that should be tested; fewer makes coverage PARTIAL (default: every target of a plain list, or the hosts found on the rails when `FF_HOSTS` has a CIDR or range) |

### Safety and access

| Setting (default) | Meaning |
|---|---|
| `FF_BUSY_CHECK` (WEKA containers running) | command run on each host before any load: exit 0 = in production use, 1 = idle, anything else = unknown (counts as in use). Example: `'systemctl is-active --quiet myservice'`. `none` = no check |
| `FF_BUSY_OK` | `1` = run even where the busy check says in use (stop the cluster's I/O first) |
| `FF_IGNORE_LOCK` | `1` = run even if another run holds a host (both runs then get garbage) |
| `FF_SSH_USER` (root) | ssh user; a non-root user runs remote steps with `sudo -n` |
| `FF_SSH_PARALLEL` (64) | ssh sessions at once for sweep and collection |
| `FF_SSH_RETRY_PARALLEL` (8) | retry targets that refused ssh under load this many at a time |
| `FF_MAX_TARGETS` (4096) | refuse to expand `FF_HOSTS` beyond this |
| `FF_SYSINFO_TIMEOUT` (300) | seconds per host for the system info capture; a host that runs out keeps what it sent and is flagged |
| `FF_PORT` (5201) | iperf3 port |

### Output

| Setting (default) | Meaning |
|---|---|
| `FF_LABEL` (first tested hostname) | name in the report and the bundle file name |
| `FF_OUT_DIR` (.) | where the `.tgz` bundle goes |

## How a run works

Each iteration pairs the hosts and runs two phases at once across all pairs:

1. **Phase 1, same rail:** A→A and B→B.
2. **Phase 2, cross-rail:** one flow each way per pair, A→B and B→A.

A host's status is the worst of its Rail A, Rail B and Cross results. `SLOW(cross)` or `CRITICAL(cross)` means only the cross-rail runs were that slow, which points at inter-rail routing or spine capacity rather than the host.

## Results

The last line of every run is the result:

```
RESULT coverage=COMPLETE|PARTIAL|NONE hosts=t/e paths=r/p ...
```

| Exit | Meaning |
|---|---|
| 0 | COMPLETE: every expected host and planned path has a result |
| 3 | PARTIAL: some hosts or paths have no result (the summary lists them) |
| 4 | NONE: no throughput result at all |
| 2 | stopped early (bad input, busy hosts, missing tools); the reason is on the RESULT line |

COMPLETE describes coverage, not health. A COMPLETE run can still have slow or critical hosts; read the summary and the dashboard.

The bundle (`fabric_ferret_<label>_<timestamp>.tgz`) holds the run log, per-host raw output, and parsed files such as `host_list.txt`, `rails.txt`, `pairs.txt`, `metadata.txt`, `host_rx.txt`, `fec_rates.txt`, `rail_anomalies.txt`, `link_flaps.txt`, `gateways.txt`, `mesh_failures.txt` and `sysinfo/<host>/`.

## Dashboard

```bash
python3 generate_dashboard.py <run>.tgz [output.html] [--compare <older run>.tgz]
```

- Writes a single HTML file (default: `<run>.html` next to the bundle); open it in a browser.
- `--compare` adds what changed per rail NIC since an older run: throughput each direction and counters (changes of 10% or more), plus IPs newly down or recovered.
- `FF_SPINES`, `FF_SPINE_LINKS` and `FF_SPINE_GBPS` set at render time declare the uplinks for a run that didn't.
- Prints a `PROBLEM:` line for each problem it finds in the data (PARTIAL coverage, link flaps, unread counters and the like) and exits 3, so scripts can tell a clean run (exit 0) from one to read.
- Renders bundles from older fabric_sleuth runs too.

## License

Apache License 2.0; see [LICENSE](LICENSE).
