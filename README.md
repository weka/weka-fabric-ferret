# weka-fabric-ferret

WEKA pre-install/offline (stopped I/O) data plane investigation and performance testing tool.

`fabric_ferret.sh` tests a backend fabric host to host with iperf3, on one rail or several, and optionally from clients to the backends. It collects the NIC, switch-neighbour and host-side evidence needed to explain a slow path. `generate_dashboard.py` turns the bundle it leaves into a single interactive HTML dashboard.

- **Throughput:** every backend host pair on each rail and across rails, with round-robin pairing so that, given enough iterations, every direction on every NIC pair gets tested. One rail, two rails (A, B) or more (A, B, C…).
- **Clients (optional):** every client data NIC to every backend rail and back, in waves that keep each backend NIC to a set number of client flows at once, and optionally all clients at once. Each client's route to each rail is checked to leave by a declared data NIC.
- **Path checks:** route, ping and a full-MTU no-fragment ping on every planned path before any load.
- **Temperatures, before the fabric:** every hwmon sensor (CPU, NVMe, NIC) on every host and client around every phase, and the BMC's (inlet, exhaust) via ipmitool, flagged against each sensor's own thresholds and for a rise over the run. A hot host can cap throughput, cause resends and flap links on its own, so the dashboard shows heat first.
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
| Each tested host | key-based ssh (the tool uses `BatchMode=yes`); root, or a user with a passwordless escalator (`dzdo -n`, `pbrun`, `sesu`, `pmrun`, `doas -n`, `ksu -e` or `sudo -n`), or a `-t` password that `sudo -S` takes (`FF_SSH_USER`, `-t`); `iperf3` (not needed with `FF_SKIP_IPERF=1`); `ethtool` |
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

Instead of `FF_HOSTS` and `FF_CLIENTS`, `-t FILE` reads the targets from a file in the format thermals_capture.sh reads (`<type>,<host>,<login>,<pw>`, see that section below): `backend` (or `host`) and `client` lines, each an IP, hostname, CIDR or range; `bmc` lines are skipped and counted in one log line. Not both: `-t` with `FF_HOSTS` or `FF_CLIENTS` set stops the run. Each target takes its line's login and password, credential rows (`*` and globs) included, resolved as thermals_capture.sh does; with no login, `FF_SSH_USER`; with no password, key ssh. A password is read once, where the target's ssh session opens, through `SSH_ASKPASS` from a one-use fifo (OpenSSH 8.4 or later, or `setsid`, on the machine running the script); it never appears on a command line, in an environment variable or in a file, the run's state file included. From a jump host, the file must be there: `bash -s -- -t FILE 120`. `hostlist.example.csv` in the repository shows every kind of row with the rules in its header. A line `FF_<setting>=value` (the whole line; the value verbatim, commas and all) in the file sets that setting for the run, in either tool: a setting exported in the environment wins over the file (and a duration argument over the file's `FF_DURATION`), thermals_capture.sh's names are skipped and named in one log line, and a line with `FF_HOSTS`, `FF_CLIENTS`, an unknown name or one that looks like a credential stops the run with its line number, never printing the value. The example lists every setting at its default under its help; `./build` writes it from the tool's own `--help`, so the two cannot drift. An argument the tool doesn't take (anything but `-t FILE`, `--list` and one duration) stops the run.

What runs on a host to get root for the remote steps: during the sweep, one ssh per host runs `id -u`. A root login needs nothing more. Any other login, a password login too: the same ssh then runs `<escalator> true` for `dzdo -n`, `pbrun`, `sesu`, `pmrun`, `doas -n`, `ksu -e` and `sudo -n`, in that order (each only if installed), each under a 5 s timeout, once per host per run; the first that works runs every remote step on that host. If none works and the login has a password from `-t`, each remote step runs with `sudo -S -k`: the password is sent first on the ssh session's input stream (never on a command line), followed by a random per-run sentinel line and then the step; a small guard on the host reads up to the sentinel before the step starts, so the password line is never run as a command, whether sudo consumed it or not (a `NOPASSWD` sudoers entry, say). If none works and there is no password, the host answered ssh but can't run the steps: it is left out, listed with its reason, login and uid in the log and in the bundle's `unusable.txt`, and counted as missing. If a run is cut short, the cleanup that finishes from its state file can't stop iperf3 on a `sudo -S` host (the password is never saved); it says so for each such host.

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
| `FF_ITER` (3) | iterations: passes of the full test set (every host and client NIC through every phase), to flush out noise and outliers. Each pass gets new partners. Pairing is round robin: no pair repeats, every host pair is tested after n-1 iterations (n if n is odd), and the next n-1 (n) swap client and server. Hosts are paired with hosts that hold their rails: a host lacking a rail's NIC or address pairs within the hosts that have the rails it has, and only those rails are planned for it; n is the largest group. Two groups that share no rail are also paired across the groups (phase 3), every host pair after as many iterations as the smaller group has hosts; `all` covers that too. `all` = two such cycles, 2(n-1) or 2n: every direction on every NIC pair, once each with one or two rails. With more rails each cross-rail phase uses one rail pair, and `all` repeats the two cycles once per rail pair, so every directed path runs and the same-rail ones run once per rail pair. With clients, `all` is at least enough iterations for every client NIC to reach every backend NIC |
| `FF_STREAMS` (16) | iperf3 parallel streams, 2 or more |
| `FF_TOS` (0) | IP TOS byte for the test traffic, 0-255 (iperf3 `-S`); e.g. 106 = DSCP 26 + ECT(0) |
| `FF_CROSS_RAIL` (on) | `0` = the rails are separate fabrics by design: skip the cross-rail phase (and the cross-group phase between rail groups that share no rail) and leave it out of coverage. By default unrouted cross-rail paths count against coverage, since a missing inter-rail route can be the fault. With one rail there is no cross-rail phase (`cross_rail=single`) |
| `FF_CROSS_MAX` (all at once) | run at most N cross-rail flows at once, in balanced waves, so a shared inter-rail path doesn't cap every flow; the cross-group phase runs in the same waves, each rail pair in turn |
| `FF_SKIP_IPERF` | `1` = no iperf3 at all (see above). Path checks cover every planned path, and the counters cover one `FF_DURATION` window |
| `FF_UDP` (`1`; `0` with `FF_SKIP_IPERF=1`) | `0` = off. `1` = after the TCP phases, run the same pairs, and the same client runs (phases UC1/UC2, UF1/UF2), with UDP at no rate cap (datagrams sized to the path MTU). Loss is split into sender TX (datagrams the sending NIC never put on the wire: sent minus the kernel's tx packet count, plus the kernel's count minus the port's where the driver has one, e.g. mlx5 `tx_packets_phy`; `udp_tx.txt`), receiver socket, NIC, kernel backlog and unaccounted. Uncapped UDP has no backoff, so where what the senders actually sent into a NIC (each run's received rate × sent ÷ delivered datagrams) adds up to more than that NIC's line rate (all-at-once phases, or a faster sender than receiver), at least 1 - line/offered of the datagrams are lost to overload alone: that floor is reported as expected loss (`udp_expected.txt`), and only unaccounted loss beyond it is flagged (likely fabric). The floor knows the receiving NIC's line rate only, not spine oversubscription or a provider's per-VM cap below it |
| `FF_UDP_DURATION` (`FF_DURATION`) | seconds per UDP run |
| `FF_MESH` (`1`) | `0` = off. `1` = before load, ping every tested host's rail IPs from every other tested host (same rail and cross-rail), and every backend rail IP from every client data NIC (clients never ping each other) |

### Judging results

| Setting (default) | Meaning |
|---|---|
| `FF_LINE_GBPS` (the fastest rail's most common NIC speed) | link speed for the OK/SLOW cut-offs: `N` for every rail, or one per rail (`100,50`) when the rails differ by design. The default makes a rail that came up slow everywhere show as slow |
| `FF_OK_PCT` (75) | OK at or above this % of link speed |
| `FF_SLOW_PCT` (50) | SLOW at or above this %, CRITICAL below |
| `FF_TEMPS` (`1`) | `0` = off. `1` = read every hwmon temperature sensor (`/sys/class/hwmon`: CPU, NVMe, NIC…; no package needed) on every host and client before the run and after every phase, read only (`temps.txt`, `temps_summary.txt`). Sensors at or above their high or critical threshold, within `FF_TEMP_MARGIN` of high, or up more than `FF_TEMP_RISE` over the run are flagged; a host with no sensors is reported as having no temperature data, never as cool |
| `FF_IPMI` (`1`) | with `FF_TEMPS`, also the BMC's temperatures (inlet, exhaust…) via `ipmitool sensor`, once per iteration and at the end, where ipmitool is installed (needs root or sudo); `0` = off |
| `FF_IPMI_TIMEOUT` (60) | seconds per ipmitool read |
| `FF_TEMP_MARGIN` (5), `FF_TEMP_RISE` (10) | °C: "near" a sensor's high threshold, and a rise over the run that gets flagged |
| `FF_RETR_PCT` (0.1) | a data NIC whose TCP retransmits exceed this % of the segments it sent (bytes sent ÷ (MTU − 52)) gets `(retr)` on its Status; throughput still decides OK/SLOW/CRITICAL |
| `FF_SPINES`, `FF_SPINE_LINKS`, `FF_SPINE_GBPS` (none) | leaf-spine uplinks, all three or none: spines, links from each backend leaf to each spine, Gbps per link. The summary always totals each leaf's traffic to other leaves; with these set it judges the totals against the uplink capacity |
| `FF_CLIENT_SPINE_LINKS`, `FF_CLIENT_SPINE_GBPS` (none) | the same for client leaves, both or neither, on the `FF_SPINES` spines (one spine layer). A leaf that serves clients and backends is flagged (`shared_leaf`) and judged as a backend leaf |
| `FF_EXPECT_HOSTS` | hosts that should be tested; fewer makes coverage PARTIAL (default: every target of a plain list, or the hosts found on the rails when `FF_HOSTS` has a CIDR or range) |

### Safety and access

| Setting (default) | Meaning |
|---|---|
| `FF_BUSY_CHECK` (WEKA containers running) | command run on each host before any load: exit 0 = in production use, 1 = idle, anything else = unknown (counts as in use). Example: `'systemctl is-active --quiet myservice'`. `none` = no check |
| `FF_BUSY_OK` | `1` = run even where the busy check says in use (stop the cluster's I/O first) |
| `FF_IGNORE_LOCK` | `1` = run even if another run holds a host (both runs then get garbage) |
| `FF_SSH_USER` (the current user) | ssh user, and `-t`'s default login; a non-root login runs remote steps through the first passwordless escalator (see `-t` above for exactly what runs) |
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
| `FF_FERRET` (0) | `1` = on a terminal, a ferret roams over the log while the run goes (see below). Needs `python3` only when set |

## How a run works

Each iteration pairs the hosts and runs two phases at once across all pairs:

1. **Phase 1, same rail:** one flow per rail per pair (A→A, B→B, …), alternating direction by rail.
2. **Phase 2, cross-rail:** one flow each way per pair between two rails (A→B and B→A). With more than two rails, the rail pair changes each pairing cycle.
3. **Phase 3, cross-group:** only when two rail groups share no rail (storage hosts on A and B, GPU hosts on C, say): hosts are paired across the groups, the larger group rotating through the smaller, and one flow runs each way per rail pair (A→C, C→A, B→C, C→B), in waves of at most `FF_CROSS_MAX`. These runs are routed between the groups; each is judged at the slower rail, a NIC shared by several flows in the wave divided by their number (the `XGrp` column, the `exp:` token on its result rows). Every host pair across the groups is met after as many iterations as the smaller group has hosts; the planning log says how many partners per host the run covers. `FF_CROSS_RAIL=0` turns it off with phase 2; when every cross-group path check fails on routing while no same-rail one does, the log says the groups are not routed to each other (`cross_group=unrouted`).

A host's status is the worst of its rail columns, Cross and XGrp. `SLOW(cross)` or `CRITICAL(cross)` means only the cross-rail runs were that slow, which points at inter-rail routing or spine capacity rather than the host; `(xgrp)` says the same of the cross-group runs (the routed path between the groups), `(cross,xgrp)` of both.

With clients set, each iteration ends with a client phase: C1 clients→backends and C2 backends→clients in waves, then (with `full`) F1 and F2 with every client at once.

**The ferret (off by default):** `FF_FERRET=1` on a terminal draws a ferret roaming over the log while the run goes, in either tool (`ferret_view.py`, kept beside the tool; `python3`, no packages). Keys: `r` rolls it, `q` hides it; nothing else, the run is never touched. When the run ends the complete log is written plainly, so the scrollback reads as it would without the ferret. Without a terminal, or with `FF_FERRET` unset or `0`, the output is exactly the plain run's.

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

The bundle (`fabric_ferret_<label>_<timestamp>.tgz`) holds the run log, per-host raw output, and parsed files such as `host_list.txt`, `rails.txt`, `pairs.txt`, `pairing.txt` (only when a host has no partner sharing its rails or is tested on fewer rails), `metadata.txt`, `phase_times.txt` (each phase's start and end, UTC, to line up with switch and monitoring data), `host_rx.txt`, `fec_rates.txt`, `rail_anomalies.txt`, `link_flaps.txt`, `gateways.txt`, `mesh_failures.txt` and `sysinfo/<host>/`; with clients also `clients.txt`, `client_results.txt`, `client_routes.txt` and `client_rx.txt`.

## Dashboard

```bash
python3 generate_dashboard.py <run>.tgz [output.html] [--compare <older run>.tgz]
```

- Writes a single HTML file (default: `<run>.html` next to the bundle); open it in a browser.
- Throughput, in the run summary and on the results tab: one table, one row per data NIC, backends and clients alike (a Role column tells them apart). Columns: Same (backend to backend on its rail), Cross (rail to rail), and with clients CB_Out / CB_In (client<->backend runs the NIC sent / received) and All_Out / All_In (the all-at-once phase), then Retr and Expect. Each run is judged at its expected rate (its rail's line; Cross the slower rail's; a client run min(client line, backend rail line / runs sharing that backend NIC)); Status is the worst column, (cross) when only Cross is that bad. A NIC with no runs shows no result (or DOWN).
- Clients (a run with `FF_CLIENTS`): a Clients card lists each client data NIC's average to the backends (C->B) and from them (B->C), each run judged against min(client line, backend rail line / runs sharing that backend NIC); the worse direction is the NIC's status. It also shows the all-at-once totals, undeclared client routes, client findings and the client paths not tested. Clients are their own node type on the topology map.
- `--compare` adds what changed per NIC (host + NIC, client NICs included) since an older run: throughput each direction and counters (changes of 10% or more), plus IPs newly down or recovered. The older run may be a two-rail run without clients.
- `FF_SPINES`, `FF_SPINE_LINKS` and `FF_SPINE_GBPS` set at render time declare the uplinks for a run that didn't; `FF_CLIENT_SPINE_LINKS` and `FF_CLIENT_SPINE_GBPS` do the same for client leaves. A leaf with both client and backend NICs is judged as a backend leaf; without client uplink settings, client leaves are judged as backend leaves too.
- Prints a `PROBLEM:` line for each problem it finds in the data (PARTIAL coverage, fewer clients or client paths tested than planned, link flaps, unread counters and the like) and exits 3, so scripts can tell a clean run (exit 0) from one to read.
- Renders bundles from older fabric_sleuth runs too.

## Temperatures only: thermals_capture.sh

A standalone script that reads temperatures alone, without fabric_ferret's network tests. It uses the same hwmon and BMC reader, the same flags and the same `FF_HOSTS` syntax. It is read only and installs, loads and changes nothing. Each host reads three sources:
- `/sys/class/hwmon`, which needs no package.
- `nvidia-smi -q -d TEMPERATURE`, where installed, for NVIDIA GPUs, which hwmon doesn't show.
- `ipmitool sensor`, where installed, for the BMC. Root runs ipmitool directly; any other login runs it through the first passwordless escalator it finds (dzdo, pbrun, sesu, pmrun, doas, ksu, sudo; see `-t` below for exactly what runs).

Every sensor is typed by what it measures, whichever source read it: inlet, cpu, gpu, mem, nvme, nic or other. A BMC sensor is typed by its name; for example, `HGX_GPU_Temp` is gpu and `NVMe_SSDA_Temp` is nvme. The per-host summary shows the hottest reading of each type.

```bash
FF_HOSTS=10.1.0.0/24 ./thermals_capture.sh                    # one reading -> thermcap_<UTC>.jsonl
FF_HOSTS=10.1.0.0/24 ./thermals_capture.sh -v                 # also list the addresses that took no ssh connection
FF_HOSTS=@hosts.txt ./thermals_capture.sh -o jsonl,html,md    # any of jsonl (default), html, md
FF_HOSTS=10.1.0.10-17 ./thermals_capture.sh -d 60            # read now and 60 s later: first/min/max/last, rise flag
FF_HOSTS=10.1.0.10-17 ./thermals_capture.sh -d 600 -i 30      # a reading every 30 s for 10 min
ssh jump "FF_HOSTS=10.1.0.0/24 bash -s -- -o md" < thermals_capture.sh
./thermals_capture.sh -t targets.csv -o md                    # targets from a file: hosts and BMCs, logins
```

`-t FILE` lists targets one per line as `<type>,<host>,<login>,<pw>`; lines starting with `#` are comments. A line with no comma is a backend with the defaults, so a plain host list works as it is. A line whose host field is empty or starts with `#` is skipped. `hostlist.example.csv` in the repository shows every kind of row. A line `FF_<setting>=value` in the file sets that setting for the run (the environment wins; fabric_ferret.sh's names are skipped and named in one log line; an unknown or credential-looking name, or `FF_HOSTS`, stops the run with its line number).
- `backend` or `client` (`host` = `backend`): an ssh target. It can be an IP, a hostname, a CIDR or a range, as in `FF_HOSTS`. It is read like any other host: hwmon, plus in-band ipmitool. One target can't be listed as both.
- `bmc`: one BMC address (no CIDR or range). It is read out of band from the machine running the script, with `ipmitool -I lanplus ... sensor`.
- A host of `*` or a glob (`*`, `?`, `[...]`, matched in any case) makes a credential row: it adds no targets and needs a login or a password. Type `*` means backend and client, never bmc.
- Each target takes the most specific row that gives a login or a password: a line naming the one host, then a CIDR or range, then a glob, then `<type>,*`, then `*,*`. That row is its credential; there is no fallback to a less specific one. Two rows at the same level that differ: the first is used, with a warning naming both line numbers. A credential row that matches no target is warned.
- With no login, `FF_SSH_USER` is used (default: the current user). With no password, a host is reached by key (passwordless) ssh, and a BMC gets an empty password. The password is everything after the third comma.
- Passwords never appear on a command line, in an environment variable or in any output. ssh reads a password through an `SSH_ASKPASS` helper, and ipmitool through `-f`, each from a one-use fifo in a private temporary directory; sshpass is not used. Unattended `SSH_ASKPASS` needs OpenSSH 8.4 or later on the machine running the script, or `setsid` there.
- The script warns if a file that holds passwords can be read by group or others; `chmod 600` it.
- Targets come from `FF_HOSTS` or from `-t`, never both.
- `FF_HOSTS` hosts are reached as `FF_SSH_USER` with key (passwordless) ssh.
- What runs on a host for the BMC reading: as root, `ipmitool sensor`. For any other login without a row password, the script first finds a passwordless escalator by running `<escalator> true` for `dzdo -n`, `pbrun`, `sesu`, `pmrun`, `doas -n`, `ksu -e` and `sudo -n`, in that order (each only if installed), each under a 5 s timeout, once per host per run; the first that works runs `ipmitool sensor`. If none works, the host's BMC reading is reported as no data with that reason; its hwmon readings still count. A login with a row password skips the probe and uses `sudo -S`.
- On a `-t` host line with a non-root login and a password, ipmitool runs with `sudo -S` and that password. The password is sent over the ssh session's input stream and kept in an unexported shell variable on the host, never on a command line or in an environment.
- `FF_IPMI=0` turns off in-band ipmitool only; `bmc` lines are always read.
- `FF_FERRET=1` on a terminal draws the ferret over the log, as in fabric_ferret.sh (see The ferret above). This tool keeps no run log, so when the viewer dies the lines it had taken are not replayed; the files hold every reading.

```text
# type,host,login,pw
backend,10.1.0.0/28
backend,10.1.0.11,admin,s3cret
client,cl-*,ops
client,cl-01
bmc,10.1.100.11
bmc,*,ADMIN,bmc-pass
```

- stdout gets one aligned row per host and source: hwmon (with the nvidia-smi GPUs) and ipmi. Each row holds the sensor count, the hottest reading of each type (inlet, CPU, GPU, mem, NVMe, NIC, other) and the flags. stderr gets progress, the flagged sensors, the no-data list and the result. Every individual sensor is in the jsonl and html files.
- A target that ssh refused under fan-out (a control master that died as it opened, a reset, a kex failure) is read once more in that sample, 8 at a time, and the log says how many recovered. An ssh that died with nothing on stderr gives the reason `ssh_failed_rc255_no_message`. A run that saw any ssh failure also writes `thermcap_<UTC>.ssh_errors.log` beside its outputs: one line per failed read, `s<sample> <target> rc=<rc>: <ssh's stderr lines>` (a retried first try is marked `(retried)`), so a dead host and one refused under load can be told apart afterwards.
- The JSONL file holds every reading, one object per line. Its records are typed `run`, `host`, `sample`, `reading`, `sensor` (type and first, min, max and last value, with the sensor's flag), `nodata`, `note` (a host with no nvidia-smi reading whose GPU temperatures the BMC gave) and `result`.
- The HTML is a single self-contained file. A left nav opens the Overview (result, hottest reading per host and type, flagged sensors), then one page per type: Inlet, CPU, GPU, Mem, NVMe, NIC and Other. A type's page holds an OS (hwmon, nvidia-smi) table and a BMC / IPMI table, each shown only when that source has readings. Each table has one row per host. Its columns are grouped by device, with a device header (`ibp13s0 mlx5`) over that device's sensors (`asic`, `Module0`). A column holds the same device on every host, and a host without it shows `-`.
  - Each cell shows the temperature.
  - The crit threshold sits under the sensor name, or in each cell when hosts differ.
  - Flagged readings are shaded.
  - BMC sensor names drop the `_Temp` suffix.
  - Click a sensor to sort; a temperature column sorts hottest first.
  - Wide tables scroll inside a box that ends at the bottom of the window, so the sideways scrollbar is on screen.
  - The Not read link at the foot of the nav lists every host and source that gave no reading, with the reason, and every unreachable target, with ssh's reason. Its count is highlighted when it isn't zero.
- The Markdown file follows the same layout. It opens with a contents line, then the Overview, then a section per type holding an OS table and a BMC / IPMI table, one row per host.
  - A BMC table has one column per sensor, with its crit in the header.
  - An OS table has one column per device. Each cell lists that device's sensors, or "max T of N sensors" when there are more than four (a CPU socket's cores).
  - Flagged readings are bold.
  - Individual readings are in the jsonl.
- The flags are crit, high, near and rise, the same as with fabric_ferret's `FF_TEMPS` (`FF_TEMP_MARGIN`, `FF_TEMP_RISE`). One addition: a sensor that reports a crit threshold but no high one is given a high threshold of 95% of its crit, so it can be flagged high or near before it reaches crit. `FF_IPMI`, `FF_IPMI_TIMEOUT`, `FF_SSH_USER`, `FF_SSH_PARALLEL`, `FF_LABEL` and `FF_OUT_DIR` work as they do for fabric_ferret.
- Unreachable targets are left out of every count, the jsonl and the Markdown. That happens silently unless `-v` is given, which lists them on stderr. The HTML lists them under Not read. A target is unreachable when it took no ssh connection in any sample: timed out, refused, no route, or name not found. `RESULT ... unreachable=N` counts them. A target that connects but then fails (auth refused, say) is always reported.
- A host or source that gives no reading is listed with the reason. Reasons include unreachable, cut off, no hwmon sensors, ipmitool not installed or timed out, and sudo refused. A host with no data is never shown as cool. On stderr, hosts with the same source and reason share one counted line (`NO TEMPERATURE DATA: ipmi (ipmitool_not_installed): 112 hosts: h1 h2 … and 104 more`, up to 8 named); each host keeps its own row in the jsonl, the Markdown and the HTML's Not read.
- A host with no nvidia-smi reading whose BMC reports GPU temperatures (HGX GPU, HBM, NVLink sensors) is not a no-data host: its GPU temperatures are in the BMC rows. It is counted in a `NOTE:` line on stderr and a `note` record in the jsonl, and it leaves `nodata=`, the verdict and Not read alone.
- When either count is above zero, the line before the last says how many targets were unreachable (no ssh connection) and how many were unavailable (connected, but gave no reading at all).
- The last line is `RESULT data=COMPLETE|PARTIAL|NONE ...`. Exit codes: 0 = complete, 3 = partial, 4 = no reading at all, 2 = bad input.

## Source

`fabric_ferret.sh` and `thermals_capture.sh` are one file each on purpose: each reaches a jump host by `scp` or `bash -s <`, and needs only bash, awk and ssh there.

Those two files are built, not edited: `./build` assembles both from `src/`, and all of it is committed. Edit `src/`, run `./build`, then run the tests. `./build` also writes `hostlist.example.csv` from the built fabric_ferret.sh's `--help`, so it needs a bash 4.3 or later first on PATH. The tests check the built files, and fail while either differs from what `./build` makes of `src/`.

- `src/fabric_ferret.sh`, `src/thermals_capture.sh`: the spines: usage, defaults, settings checks and `main`, and where each module goes in.
- `src/sh/*.sh`: the rest of the bash, one module per part of a run. A module both tools use has a plain name (`ipaddr`, `expand`: target expansion); one tool's own modules start `ff_` or `tc_`.
- `src/awk/<name>.awk`: every awk program longer than one line, named for its variable or for the function that runs it (`<function>.<role>.awk` where one runs several; `TEMP_SUM_AWK` is `temp_summary.awk`, shared by both tools). `ff_` and `tc_` mark one tool's programs. Two kinds stay where they are: those inside the scripts each host runs (heredocs, sent over ssh as written), and `rx_one`'s, which has a line ending in a backslash.

In a `.sh` file `./build` reads two directives; an `.awk` file goes in as it is.

- A line `#@include <path>` becomes that file under `src/`, recursively.
- `#@awk <name>`, inside an awk program's single quotes and one to a line, becomes `src/awk/<name>.awk`: its first line takes the marker's place, each later line is indented like the marker's own line (an empty one stays empty), and every `'` becomes `'\''`, so the program stays one bash string. The marker goes right after the opening quote, or alone on the next line at the program's indent.

`./build` stops, naming the problem and leaving both targets alone, on:

- a file it cannot read, or an awk file with no text;
- an include cycle;
- a second directive on a line, or anything else that looks like one;
- a directive left in the assembly (an include not named `.sh` comes in as it is);
- a program line ending in a backslash;
- a target that is a directory, or a `./build <dir>` that isn't one;
- an assembly `bash -n` rejects, which it keeps as `<target>.rejected`.

## License

Apache License 2.0; see [LICENSE](LICENSE).
