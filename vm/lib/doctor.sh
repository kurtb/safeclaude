#!/usr/bin/env bash
# Sourced by linux-incus.sh. All host checks are read-only. In particular,
# don't run apply_egress here: a repair would conceal the original failure.

doctor_check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'OK    %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label" >&2
    failed=1
  fi
}

# Frozen reference for the shared-bridge install shipped in PR #34. It had
# no saved readback. Match the whole table, including unconditional accepts
# and rule order, until the host installs the boot firewall service.
check_legacy_firewall() {
  local live
  live="$(sudo nft -s list table inet devvm | awk 'NF { $1=$1; print }')" || return 1
  cmp -s <(printf '%s\n' "$live") - <<'TABLE'
table inet devvm {
chain prerouting {
type nat hook prerouting priority dstnat; policy accept;
ip saddr 10.63.0.0/24 tcp dport 80 dnat ip to 10.63.0.1:3129
ip saddr 10.63.0.0/24 tcp dport 443 dnat ip to 10.63.0.1:3130
}
chain input {
type filter hook input priority filter; policy accept;
iifname != "devvmbr0" accept
ct state established,related accept
iifname "devvmbr0" udp dport 67 accept
iifname "devvmbr0" ip daddr 10.63.0.1 udp dport 53 accept
iifname "devvmbr0" ip daddr 10.63.0.1 tcp dport { 53, 3129, 3130 } accept
iifname "devvmbr0" drop
}
chain forward {
type filter hook forward priority filter; policy accept;
ct state established,related accept
oifname "devvmbr0" ct state new drop
iifname "devvmbr0" counter reject
}
}
TABLE
}

check_firewall() {
  local net="$1" family saved
  if [[ "$net" = devvmbr0 && ! -e /usr/local/lib/devvm/host-firewall.sh && ! -d /run/devvm-firewall-applied ]]; then
    check_legacy_firewall
    return
  fi
  for family in inet bridge; do
    saved="/run/devvm-firewall-applied/$family"
    # Ignore changing counters, compare the actual ordered rules and hooks.
    if [ ! -s "$saved" ] || ! sudo nft -s list table "$family" devvm | cmp -s "$saved" -; then
      echo "  $family devvm differs from the applied firewall (or has no readback)" >&2
      return 1
    fi
  done
  check_firewall_lifecycle
}

# nftables.service flushes the ruleset on start, reload and stop. Its drop-in
# must restore the devvm tables after each, or the guest firewall fails open.
check_firewall_lifecycle() {
  local prop
  for prop in ExecStartPost ExecReload ExecStopPost; do
    if ! systemctl show -p "$prop" --value nftables.service |
        grep -Fq 'argv[]=/usr/local/lib/devvm/host-firewall.sh --restore ;'; then
      echo "  nftables.service $prop does not restore the devvm firewall; rerun sudo ./install-host.sh" >&2
      return 1
    fi
  done
}

proxy_listening() {
  local listeners
  listeners="$(ss -Hln4t | awk '{print $4}')" || return 1
  grep -Fxq '10.63.0.1:3129' <<<"$listeners" && grep -Fxq '10.63.0.1:3130' <<<"$listeners"
}

# The installed template enforces the name ACL, resolves the name on the host
# and selects that destination. Compare the whole generated config, including
# rule order, without constructing packets to try to bypass it.
check_proxy_config() {
  sed -e 's/@PROXY_IP@/10.63.0.1/g' -e 's|@DOMAINS@|/etc/devvm/allowed-domains|g' \
      -e 's|@BOGONS@|/etc/devvm/bogons|g' /usr/local/lib/devvm/haproxy.cfg |
    cmp -s /etc/devvm/haproxy.cfg -
}

# Advisory only: VS Code user data does not show that Remote-SSH is in use,
# so this never fails doctor. Remote-SSH gives guest code a channel to the
# host VS Code client; report the host settings that hand it Git credentials
# or forward its ports.
check_vscode_settings() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}" app report
  local -a dirs=()
  for app in Code 'Code - Insiders' devvm-vscode; do
    [ -d "$base/$app/User" ] && dirs+=("$base/$app/User")
  done
  if [ "${#dirs[@]}" = 0 ]; then
    echo 'SKIP  host VS Code Remote-SSH settings (advisory; no VS Code user data found)'
    return 0
  fi
  if report="$(/usr/bin/python3 -IB "$VMDIR/lib/host-vscode-settings.py" "${dirs[@]}" 2>&1)"; then
    echo 'INFO  host VS Code Remote-SSH settings (advisory): a profile sets the required values'
  else
    echo 'WARN  host VS Code Remote-SSH settings (advisory): no profile sets the required values'
  fi
  printf '%s\n' "$report"
  echo '      Applies only to Remote-SSH. Doctor cannot tell which profile a connection uses or which accounts are signed in.'
  echo '      See QUICKSTART.md, "VS Code settings for devvm hosts".'
}

cmd_doctor() {
  local name="$1" failed=0 installed=/usr/local/lib/devvm/allowlist.conf checkout="$VMDIR/allowlist.conf"
  local net expected_dns actual_dns expected_domains file
  local -a domains
  if [ -n "${DEVVM_CHECKOUT:-}" ]; then checkout="$DEVVM_CHECKOUT/vm/allowlist.conf"; fi
  if [[ "$installed" -ef "$checkout" && -z "${DEVVM_CHECKOUT:-}" ]]; then
    echo 'SKIP  source allowlist comparison (set DEVVM_CHECKOUT to the safeclaude checkout)'
  else
    doctor_check "installed base allowlist matches $checkout" cmp -s "$checkout" "$installed"
  fi
  doctor_check 'dedicated HAProxy service active' systemctl is-active --quiet devvm-proxy.service
  doctor_check 'HTTP and HTTPS proxy listeners' proxy_listening
  doctor_check 'by-name proxy policy matches the installed template' check_proxy_config
  for file in haproxy.cfg bogons allowed-domains; do
    doctor_check "$file matches the last successful proxy apply" cmp -s "/etc/devvm/$file" "/run/devvm-proxy-applied/$file"
  done
  check_vscode_settings
  net="$(incus config device get "$name" eth0 network)" || return 1
  case "$net" in
    devvmbr0|"dvmp-${name##*-}") ;;
    *) echo "FAIL  $name is attached to an unexpected network: $net" >&2; return 1 ;;
  esac
  doctor_check 'effective Incus devices limited to root disk and project NIC' check_project_devices "$net"
  doctor_check "host nftables enforcement ($net)" check_firewall "$net"
  expected_dns="$(build_raw_dnsmasq)" || return 1
  actual_dns="$(incus network get "$net" raw.dnsmasq)" || return 1
  doctor_check "allowlist-only DNS on $net" test "$actual_dns" = "$expected_dns"

  expected_domains="$(sed -n 's|^server=/\([^/]*\)/.*|\1|p' <<<"$expected_dns")"
  if [ -z "$expected_domains" ] || grep -qEv '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$' <<<"$expected_domains"; then
    echo 'FAIL  installed base list and extras must contain exact hostnames' >&2; return 1
  fi
  doctor_check 'proxy loaded installed base list plus local extras' cmp -s /run/devvm-proxy-applied/allowed-domains - <<<"$expected_domains"
  mapfile -t domains <<<"$expected_domains"
  if ! is_running; then echo "FAIL  $name must be running for guest checks" >&2; return 1; fi
  echo "Checking ${#domains[@]} allowlisted domains inside $name ..."
  doctor_check 'guest smoke test' incus exec "$name" -T -- bash -s -- "${domains[@]}" < "$VMDIR/lib/guest-doctor.sh"
  return "$failed"
}
