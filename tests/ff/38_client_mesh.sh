#!/opt/homebrew/bin/bash
# client mesh (10-24: "make the client mesh pings"): every client data NIC pings every backend rail IP,
# clients never ping each other. 4 clients, 5 client IPs (c4 has two NICs), 2 backends x 2 rails = 4 rail IPs:
# backend mesh 2 x 2 x 2 = 8 pings, client mesh 5 x 4 = 20
# checks: 5
# secs: 46
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" "$@"
NETS=198.19.10.0/24,198.19.11.0/24
CL="FF_CLIENTS=198.18.1.1-4 FF_CLIENT_NETS=$NETS FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0"

# the clean client mesh (28 pings, 0 failed, metadata 20/0) is checked on the mn run below: a dead client IP must look
# exactly clean, since nothing pings a client (10-26: was its own run mc). FAKE_MESHFAIL's positive control is
# golden-C (52), where it fails a backend rail IP's pings

# the dead-rail-IP run's checks moved to 52_golden_C.sh (10-26): golden-C carries FAKE_MESHFAIL=198.19.1.21

# a client whose inbound ICMP is blocked: named once as the source, no backend rail IP blamed
out=$(xrun mb FAKE_ICMP_BLOCK=198.19.10.1 $CL timeout 240 $B $C 1); rc=$?
chk "ICMP-blocked client: c1 no replies from any of the 4 rail IPs, no rail IP blamed" "grep -q 'c1 mesh_client_no_replies client IP 198.19.10.1 got no reply from any of the 4 backend rail IPs' <<<\"\$out\" && ! grep -q 'mesh_client_unreachable\|mesh_unreachable\|mesh_no_replies' <<<\"\$out\"" "$(grep -E 'Mesh|mesh_' <<<"$out")"
render mb; prc=$?
chk "dashboard: the client no-replies finding has its label" "grep -q 'Client IP gets no replies from the backends in the mesh' $W/mb.html" "rc=$prc"

# clients never ping each other (a dead client IP fails nothing) and backends never ping clients
out=$(xrun mn FAKE_MESHFAIL=198.19.10.2 $CL timeout 240 $B $C 1); rc=$?
chk "a client IP that answers nobody: 0 failed (nothing pings a client)" "grep -q 'Mesh: 28 pings, 0 failed (from clients: 0 of 20)' <<<\"\$out\"" "$(grep 'Mesh' <<<"$out")"
chk "metadata: mesh_client_pings=20, mesh_client_failures=0" "bfile mn metadata.txt | grep -qx 'mesh_client_pings=20' && bfile mn metadata.txt | grep -qx 'mesh_client_failures=0'" "$(bfile mn metadata.txt | grep mesh)"

# no clients: the backend mesh as before, no client counts
out=$(xrun m0 FF_HOSTS=198.18.0.21,198.18.0.22 FF_ITER=1 FF_UDP=0 timeout 240 $B $C 1); rc=$?
chk "no clients: 'Mesh: 8 pings, 0 failed' with no client part; metadata client pings empty" "grep -qE 'Mesh: 8 pings, 0 failed\$' <<<\"\$out\" && bfile m0 metadata.txt | grep -qx 'mesh_client_pings=0'" "$(grep 'Mesh' <<<"$out") $(bfile m0 metadata.txt | grep mesh_client)"
finish
