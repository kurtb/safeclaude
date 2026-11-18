# Project Instructions

- Always keep `README.md` up to date when making changes to the Dockerfile, adding new features, or changing how the image is built or run.

## Container lane is in maintenance mode

The Docker container lane (`Dockerfile`, `init-firewall.sh`, `entrypoint.sh`, `safeclaude.zsh`, `install.sh` and the image workflows) is being retired in favour of the VM lane in `vm/`.

- Container changes are limited to security fixes, allowlist fixes and tool-version bumps. Keep the README's container sections accurate until the lane is removed. Do not add container features or new container mechanisms. An allowlist fix is still an egress change, so it is still a **minor** bump under the rules below.
- New capabilities go into `vm/`. If the container has something the VM lacks, port it to the VM rather than improving the container copy.

## Versioning & releases

Releases are cut via the **Release** workflow (Actions → Release → pick a bump). For this rolling image, "compatibility" means runtime behavior / how you use it — not a code API. Choose the bump by that lens:

- **patch** — fixes and tool-version bumps with no change to behavior or to what the sandbox is allowed to reach.
- **minor** — a new capability (tool/command) **OR any change to the firewall egress allowlist / surface** — i.e. what the sandbox is permitted to reach out to. Broadening egress (e.g. widening a host to a `/24`, adding a domain, or adding a provider IP range) is a **posture change** and is a minor even when it "just fixes" an already-listed host, so the change is visible to anyone auditing the egress posture.
- **major** — a breaking change to how you use it (removed/renamed command, changed volume or run model).
