#!/usr/bin/env bash
# Static checks and offline tests of the CLI, DNS config and proxy policy.
set -euo pipefail
vm=$(cd "$(dirname "$0")/.." && pwd)
case "$#:${1-}" in 0:|1:--rig) ;; *) echo "usage: $0 [--rig]" >&2; exit 2 ;; esac
while IFS= read -r -d '' script; do
  case $(head -c 120 "$script" | head -n1) in
    '#!'*bash*|'#!'*'/sh') shellcheck --severity=warning "$script" ;;
  esac
done < <(find "$vm" -type f -print0)
"/usr/bin/python3" -B "$vm/test/host-packages-test.py"
python3 -B "$vm/test/guest-personal-test.py"
python3 -B "$vm/test/host-vscode-settings-test.py"
"$vm/test/guest-doctor-test.sh"

LC_ALL=C awk -F. '
  /^[[:space:]]*(#|$)/ { next }
  { for (i=1; i<=NF; i++) if (length($i)>63) {print FILENAME ":" FNR ": label too long"; bad=1} }
  !/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$/ || seen[$0]++ {
    printf "%s:%d: invalid or duplicate hostname: %s\n", FILENAME, FNR, $0; bad=1
  }
  END { if (!length(seen)) bad=1; exit bad }
' "$vm/allowlist.conf"

# Keep absolute install paths inside private mounts, and prevent network
# access even if a stub is missing. No host service or firewall is changed.
if [[ $EUID != 0 ]] && ! sudo -n true 2>/dev/null; then
  [[ ${1-} != --rig ]] || { echo "--rig requires root" >&2; exit 1; }
  echo "Static checks passed. SKIP namespace tests (run sudo vm/test/run.sh)."
  exit 0
fi
sudo unshare --mount --net --propagation private bash -eu -o pipefail -s "$vm" <<'ISOLATED'
vm=$1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -L /etc/{passwd,group,resolv.conf} "$scratch"
awk_bin=$(readlink -f "$(command -v awk)")
nft_bin=$(command -v nft)
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
"$nft_bin" -c -f /run/test-rules
grep -Fx 'restart devvm-proxy.service' /run/test-systemctl >/dev/null
"$cli" allow "$host"
[[ $(grep -Fxc "$host" "$extra") == 1 ]]
if "$cli" allow '*.invalid'; then echo "accepted a wildcard" >&2; exit 1; fi
"$cli" allow | grep -F "$host"
if "$cli" allow --refresh "$host"; then exit 1; fi
grep -Fx "$host" "$extra"
for bad in '192.0.2.1' 'bad.test # comment' 'bad;host.test' 'host.test:443'; do
  if "$cli" allow "$bad"; then exit 1; fi
done
base=/usr/local/lib/devvm/allowlist.conf
echo installed-only.test >> "$base"
"$cli" allow installed-only.test | grep -F 'already allowed: installed-only.test'
if grep -Fx installed-only.test "$extra"; then exit 1; fi
"$cli" allow cidr:legacy.test > /run/output 2>&1
grep -F 'no longer needed' /run/output
grep -Fx legacy.test "$extra"
cp "$base" /run/base
echo 'not a hostname' >> "$base"
if "$cli" allow retry.test >/run/output 2>&1; then exit 1; fi
grep -F 'NOT fully applied' /run/output
mv /run/base "$base"
"$cli" allow retry.test
grep -Fxc 'server=/retry.test/1.1.1.1' /run/test-dns | grep -Fx 1
: >/run/test-systemctl
"$cli" allow --rm "$host"
if grep -F "$host" "$extra" "$live" /run/test-dns; then exit 1; fi
grep -Fx 'restart devvm-proxy.service' /run/test-systemctl >/dev/null
"$cli" allow --refresh
cp "$live" /run/good-domains
cp /etc/devvm/haproxy.cfg /run/good-proxy
cp "$base" /run/good-base
apply_must_fail() {
  if /usr/local/lib/devvm/host-egress.sh > /run/error 2>&1; then exit 1; fi
  grep -Fi "$1" /run/error
  cmp /run/good-domains "$live"
  cmp /run/good-proxy /etc/devvm/haproxy.cfg
}
chown 65534 "$base"
apply_must_fail 'must be root-owned'
chown 0 "$base"
echo 'host.test # invalid' >> "$base"
apply_must_fail 'not a plain host name'
mv "$extra" /run/extras
: > "$base"
apply_must_fail 'allowlist is empty'
mv /run/extras "$extra"
mv /run/good-base "$base"
echo invalid-directive >> /usr/local/lib/devvm/haproxy.cfg
apply_must_fail 'generated proxy config is invalid'
"$vm/test/driver-test.sh" "$vm" "$scratch/bin"
ISOLATED
if [[ ${1-} == --rig ]]; then
  sudo "$vm/test/egress-test.sh" --down
else
  echo "SKIP systemd egress rig (run with --rig on a disposable host)"
fi
echo "VM checks passed."
