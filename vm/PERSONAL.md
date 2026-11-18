# Personal tools and authentication inside devvm

Nothing here logs in at boot, reads a host token, or mounts your home. Run the
following **inside the guest, as `dev`**, from the safeclaude checkout.

## GitHub

Run `gh-auth-setup` after base guest setup. Paste a fine-grained PAT scoped to
this VM's repositories at its hidden prompt; press Enter to skip. The helper
also accepts **guest-local** stdin, `GH_TOKEN`, or `GITHUB_TOKEN`. Do not put
a token on a command line or pass it through a host command. It configures gh
and HTTPS Git for this guest user. Any agent running as that user can use the
credential. Snapshots of an authenticated VM can contain it: revoke the token
when retiring the VM and never publish an enrolled image.

## Dotfiles and Claude skills (opt-in)

```sh
bash vm/guest-tools.sh base node
# Open a new guest shell for the tools to be on PATH, then choose groups:
bash vm/guest-personal.sh dotzsh dotvim
DOTCLAUDE_REPO=https://github.com/YOUR-ORG/dotclaude DOTCLAUDE_REF=main bash vm/guest-personal.sh dotclaude
bash vm/guest-personal.sh gstack
```

The dotfile groups default to `kurtb/dotzsh`, `kurtb/dotvim` and
`kurtb/dotclaude`. They clone under `~/dev` and run each repo's executable
`install.sh`. Authenticate in the guest first for private repos, or choose
other groups. Dotzsh keeps the existing `.zshrc` and does not change your
login shell. Start `zsh` to use it. Dotvim configures Neovim.

Gstack defaults to `garrytan/gstack` at `~/.claude/skills/gstack`. Each
group has a `<GROUP>_REPO` (credential-free HTTPS URL) and `<GROUP>_REF`
(branch/tag) override: e.g. `DOTVIM_REF`, `GSTACK_REF`. The default is the
remote default branch except for dotclaude (`main`). Rerunning uses the
existing checkout; it does not pull it, discard local edits, or switch it to
another ref. The upstream installers can still update their own dependencies
and edit your guest configuration. Review the repos before running them:
these scripts run as `dev`, with access to guest credentials and sudo.

### Playwright Chromium

Gstack setup builds the CLI. The installer uses **that checkout's** Playwright
to install Ubuntu runtime libraries and its matching browser. It checks both
gstack's offline render probe and the real `browse` command in a temporary
session. To repeat the upstream render probe:

```sh
~/.claude/skills/gstack/bin/gstack-browser-ensure --check
```

The stock allowlist deliberately does **not** include all Chromium download
hosts. For Playwright 1.65 on Linux x64, `cdn.playwright.dev` redirects Chrome
and the headless shell to `storage.googleapis.com`, and FFmpeg to
`playwright.download.prss.microsoft.com`. The proxy matches names, not bucket
paths: allowing generic object storage would allow access to unrelated
buckets. **Do not add it to the base list.**

Two ways to provision the browser without that grant:

1. Stage a clean browser artifact cache, **not a home directory, browser
   profile or login data**. On a trusted builder with the same Linux OS and
   architecture and the same Playwright version (see the guest's
   `node_modules/playwright/package.json`), start with an empty directory:
   `PLAYWRIGHT_BROWSERS_PATH=/path/to/empty/cache node node_modules/playwright/cli.js install chromium`.
   Transfer only those downloaded browser/FFmpeg artifacts into the guest's
   `~/.cache/ms-playwright/`, owned by `dev`, then rerun the gstack group.
2. Use an approved, **read-only** artifact mirror with a dedicated hostname
   and Playwright's directory layout. If needed the operator allows just that
   hostname on the host, then inside the guest runs
   `PLAYWRIGHT_DOWNLOAD_HOST=https://<mirror> bash vm/guest-personal.sh gstack`.

If the browser download is blocked or Chromium will not launch, the command
fails rather than reporting the browser skills ready. Recheck versions and
redirects after upgrading gstack.

**Chromium sandbox on Ubuntu 24.04.** The bundled Playwright browser can pass
the render probe while the actual skill fails with “No usable sandbox”.
Ubuntu's stock AppArmor profile supports the root-owned Chrome stable binary,
not a user-owned developer build. Install `google-chrome-stable` **in the
guest** from [Google's signed package repository](https://www.google.com/linuxrepositories/)
(use a repository-scoped signing key; its packages and key are on the
already-listed `dl.google.com`). In the guest shell that will run setup and
your agents, select that packaged binary:

```sh
export GSTACK_CHROMIUM_PATH=/opt/google/chrome/chrome
bash vm/guest-personal.sh gstack
```

Keep that export in your guest shell profile. The bundled Playwright cache
above is still needed by gstack's own readiness check. Do not turn off
AppArmor, enable unprivileged namespaces globally or disable Chromium's
sandbox to make a probe pass.

## Tailscale

Joining a tailnet is **unsupported**. Neither installing a daemon nor copying
the container's `tailscale-up` preserves the host boundary. Direct UDP is
blocked; with a DERP relay the host proxy could enforce only the outer relay
name, not the destination carried inside the encrypted tunnel. The existing
package/control-plane names do not authorize relay or peer access. No
enrollment keys, relay lists, tunnels or exit nodes are provisioned. A
project-specific, host-enforced design is required before enabling access.
