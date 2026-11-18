#!/usr/bin/env bash
# Static checks and offline tests of the CLI, DNS config and proxy policy.
set -euo pipefail
vm=$(cd "$(dirname "$0")/.." && pwd)
while IFS= read -r -d '' script; do
  case $(head -c 120 "$script" | head -n1) in
    '#!'*bash*|'#!'*'/sh') shellcheck --severity=warning "$script" ;;
  esac
done < <(find "$vm" -type f -print0)
"/usr/bin/python3" -B "$vm/test/host-packages-test.py"
python3 -B "$vm/test/guest-personal-test.py"
"$vm/test/guest-doctor-test.sh"

LC_ALL=C awk '
  /^[[:space:]]*(#|$)/ { next }
  !/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$/ || seen[$0]++ {
    printf "%s:%d: invalid or duplicate hostname: %s\n", FILENAME, FNR, $0; bad=1
  }
  END { if (!length(seen)) bad=1; exit bad }
' "$vm/allowlist.conf"

# Keep absolute install paths inside private mounts, and prevent network
# access even if a stub is missing. No host service or firewall is changed.
sudo unshare --mount --net --propagation private bash -eu -o pipefail -s "$vm" <<'ISOLATED'
vm=$1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -L /etc/{passwd,group,resolv.conf} "$scratch"
awk_bin=$(readlink -f "$(command -v awk)")
for path in /usr/local/lib /etc /run; do mount -t tmpfs tmpfs "$path"; done
cp "$scratch"/{passwd,group,resolv.conf} /etc
mkdir -p /etc/systemd/system /usr/local/lib/devvm "$scratch/bin"
install -m 0755 "$vm"/lib/host-{egress,firewall}.sh /usr/local/lib/devvm/
install -m 0644 "$vm"/allowlist.conf "$vm"/proxy/{haproxy.cfg,bogons.lst} /usr/local/lib/devvm/
install -m 0644 "$vm"/proxy/devvm-proxy.service /etc/systemd/system/
export PATH="$scratch/bin:$PATH"
ln -s "$awk_bin" "$scratch/bin/awk"
cat >"$scratch/bin/incus" <<'INCUS'
#!/bin/sh
case "$1 $2" in
  'network show') exit 0 ;;
  'network list') echo '[]' ;;
  'network set') printf '%s\n' "$4" > /run/test-dns ;;
  *) echo "unexpected incus invocation: $*" >&2; exit 1 ;;
esac
INCUS
cat >"$scratch/bin/nft" <<'NFT'
#!/bin/sh
case "$1" in
  -f) cp "$2" /run/test-rules ;;
  -s) echo "test readback of $*" ;;
  *) exit 1 ;;
esac
NFT
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>/run/test-systemctl\n' >"$scratch/bin/systemctl"
printf '#!/bin/sh\nexec "$@"\n' >"$scratch/bin/sudo"
chmod +x "$scratch/bin/"*

cli="$vm/devvm.sh"
extra=/etc/devvm/allowlist.local
live=/etc/devvm/allowed-domains
host=vm-ci.example
"$cli" allow "https://VM-CI.EXAMPLE/path"
grep -Fx "$host" "$extra" >/dev/null
grep -Fx "$host" "$live" >/dev/null
grep -Fx "server=/$host/1.1.1.1" /run/test-dns >/dev/null
grep -F 'table inet devvm' /run/test-rules >/dev/null
grep -Fx 'restart devvm-proxy.service' /run/test-systemctl >/dev/null
"$cli" allow "$host"
[[ $(grep -Fxc "$host" "$extra") == 1 ]]
if "$cli" allow '*.invalid'; then echo "accepted a wildcard" >&2; exit 1; fi
: >/run/test-systemctl
"$cli" allow --rm "$host"
if grep -F "$host" "$extra" "$live" /run/test-dns; then exit 1; fi
grep -Fx 'restart devvm-proxy.service' /run/test-systemctl >/dev/null
ISOLATED
echo "VM checks passed."
