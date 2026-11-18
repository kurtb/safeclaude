# SafeClaude

SafeClaude runs coding agents in an Ubuntu VM on a Linux host with KVM. The `devvm` command creates one Incus VM per project. Each guest has its own kernel and Git clone. The host enforces the DNS and web egress allowlist. Docker and minikube run inside the guest.

## Install

From a directory you control on the Linux host, download the release installer and run it:

```bash
curl -fL --proto '=https' https://github.com/kurtb/safeclaude/releases/latest/download/install.sh -o install.sh && sudo bash ./install.sh
```

Run `sudo bash ./install.sh` again to upgrade the host. Each run resolves the latest stable GitHub release, downloads the bundle and checksum for that tag, and verifies the archive before installing it. Running it again on the same release reapplies the host installation. Your Incus storage, project VMs and guest clones persist. To update the tools inside a guest, run `devvm upgrade` from its project directory.

To install a specific version, download **devvm.tar.gz** and **devvm.tar.gz.sha256** from that [GitHub release](https://github.com/kurtb/safeclaude/releases) and run:

```bash
sha256sum -c devvm.tar.gz.sha256 && tar -xzf devvm.tar.gz && sudo ./devvm/install-host.sh
```

The checksum checks download integrity. The installer configures the signed stable Incus APT channel and installs the host tools on Ubuntu 24.04/26.04 or Debian 13 (amd64 and arm64). To install from a trusted checkout, run `sudo ./vm/install-host.sh`.

On a fresh Incus host, initialize storage with `sudo incus admin init --minimal`. On an existing installation, check `incus storage list` first. Give your trusted operator account access with `sudo usermod -aG incus-admin "$USER"` and log back in. The group grants host administrator privileges.

## Start a project

From the **host**, in the project's Git checkout:

```bash
devvm up         # first boot opens a bare guest shell
exit             # back on the host
devvm upgrade    # install the dev user, GitHub CLI, Docker and Claude Code
devvm doctor     # check the guest tools, firewall, DNS and proxy
devvm up         # clone a public HTTPS origin and enter the guest as dev
```

Edit the guest clone under `~/workspace`. For a private repo, log in with `gh-auth-setup` inside the guest, then clone there. Run `claude login` inside the guest as well. Use `devvm stop` on the host to shut down the VM and `devvm up` to resume. The [quickstart](vm/QUICKSTART.md) covers optional tools, file transfers, editor setup and snapshots. See the [VM security model](vm/README.md) for the allowlist and its limitations.

## Migrating from the Docker runner

**The host Docker runner and its GHCR image are retired.** Previously published image tags remain available. The supported command is `devvm`. The VM installer leaves existing containers, volumes and project checkouts alone.

1. The old runner bind-mounted your host project. Review and commit or otherwise back up any local changes you want to keep. Push the commits you want the guest to clone.
2. Inventory old containers and volumes with `docker ps -a --filter name=safeclaude-` and `docker volume ls --filter name=safeclaude-`. The old home directory was in a named volume mounted at `/home/ubuntu`. Copy out individual files you need before removing anything. For example, `docker cp safeclaude-PROJECT:/home/ubuntu/notes.txt ./notes-backup.txt` works with a stopped container. Keep credentials scoped to the new guest.
3. Remove the old `safeclaude.zsh` source line or the installer-managed `# >>> safeclaude >>>` block from your shell startup file. Open a new shell, install the VM release and start the project as above. Use `devvm cp push` for selected local files.
4. Once you have verified your backups and guest clone, you can remove the old container and its volume by their exact names. Removing the volume permanently deletes its contents.

The [v0.5.0 documentation](https://github.com/kurtb/safeclaude/tree/v0.5.0) covers the retired runner.
