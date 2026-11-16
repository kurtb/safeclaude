#!/usr/bin/env bash
# macOS driver (SKETCH / not implemented): Lima (vz) + vmnet + pf.
# This is "the other option" for when you build on a Mac — Incus can't run
# natively on macOS.
#
# Plan:
#  - `limactl start` a vz VM (Apple Virtualization.framework) with a vmnet
#    "shared" network, so the VM gets a real host-side interface (bridge100 /
#    vmenetX) that the host can filter.
#  - Enforce egress on the HOST with pf (the macOS analogue of nftables): an
#    anchor with a table of the resolved allowlist CIDRs (lib/resolve-allowlist.sh),
#    default-block on the VM's interface, pass only to the table + the bridge
#    resolver for DNS.
#  - Mount the project dir via Lima's virtiofs mount.
#  - BYPASS to close: vz still exposes Lima's default user-mode NIC. Ensure only
#    the vmnet NIC carries the default route and pf-block the slirp subnet — or
#    confirm vz single-NIC mode. VERIFY this actually closes the bypass before
#    trusting it; this is the same class of hole the Lima-on-Linux sketch had.
#
# Boundary strength: good (host-enforced via pf), below Linux/Incus only because
# the slirp-bypass mitigation is subtler.
echo "devvm: darwin-lima driver not implemented yet (see comments for the plan)." >&2
exit 2
