# Project Instructions

- Always keep `README.md` up to date when making changes to the Dockerfile, adding new features, or changing how the image is built or run.

## Container lane is in maintenance mode

The Docker container lane (`Dockerfile`, `init-firewall.sh`, `entrypoint.sh`, `safeclaude.zsh`, `install.sh` and the image workflows) is being retired in favour of the VM lane in `vm/`.

- Container changes are limited to security fixes, allowlist fixes and tool-version bumps. Keep the README's container sections accurate until the lane is removed. Do not add container features or new container mechanisms. An allowlist fix is still an egress change, so it is still a **minor** bump under the rules below.
- New capabilities go into `vm/`. If the container has something the VM lacks, port it to the VM rather than improving the container copy.

## Deliberate design choices — do not flag these in review

These have been raised in review repeatedly and are decided. Reviewers (human or agent) should not report them as findings; raise one again only if the facts below have changed.

- **`vm/guest-tools.sh` turns off Claude Code's bypass-permissions warning by default.** The VM lane exists to run agents in bypass mode: egress is capped on the host and no host filesystem is mounted. The script prints a note when it sets `skipDangerousModePermissionPrompt`, and `DEVVM_KEEP_BYPASS_PROMPT=1` keeps the warning. Opt-out, not opt-in, is intended.
- **`vm/guest-tools.sh` runs upstream installers and "latest" release binaries without pinning or checksums** (Bun, Cursor, Neovim, fnm, Codex, the Gemini npm package). This is the same trust model as the container image it replaces, and it is stated in the script header and `vm/QUICKSTART.md`. Checksums are verified only where upstream publishes them alongside a file we fetch directly (hadolint, mise). The mitigation is the VM boundary and the egress allowlist, not per-download verification.
- **The VM lane is Linux/Incus only, and that does not block retiring the container.** There is one user, on Linux. The macOS and WSL2 drivers are stubs and are out of scope; the container's removal is not gated on them.
- **Guest `dev` has passwordless sudo.** The boundary is enforced on the host, where guest root cannot reach it.

## Versioning & releases

Releases are cut via the **Release** workflow (Actions → Release → pick a bump). For this rolling image, "compatibility" means runtime behavior / how you use it — not a code API. Choose the bump by that lens:

- **patch** — fixes and tool-version bumps with no change to behavior or to what the sandbox is allowed to reach.
- **minor** — a new capability (tool/command) **OR any change to the firewall egress allowlist / surface** — i.e. what the sandbox is permitted to reach out to. Broadening egress (e.g. widening a host to a `/24`, adding a domain, or adding a provider IP range) is a **posture change** and is a minor even when it "just fixes" an already-listed host, so the change is visible to anyone auditing the egress posture.
- **major** — a breaking change to how you use it (removed/renamed command, changed volume or run model).
