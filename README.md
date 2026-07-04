# immutable-os

Bootc-based immutable OS images for AlmaLinux 10. Each variant is a container image that servers boot and run directly. To change what's on a host, edit a Containerfile, push to main, and the server picks it up on its next `bootc upgrade` cycle.

## How it works

Images are built on `quay.io/almalinuxorg/almalinux-bootc:10` (or the RPi variant) and pushed to `ghcr.io/joshgordon/immutable-os/<variant>:latest`. Hosts run `bootc-fetch-apply-updates.timer` to pull and stage new images automatically; a reboot applies them.

See [bootc docs](https://bootc-dev.github.io/bootc/) and the [three-way /etc/ merge explainer](https://developers.redhat.com/articles/2025/08/25/what-image-mode-3-way-merge) for how upgrades work.

## Variants

| Image | Base | Purpose |
|-------|------|---------|
| `base-cloud-init` | almalinux-bootc:10 | Minimal base with cloud-init and growpart |
| `bao-agent` | almalinux-bootc:10 | OpenBao agent for secrets delivery |
| `dns` | bao-agent | AdGuard Home + AdGuard Home Sync + cloudflare-rdns via Quadlet |
| `almalinux-k8s` | almalinux-bootc:10 / almalinux-bootc-rpi:10 | Kubernetes node (containerd, kubelet, kubeadm, cilium-cli); RPi 5 gets a BCM2712 kernel from [almalinux-rpi5-kernel](https://github.com/joshgordon/almalinux-rpi5-kernel) |

## Adding a variant

```bash
mkdir images/myvariant
$EDITOR images/myvariant/Containerfile
```

CI auto-discovers directories under `images/`. Images whose first `FROM` references `ghcr.io/joshgordon/immutable-os/` are treated as derived and built after their base.

## Common host commands

```bash
sudo bootc status                  # current deployment and available image
sudo bootc upgrade                 # pull latest, stage for next reboot
sudo bootc rollback                # revert to previous deployment on next reboot
sudo ostree admin config-diff      # what's been locally modified in /etc
```

## CI and updates

- **Build**: GitHub Actions matrix builds each variant for amd64 and arm64, merges a multi-arch manifest, and signs with cosign keyless via Sigstore.
- **Updates**: Renovate pins base image digests and opens PRs when upstream images change. Don't update digests by hand.
