# Project Instructions

- Always keep `README.md` up to date when making changes to the Dockerfile, adding new features, or changing how the image is built or run.

## Versioning & releases

Releases are cut via the **Release** workflow (Actions → Release → pick a bump). For this rolling image, "compatibility" means runtime behavior / how you use it — not a code API. Choose the bump by that lens:

- **patch** — fixes and tool-version bumps with no change to behavior or to what the sandbox is allowed to reach.
- **minor** — a new capability (tool/command) **OR any change to the firewall egress allowlist / surface** — i.e. what the sandbox is permitted to reach out to. Broadening egress (e.g. widening a host to a `/24`, adding a domain, or adding a provider IP range) is a **posture change** and is a minor even when it "just fixes" an already-listed host, so the change is visible to anyone auditing the egress posture.
- **major** — a breaking change to how you use it (removed/renamed command, changed volume or run model).
