#!/usr/bin/env bash
# Install from a trusted checkout; a new shell does not need the checkout.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/usr/local/lib/devvm
CLI=/usr/local/bin/devvm

case "$#:${1-}" in
  1:--check) ;;
  0:) [ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; } ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

[[ -x /usr/bin/python3 ]] || { echo "FAIL python3: sudo apt install python3-apt" >&2; exit 1; }
echo "Checking installed packages against local APT indexes (run sudo apt update first)."
/usr/bin/python3 -IB "$SRC/host/check-packages.py"
[[ ${1-} != --check ]] || exit 0

# Never put the launcher or privileged runtime below a writable/symlinked dir.
for d in /usr/local /usr/local/bin /usr/local/lib "$DEST" "$DEST/drivers" "$DEST/lib"; do
  [[ -e "$d" || -L "$d" ]] || continue
  mode="$(stat -c %a "$d")"
  if [[ ! -d "$d" || -L "$d" || $(stat -c %u "$d") != 0 ]] || (( 8#$mode & 022 )); then
    echo "refusing unsafe install directory: $d (must be root-owned, not a symlink or group/world writable)" >&2
    exit 1
  fi
done
if [[ -e "$DEST/.egress-rig" ]]; then
  echo "the test rig owns $DEST; tear down the rig before installing devvm" >&2; exit 1
fi
if [[ -L "$CLI" || ( -e "$CLI" && ! -f "$CLI" ) ]] || { [[ -f "$CLI" ]] && ! cmp -s "$SRC/host/devvm" "$CLI"; }; then
  echo "refusing to overwrite unrelated $CLI; move it aside and retry" >&2; exit 1
fi

"$SRC/host/install-egress.sh"
install -o root -g root -m 0644 "$SRC/proxy/devvm-firewall.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now devvm-firewall.service
install -d -o root -g root -m 0755 "$DEST/drivers" "$DEST/lib"
# Only ship named runtime files, never extra files from a working tree.
install -o root -g root -m 0755 "$SRC"/{devvm,guest-setup,guest-tools,guest-cloud-tools,guest-personal}.sh "$SRC/gh-auth-setup" "$DEST/"
install -o root -g root -m 0755 "$SRC"/drivers/{linux-incus,incus-editor,darwin-lima,windows-wsl2}.sh "$DEST/drivers/"
install -o root -g root -m 0755 "$SRC"/lib/{doctor,guest-doctor,guest-editor-setup}.sh "$DEST/lib/"
[[ -d /usr/local/bin ]] || install -d -o root -g root -m 0755 /usr/local/bin
install -T -o root -g root -m 0755 "$SRC/host/devvm" "$CLI"
echo "Installed $CLI; from a project directory, run: devvm"
echo "Apply egress now with: devvm allow --refresh   (or the next 'devvm up')."
