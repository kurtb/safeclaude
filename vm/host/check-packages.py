"""Read-only Debian/Ubuntu host preflight. Run with the distro's python3."""

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import apt
    import apt_pkg
except ImportError:
    sys.exit("FAIL python3-apt: install the distro bindings: sudo apt install python3-apt")


def supported(origin, incus):
    if not origin.trusted or not origin.site:
        return False
    if (origin.origin, origin.label) in {
        ("Ubuntu", "Ubuntu"), ("Debian", "Debian"), ("Debian", "Debian-Security")
    }:
        return True
    return incus and (origin.site, origin.origin, origin.label) == (
        "pkgs.zabbly.com", "pkgs.zabbly.com", "incus-stable"
    )


def check_binary(pkg, command):
    # Check the final target, not just /usr/bin/incus (a symlink on Zabbly).
    # Do not execute possibly unpackaged or locally overwritten binaries.
    found = shutil.which(command)
    if not found:
        raise ValueError(f"{command} not on PATH")
    path = Path(found).resolve(strict=True)
    sums = subprocess.run(
        ["/usr/bin/dpkg-query", "--control-show", pkg.fullname, "md5sums"],
        capture_output=True, text=True, check=True,
    ).stdout
    for line in sums.splitlines():
        checksum, filename = line.split(maxsplit=1)
        listed = Path("/") / filename
        # Debian's merged /usr can make /sbin and /usr/sbin aliases.
        if listed.name != path.name or listed.parent.resolve() / listed.name != path:
            continue
        digest = hashlib.md5(usedforsecurity=False)
        with path.open("rb") as binary:
            for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != checksum:
            raise ValueError(f"{path} differs from the packaged binary")
        return
    raise ValueError(f"{found} is not the binary from {pkg.name} (remove the snap/local override)")


def check_package(cache, name, command=None, minimum=None):
    if name not in cache or not cache[name].is_installed:
        raise ValueError("package not installed")
    pkg = cache[name]
    installed = pkg.installed
    state = subprocess.check_output([
        "/usr/bin/dpkg-query", "--show", "-f=${db:Status-Status} ${db:Status-Eflag}", pkg.fullname
    ], text=True)
    if state != "installed ok":
        raise ValueError(f"incomplete dpkg installation ({state}); finish configuring the package")
    if pkg.is_now_broken:
        raise ValueError("broken package dependencies")
    if minimum and apt_pkg.version_compare(apt_pkg.upstream_version(installed.version), minimum) < 0:
        raise ValueError(f"installed {installed.version}; need >= {minimum}")
    if not pkg.candidate or pkg.candidate.version != installed.version:
        candidate = pkg.candidate.version if pkg.candidate else "(none)"
        raise ValueError(f"installed {installed.version}; APT candidate {candidate}")
    # dpkg does not store historical download URLs. Require the exact installed
    # version in an enabled, trusted index; /var/lib/dpkg/status alone isn't one.
    origins = [o for o in installed.origins if o.archive != "now"]
    if not origins or not all(supported(o, name.startswith("incus")) for o in origins):
        raise ValueError(f"{installed.version} not unambiguously offered by a supported repository; "
                         "restore the supported APT source and remove conflicting sources")
    # Pinning can hide a newer version in the same repository from candidate.
    sources = {(o.site, o.archive, o.label) for o in origins}
    for version in pkg.versions:
        if apt_pkg.version_compare(version.version, installed.version) > 0 and any(
            (o.site, o.archive, o.label) in sources for o in version.origins
        ):
            raise ValueError(f"installed {installed.version}; repository offers {version.version} (check APT pins)")
    if command:
        check_binary(pkg, command)
    source = origins[0]
    return f"{installed.version} ({source.site}, {source.label}/{source.archive})"


def main():
    cache = apt.Cache(memonly=True)
    checks = [
        ("incus", None, "7.5.1"), ("incus-client", "incus", "7.5.1"),
        ("haproxy", "haproxy", "2.8"), ("nftables", "nft", None),
        ("dnsmasq-base", "dnsmasq", None), ("jq", "jq", None),
        ("bind9-dnsutils", "dig", None),
    ]
    if "incus-base" in cache and cache["incus-base"].is_installed:
        checks.insert(1, ("incus-base", None, "7.5.1"))
    failed = False
    for name, command, minimum in checks:
        try:
            details = check_package(cache, name, command, minimum)
            print(f"OK   {name}: {details}")
        except (ValueError, OSError, subprocess.CalledProcessError) as err:
            fix = f"sudo apt update && sudo apt install --reinstall {name}"
            if name.startswith("incus"):
                fix += " (Zabbly stable recommended: https://github.com/zabbly/incus#stable-repository)"
            print(f"FAIL {name}: {err}; {fix}")
            failed = True
    if "dnsmasq" in cache and cache["dnsmasq"].is_installed:
        print("FAIL dnsmasq: full service installed; remove dnsmasq, keep dnsmasq-base")
        failed = True
    else:
        print("OK   dnsmasq: no full service package installed")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
