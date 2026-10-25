# weka-fabric-ferret

WEKA pre-install/offline (stopped I/O) data plane investigation and performance testing tool.

`fabric_ferret.sh` tests a backend fabric host to host with iperf3, on one rail or several, and optionally from clients to the backends. It collects the NIC, switch-neighbour and host-side evidence needed to explain a slow path. `generate_dashboard.py` turns the bundle it leaves into a single interactive HTML dashboard.

- **Throughput:** every backend host pair on each rail and across rails, with round-robin pairing so that, given enough iterations, every direction on every NIC pair gets tested. One rail, two rails (A, B) or more (A, B, C…).
- **Clients (optional):** every client data NIC to every backend rail and back, in waves that keep each backend NIC to a set number of client flows at once, and optionally all clients at once. Each client's route to each rail is checked to leave by a declared data NIC.
- **Path checks:** route, ping and a full-MTU no-fragment ping on every planned path before any load.
- **Fabric evidence:** LLDP neighbours (which leaf each NIC lands on), link speed, optics, FEC rate, priority and pause counters, NIC and kernel drops, link flaps, rail gateways, and NICs that are swapped between rails.
- **Host side:** system info per host (OS, CPU, PCIe, NIC rings, IRQs and QoS, routes, sysctls, the kernel log over the run) and a receive-side table (drops, softnet, iperf3 CPU) with flags.
- **UDP pass:** after the TCP phases, the same backend and client runs over UDP at no rate cap, with loss split by where it happened (`FF_UDP=0` turns it off).
- **Ping mesh:** before load, every backend rail IP from every other backend's and from every client data NIC (`FF_MESH=0` turns it off).
- **Optional:** leaf-spine uplink totals, and a run that skips the bandwidth tests and still does every other check.

## Before you run it

- **It loads the fabric.** The default run sends line-rate iperf3 traffic between every host pair (and between clients and backends, when clients are set). Run it before WEKA is installed or with the cluster's I/O stopped.
- **WEKA running?** A busy check runs on every host and client before any load. By default a host counts as busy when a WEKA container is Running (`weka local ps`) or the check fails, and the tool stops if any host is busy. Use `FF_SKIP_IPERF=1` there: it runs every check except the bandwidth tests and watches the counters over the cluster's own traffic.
- **One run at a time.** A run takes a lock on each host and client. A second run against the same hosts stops instead of killing the first run's iperf3 servers.

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

# A test run on two rails: 120 s per iperf3 run (';' between rails, so quote it)
FF_HOSTS=10.1.0.10-40 FF_RAILS='10.20.1.0/24;10.20.2.0/24' ./fabric_ferret.sh 120

# One rail (backends with a single data NIC)
FF_HOSTS=10.1.0.10-40 FF_RAILS=10.20.1.0/24 ./fabric_ferret.sh 120

# A rail with several subnets (routed /31s or one subnet per leaf): ',' within a rail
FF_HOSTS=@hosts.txt FF_RAILS='10.20.1.0/24,10.20.3.0/24;10.20.2.0/24,10.20.4.0/24' ./fabric_ferret.sh

# Rails named by NIC instead of subnet, every direction on every NIC pair
FF_HOSTS=@hosts.txt FF_NICS=enp5s0np0,enp196s0np0 FF_ITER=all ./fabric_ferret.sh

# Clients too: every client data NIC to every backend rail and back
FF_HOSTS=@hosts.txt FF_RAILS='10.20.1.0/24;10.20.2.0/24' FF_CLIENTS=@clients.txt FF_CLIENT_NETS=10.30.0.0/23 ./fabric_ferret.sh

# From a jump host: settings ride in the remote command, nothing to copy first
ssh jump "FF_HOSTS=10.1.0.0/24 FF_RAILS='10.20.1.0/24;10.20.2.0/24' bash -s -- 120" < fabric_ferret.sh

# A cluster whose I/O can't stop: everything but the bandwidth tests (clients get their path checks)
FF_HOSTS=@hosts.txt FF_RAILS='10.20.1.0/24;10.20.2.0/24' FF_SKIP_IPERF=1 FF_ITER=all FF_DURATION=120 ./fabric_ferret.sh

# Render the dashboard (writes <run>.html next to the bundle)
python3 generate_dashboard.py fabric_ferret_<label>_<timestamp>.tgz
```

A run ends by printing the `scp` and render command for the bundle it left behind.

## Settings

All settings are environment variables. A setting the tool doesn't know (a typo such as `FF_STREAM`) stops the run and suggests the closest name. The prefix used to be `FS_` (the tool's old name, fabric_sleuth); an `FS_` setting stops the run and names its `FF_` replacement. `FF_RAIL_A` and `FF_RAIL_B` are gone; setting either stops the run and shows the `FF_RAILS` form.

### Hosts and rails (required)

| Setting | Meaning |
|---|---|
| `FF_HOSTS` | ssh targets, comma or space separated, any mix of: `10.1.0.5,node07` (IPs or hostnames), `10.1.0.0/24` (CIDR), `10.1.0.10-10.1.1.20` (full range), `10.1.0.10-40` (last-octet range), `10.1.0-1.10-40` (per-octet ranges, nmap style), `@hosts.txt` (a file; entries split on lines, commas or spaces; `#` comments) |
| `FF_RAILS` | each rail's data subnets: `;` between rails (A first), `,` between one rail's subnets. `'10.20.1.0/24;10.20.2.0/24'` is two rails; `10.20.1.0/24` is one; any number works, labelled A, B, C… Quote it: `;` ends a shell command |
| or `FF_NICS` | the data NIC per rail, A first, any number: `enp5s0np0,enp196s0np0` (wins over `FF_RAILS`) |

With no rail setting, the tool sweeps the hosts, prints the IPv4 subnets it found, and stops. Where two NICs on a host share one subnet (both rails in one /16, say), it also lists their addresses by /24 and suggests `FF_NICS`.

`FF_RAILS=a,b` (a comma, no `;`) is one rail with two subnets. On hosts with a NIC in each, that rail is ambiguous, and the run stops and shows the `;` form.

### Clients (optional)

| Setting (default) | Meaning |
|---|---|
| `FF_CLIENTS` | client ssh targets, same forms as `FF_HOSTS`. A host can't be both a backend and a client |
| `FF_CLIENT_NETS` | the clients' data subnets, comma separated: every client NIC with an address in them is a data NIC (a client may have one or several) |
| or `FF_CLIENT_NICS` | the clients' data NIC names, comma separated |
| `FF_CLIENT_RATIO` (1) | `N`: waves, at most N client NICs on one backend NIC at once. `full`: every client NIC at once, clients→backends then backends→clients. `N:full`: the waves, then all at once |
| `FF_CLIENT_GBPS` (each client NIC's speed) | client line rate; a bond counts its total speed |
| `FF_EXPECT_CLIENTS` | clients that should be tested; fewer makes coverage PARTIAL |

With `FF_CLIENTS` but neither `FF_CLIENT_NETS` nor `FF_CLIENT_NICS`, the tool lists the subnets on the clients and stops.

Clients follow `FF_ITER` as the backends do: each iteration ends with its client phase, and each iteration moves every client data NIC on to the next backend. In an iteration each client data NIC runs to one backend on every rail, both ways, and the backends are spread so every backend NIC gets its share. After as many iterations as a rail has backends, every client NIC has run to every backend NIC (`FF_ITER=all` covers that too; with `full`, the rail rotates first, so it takes rails x backends iterations). A client run is judged against min(client line rate, backend rail line rate ÷ flows sharing that backend NIC). Each client also asks its kernel for its route to every backend rail; a route that leaves by a NIC that isn't a declared data NIC (management, say) is flagged in `client_routes.txt`.

Clients get the same reports as backends: drop, host receive, priority/ECN and FEC counters (read around every client phase as well), system info and kernel log (`sysinfo/<client>/`), and a host-side receive table of their own (`client_rx.txt`, one column per client data NIC). With `FF_CLIENT_GBPS` set, client NICs at another speed are listed. Both throughput tables carry `Retr`, the TCP retransmits over the runs a host or client NIC sent.

### Test shape

| Setting (default) | Meaning |
|---|---|
| `FF_DURATION` (120) | iperf3 seconds per run; the first argument also sets it |
| `FF_ITER` (3) | iterations: passes of the full test set (every host and client NIC through every phase), to flush out noise and outliers. Each pass gets new partners. Pairing is round robin: no pair repeats, every host pair is tested after n-1 iterations (n if n is odd), and the next n-1 (n) swap client and server. `all` = two such cycles, 2(n-1) or 2n: every direction on every NIC pair, once each with one or two rails. With more rails each cross-rail phase uses one rail pair, and `all` repeats the two cycles once per rail pair, so every directed path runs and the same-rail ones run once per rail pair. With clients, `all` is at least enough iterations for every client NIC to reach every backend NIC |
| `FF_STREAMS` (16) | iperf3 parallel streams, 2 or more |
| `FF_TOS` (0) | IP TOS byte for the test traffic, 0-255 (iperf3 `-S`); e.g. 106 = DSCP 26 + ECT(0) |
| `FF_CROSS_RAIL` (on) | `0` = the rails are separate fabrics by design: skip the cross-rail phase and leave it out of coverage. By default unrouted cross-rail paths count against coverage, since a missing inter-rail route can be the fault. With one rail there is no cross-rail phase (`cross_rail=single`) |
| `FF_CROSS_MAX` (all at once) | run at most N cross-rail flows at once, in balanced waves, so a shared inter-rail path doesn't cap every flow |
| `FF_SKIP_IPERF` | `1` = no iperf3 at all (see above). Path checks cover every planned path, and the counters cover one `FF_DURATION` window |
| `FF_UDP` (`1`; `0` with `FF_SKIP_IPERF=1`) | `0` = off. `1` = after the TCP phases, run the same pairs, and the same client runs (phases UC1/UC2, UF1/UF2), with UDP at no rate cap (datagrams sized to the path MTU). Loss is split into receiver socket, NIC, kernel backlog and unaccounted (likely fabric) |
| `FF_UDP_DURATION` (`FF_DURATION`) | seconds per UDP run |
| `FF_MESH` (`1`) | `0` = off. `1` = before load, ping every tested host's rail IPs from every other tested host (same rail and cross-rail), and every backend rail IP from every client data NIC (clients never ping each other) |

### Judging results

| Setting (default) | Meaning |
|---|---|
| `FF_LINE_GBPS` (the fastest rail's most common NIC speed) | link speed for the OK/SLOW cut-offs: `N` for every rail, or one per rail (`100,50`) when the rails differ by design. The default makes a rail that came up slow everywhere show as slow |
| `FF_OK_PCT` (75) | OK at or above this % of link speed |
| `FF_SLOW_PCT` (50) | SLOW at or above this %, CRITICAL below |
| `FF_SPINES`, `FF_SPINE_LINKS`, `FF_SPINE_GBPS` (none) | leaf-spine uplinks, all three or none: spines, links from each backend leaf to each spine, Gbps per link. The summary always totals each leaf's traffic to other leaves; with these set it judges the totals against the uplink capacity |
| `FF_CLIENT_SPINE_LINKS`, `FF_CLIENT_SPINE_GBPS` (none) | the same for client leaves, both or neither, on the `FF_SPINES` spines (one spine layer). A leaf that serves clients and backends is flagged (`shared_leaf`) and judged as a backend leaf |
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

1. **Phase 1, same rail:** one flow per rail per pair (A→A, B→B, …), alternating direction by rail.
2. **Phase 2, cross-rail:** one flow each way per pair between two rails (A→B and B→A). With more than two rails, the rail pair changes each pairing cycle.

A host's status is the worst of its rail columns and Cross. `SLOW(cross)` or `CRITICAL(cross)` means only the cross-rail runs were that slow, which points at inter-rail routing or spine capacity rather than the host.

With clients set, each iteration ends with a client phase: C1 clients→backends and C2 backends→clients in waves, then (with `full`) F1 and F2 with every client at once.

## Results

The last line of every run is the result:

```
RESULT coverage=COMPLETE|PARTIAL|NONE hosts=t/e paths=r/p ... [clients=t/e client_paths=r/p]
```

| Exit | Meaning |
|---|---|
| 0 | COMPLETE: every expected host and client, and every planned path, has a result |
| 3 | PARTIAL: some hosts or paths have no result (the summary lists them) |
| 4 | NONE: no throughput result at all |
| 2 | stopped early (bad input, busy hosts, missing tools); the reason is on the RESULT line |

COMPLETE describes coverage, not health. A COMPLETE run can still have slow or critical hosts; read the summary and the dashboard.

The bundle (`fabric_ferret_<label>_<timestamp>.tgz`) holds the run log, per-host raw output, and parsed files such as `host_list.txt`, `rails.txt`, `pairs.txt`, `metadata.txt`, `phase_times.txt` (each phase's start and end, UTC, to line up with switch and monitoring data), `host_rx.txt`, `fec_rates.txt`, `rail_anomalies.txt`, `link_flaps.txt`, `gateways.txt`, `mesh_failures.txt` and `sysinfo/<host>/`; with clients also `clients.txt`, `client_results.txt`, `client_routes.txt` and `client_rx.txt`.

## Dashboard

```bash
python3 generate_dashboard.py <run>.tgz [output.html] [--compare <older run>.tgz]
```

- Writes a single HTML file (default: `<run>.html` next to the bundle); open it in a browser.
- Any number of rails: the per-host table has one column group per rail (A, B, C…) plus Cross with two or more rails; each IP is judged at its rail's line rate.
- Clients (a run with `FF_CLIENTS`): a Clients card lists each client data NIC's average to the backends (C->B) and from them (B->C), each run judged against min(client line, backend rail line / runs sharing that backend NIC); the worse direction is the NIC's status. It also shows the all-at-once totals, undeclared client routes, client findings and the client paths not tested. Clients are their own node type on the topology map.
- `--compare` adds what changed per NIC (host + NIC, client NICs included) since an older run: throughput each direction and counters (changes of 10% or more), plus IPs newly down or recovered. The older run may be a two-rail run without clients.
- `FF_SPINES`, `FF_SPINE_LINKS` and `FF_SPINE_GBPS` set at render time declare the uplinks for a run that didn't; `FF_CLIENT_SPINE_LINKS` and `FF_CLIENT_SPINE_GBPS` do the same for client leaves. A leaf with both client and backend NICs is judged as a backend leaf; without client uplink settings, client leaves are judged as backend leaves too.
- Prints a `PROBLEM:` line for each problem it finds in the data (PARTIAL coverage, fewer clients or client paths tested than planned, link flaps, unread counters and the like) and exits 3, so scripts can tell a clean run (exit 0) from one to read.
- Renders bundles from older fabric_sleuth runs too.

## License

Apache License 2.0; see [LICENSE](LICENSE).
