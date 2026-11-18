#!/usr/bin/env bash
# Streamed to the running VM by ssh-config. Only the dedicated PUBLIC key is
# passed in. Keep stdout for the guest's public host key (returned over Incus).
set -euo pipefail
id dev >/dev/null 2>&1 || { echo 'Run guest-setup.sh inside the VM first (missing dev user).' >&2; exit 1; }
[[ "${1:-}" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] || { echo 'Invalid editor public key.' >&2; exit 1; }
{
  # sshd runs in inetd mode over incus exec, never on a network interface.
  # Mask both forms *before* installation (Noble uses socket activation).
  for unit in ssh.socket ssh.service; do
    if systemctl is-active --quiet "$unit"; then
      echo "Guest $unit already active. Stop network SSH before enabling Incus-only editor access." >&2
      exit 1
    fi
  done
  systemctl mask ssh.socket ssh.service
  if [ ! -x /usr/sbin/sshd ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends openssh-server
  fi
  if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
  fi
  # The distro's ssh.service normally creates this directory at each boot.
  echo 'd /run/sshd 0755 root root -' > /etc/tmpfiles.d/devvm-sshd.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/devvm-sshd.conf
  printf '%s\n' "$1" > /etc/ssh/devvm_authorized_keys
  chmod 0644 /etc/ssh/devvm_authorized_keys
  cat > /etc/ssh/devvm_sshd_config <<'CONFIG'
HostKey /etc/ssh/ssh_host_ed25519_key
AllowUsers dev
AuthorizedKeysFile /etc/ssh/devvm_authorized_keys
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM yes
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding local
PermitOpen localhost:* 127.0.0.1:* [::1]:*
AllowStreamLocalForwarding local
PermitTunnel no
Subsystem sftp internal-sftp
CONFIG
  /usr/sbin/sshd -t -f /etc/ssh/devvm_sshd_config
} >&2
ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key | cut -d' ' -f1-2
