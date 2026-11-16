#!/usr/bin/env bash
# Windows driver (SKETCH / not implemented): WSL2 + nested Incus/nftables.
#
# Plan:
#  - WSL2 is itself a Linux utility VM (real kernel; nested virt available on
#    recent Windows via .wslconfig `nestedVirtualization=true`). Run the
#    Linux/Incus driver INSIDE the WSL2 distro — so most of linux-incus.sh is
#    reused verbatim.
#  - Enforce egress with the SAME Incus network ACL / nftables approach inside
#    WSL2, on the Incus bridge.
#  - Requirements in the distro: systemd enabled, /dev/kvm present (for Incus
#    VMs), Incus installed.
#
# Boundary strength: weakest of the three. WSL2's own NAT/mirrored networking is
# the outermost layer and is managed by Windows (HNS), not by us — so the true
# host boundary sits at the WSL2 VM edge, and our allowlist is enforced INSIDE
# that VM. Fine for dev; not a hard multi-tenant boundary.
#
# This driver would detect WSL, then delegate to linux-incus.sh running in-distro.
echo "devvm: windows-wsl2 driver not implemented yet (see comments for the plan)." >&2
exit 2
