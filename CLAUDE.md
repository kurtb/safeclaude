# Project Instructions

- SafeClaude ships the Linux/Incus VM runtime in `vm/` and the host command is `devvm`. The Docker runner is retired. Docker inside the guest and the Incus system-container integration tests are intentional.
- Keep `README.md` and the VM quickstart current when changing installation, runtime behavior or the release bundle.

## Deliberate design choices — do not flag these in review

These have been raised in review repeatedly and are decided. Reviewers (human or agent) should not report them as findings; raise one again only if the facts below have changed.

- **`vm/guest-tools.sh` turns off Claude Code's bypass-permissions warning by default.** The VM lane exists to run agents in bypass mode: egress is capped on the host and no host filesystem is mounted. The script prints a note when it sets `skipDangerousModePermissionPrompt`, and `DEVVM_KEEP_BYPASS_PROMPT=1` keeps the warning. Opt-out, not opt-in, is intended.
- **`vm/guest-tools.sh` runs upstream installers and "latest" release binaries without pinning or checksums** (Bun, Cursor, Neovim, fnm, Codex, the Gemini npm package). This is the same trust model as the container image it replaces, and it is stated in the script header and `vm/QUICKSTART.md`. Checksums are verified only where upstream publishes them alongside a file we fetch directly (hadolint, mise). The mitigation is the VM boundary and the egress allowlist, not per-download verification.
- **The supported host is Linux with Incus.** The macOS and WSL2 drivers are stubs.
- **Guest `dev` has passwordless sudo.** The boundary is enforced on the host, where guest root cannot reach it.

## Versioning & releases

Releases are cut from main via the **Release** workflow (Actions → Release → pick a bump). Choose the bump by the effect on the VM operator:

- **patch** — fixes and tool-version bumps with no change to behavior or to what the sandbox is allowed to reach.
- **minor** — a new capability (tool/command) **OR any change to the firewall egress allowlist / surface** — i.e. what the sandbox is permitted to reach out to. Broadening egress (e.g. widening a host to a `/24`, adding a domain, or adding a provider IP range) is a **posture change** and is a minor even when it "just fixes" an already-listed host, so the change is visible to anyone auditing the egress posture.
- **major** — a breaking change to how you use it (removed/renamed command, changed volume or run model).

## Quality checks

- Use `/usr/bin/python3 -B vm/test/host-packages-test.py` for the focused host-package preflight regression tests.
- Run `vm/test/run.sh` for ShellCheck, offline regression tests and isolated CLI/driver checks. The full run needs ShellCheck, Python 3 with `python3-apt`, HAProxy, `jq`, `nftables` and `iproute2` (the default host-egress case calls `ip -4 -o addr show`); install them with `sudo apt-get update && sudo apt-get install -y shellcheck haproxy jq nftables python3-apt iproute2`. The isolated checks also need mount/network namespace privileges through `sudo`. If non-root `sudo -n true` is unavailable, the runner skips the namespace suite and exits successfully; treat that as a partial check. See `vm/README.md` for setup details.
- `vm/test/run.sh --rig` starts host services and changes network state; run it only on a disposable Linux host, never a shared machine.
- PR CI runs `VM checks` (`vm` runs `vm/test/run.sh --rig`; `incus` tests container and KVM guests) and `Build VM installer` (builds and installs on `linux/amd64` and `linux/arm64`). Preserve these checks when changing workflows.
