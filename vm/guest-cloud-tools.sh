#!/usr/bin/env bash
# Optional cloud and Kubernetes tools. Run inside the VM as dev, after
# guest-setup.sh: bash ~/workspace/safeclaude/vm/guest-cloud-tools.sh
# The Google apt repository supplies gcloud and kubectl. Release downloads
# go into ~/.local and are checked against the publishers' SHA-256 digests.
# Starting a cluster and logging in to cloud services are separate user steps.
set -euo pipefail

if [[ $(id -u) == 0 ]]; then
  echo "Run this inside the VM as dev after guest-setup.sh." >&2
  exit 1
fi

pulumi_version=3.276.0
helm_version=v4.3.2
minikube_version=v1.39.0
arch=$(dpkg --print-architecture)
# For version bumps: Pulumi publishes pulumi-<version>-checksums.txt in its
# GitHub release, Helm publishes .sha256sum and minikube publishes .sha256.
case "$arch" in
  amd64)
    pulumi_arch=x64
    pulumi_sha=99f6b4626be083a3326517a46ba33b995f44812058143a018d9dffaa027ec3bf
    helm_sha=d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983
    minikube_sha=b738496da01be06bbaf80c688f57ce25acd3849fbb518155f3a88e03ef555aa4
    ;;
  arm64)
    pulumi_arch=arm64
    pulumi_sha=dbf8d1efd39f3fc3f0d9cefa37c6caba8fdf937562dbaa93b6c284ded4f2c904
    helm_sha=df31cb61680ef728f82c770e5280dd565617bee6b039d37e85c677288be4bbb0
    minikube_sha=202f331cb677761c5aec81c58472d16d65707358b9f66226210be3fe3275b1c3
    ;;
  *) echo "Unsupported guest architecture: $arch" >&2; exit 1 ;;
esac

bin="$HOME/.local/bin"
export PATH="$bin:$PATH"
mkdir -p "$bin"
tmp=$(mktemp -d "$HOME/.local/.devvm-cloud.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
fetch() { curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 -o "$2" "$1"; }
download() {
  fetch "$1" "$tmp/$2"
  (cd "$tmp" && printf '%s  %s\n' "$3" "$2" | sha256sum --check)
}

if ! have gcloud || ! have kubectl; then
  echo "Installing gcloud and kubectl from Google's apt repository"
  fetch https://packages.cloud.google.com/apt/doc/apt-key.gpg "$tmp/google.asc"
  sudo install -d -m 0755 /etc/apt/keyrings
  sudo install -m 0644 "$tmp/google.asc" /etc/apt/keyrings/devvm-google-cloud.asc
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/devvm-google-cloud.asc] https://packages.cloud.google.com/apt cloud-sdk main" > "$tmp/google.list"
  sudo install -m 0644 "$tmp/google.list" /etc/apt/sources.list.d/google-cloud-sdk.list
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends google-cloud-cli kubectl
fi

if ! have pulumi; then
  echo "Installing Pulumi $pulumi_version"
  pulumi_dir="$HOME/.local/opt/pulumi-$pulumi_version"
  if [[ ! -x "$pulumi_dir/pulumi" ]]; then
    download "https://get.pulumi.com/releases/sdk/pulumi-v$pulumi_version-linux-$pulumi_arch.tar.gz" pulumi.tgz "$pulumi_sha"
    tar -xzf "$tmp/pulumi.tgz" -C "$tmp"
    mkdir -p "$HOME/.local/opt"
    mv -T "$tmp/pulumi" "$pulumi_dir"
  fi
  ln -sfn "$pulumi_dir/pulumi" "$bin/pulumi"
fi

if ! have helm; then
  echo "Installing Helm $helm_version"
  download "https://get.helm.sh/helm-$helm_version-linux-$arch.tar.gz" helm.tgz "$helm_sha"
  tar -xzf "$tmp/helm.tgz" -C "$tmp" "linux-$arch/helm"
  mv "$tmp/linux-$arch/helm" "$bin/helm"
fi

if ! have minikube; then
  echo "Installing minikube $minikube_version"
  download "https://github.com/kubernetes/minikube/releases/download/$minikube_version/minikube-linux-$arch" minikube "$minikube_sha"
  chmod 0755 "$tmp/minikube"
  mv "$tmp/minikube" "$bin/minikube"
fi

# On a first start, minikube 1.39 assumes this directory already exists
# when GitHub rate-limits its checksum lookup for the Kubernetes preload.
mkdir -p "$HOME/.minikube/cache/preloaded-tarball"

gcloud version
PULUMI_SKIP_UPDATE_CHECK=true pulumi version
kubectl version --client
helm version --short
minikube version
echo "To start a local cluster, run as dev: minikube start --driver=docker"
