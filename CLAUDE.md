# CLAUDE.md

Context for AI assistants working in this repo. Skim this before making changes.

## What this is

A monorepo of bootc-based, immutable OS images for AlmaLinux 10. Each directory
under `images/` is a separate variant (web server, NAS, etc). CI builds them all
to `ghcr.io/<owner>/<repo>/<variant>:latest` and signs them with cosign.

Servers run these images via `bootc`. To change what's installed on a server,
you edit the Containerfile, push to main, CI rebuilds, and the server pulls
on its next `bootc upgrade` cycle (timer-driven or manual).

## Repo layout

- `images/<variant>/Containerfile` — one per OS variant. Adding a new variant
  is just `mkdir images/whatever && $EDITOR images/whatever/Containerfile`.
  The CI matrix auto-discovers directories.
- `shared/` — optional shared snippets that get `COPY`ed into multiple images.
- `.github/workflows/build.yml` — matrix build, signs with cosign keyless.
- `renovate.json` — pins base image digests, tracks AlmaLinux + Actions updates.

## Stack and key decisions

- **Base image:** `quay.io/almalinuxorg/almalinux-bootc:10`, digest-pinned by
  Renovate. Don't update the digest by hand — let Renovate PR it.
- **Registry:** GitHub Container Registry (ghcr.io). Repo is public, packages
  are public, cosign signs via Sigstore keyless. No registry creds in CI.
- **Container engine on hosts:** Podman with Quadlet for systemd integration.
  Do NOT add Docker to images unless there's a specific reason — see "Things
  not to do."
- **First-boot config:** cloud-init. Both `cloud-init` and `cloud-utils-growpart`
  are baked in. Hosts get a NoCloud seed ISO (or cloud platform metadata)
  with user-data that creates users, SSH keys, hostname.
- **Updates on hosts:** `bootc-fetch-apply-updates.timer` is enabled in images,
  so hosts auto-pull and stage. Reboot completes the upgrade.

## How upgrades actually behave

This is the most important section because it's the part that surprises people.

- **`/usr/` is image-controlled, read-only, atomic.** New image → new `/usr`.
  Always. No drift possible.
- **`/etc/` uses a three-way merge.** OSTree compares: old image's `/etc`,
  new image's `/etc`, current `/etc`. If a file was modified locally, the
  local version wins **silently** — the image's update is dropped on the floor.
  This means a change to `/etc/foo.conf` in the Containerfile may not reach
  hosts where someone has touched that file. Audit with
  `sudo ostree admin config-diff`. The "diff" includes metadata (uid/gid/mode/
  xattrs), so a chmod alone makes a file "locally modified."
- **`/var/` is persistent and machine-local.** Image changes to `/var` content
  apply only on fresh installs, never on upgrades. Don't put baseline data
  in `/var/` via the Containerfile and expect it to update.

Rule of thumb: anything you want guaranteed-applied on every host, put it
under `/usr/lib/` (most tools support drop-ins there — systemd, sysctl,
modprobe, udev, tmpfiles.d, sysusers.d). Reserve `/etc/` for genuinely
host-specific state.

## Patterns to follow

### Adding a package
```dockerfile
RUN dnf install -y  && dnf clean all && rm -rf /var/cache/dnf
```
Always clean up the dnf cache in the same RUN to keep the layer small.

### Enabling a service
Image-time:
```dockerfile
RUN systemctl enable foo.service
```

### Configuring a service
Prefer drop-ins under `/usr/lib/` over editing files in `/etc/`:
- systemd: `/usr/lib/systemd/system/foo.service.d/override.conf`
- sshd: `/etc/ssh/sshd_config.d/00-mine.conf` (sshd doesn't read
  `/usr/lib/ssh/sshd_config.d`; live with the `/etc/` location, but
  ship it via the image and don't edit on hosts)
- sysctl: `/usr/lib/sysctl.d/99-mine.conf`
- tmpfiles.d / sysusers.d: `/usr/lib/...` always

### Running an app container
Use Quadlet, not `podman run` or compose:
```ini
# /etc/containers/systemd/myapp.container
[Container]
Image=docker.io/example/myapp:latest
PublishPort=8080:8080
Volume=/var/lib/myapp:/data:Z
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```
Ship the Quadlet file in the image (under `/etc/containers/systemd/` — yes,
this is one of the `/etc/` exceptions). For per-host apps, put them in
cloud-init's `write_files`.

### Secrets
Never bake them into the image. For a single host, put them in cloud-init
user-data and write to `/etc/<app>/credentials` with mode 0600. For a fleet,
use SOPS + age in a separate `secrets` repo, with per-host keys.

### Build-time validation
Every Containerfile should end with:
```dockerfile
RUN bootc container lint
```
This catches common mistakes (writes to `/var` that should be `/usr`,
missing kernel, etc).

## Things not to do

- **Don't `rpm-ostree install` anything on a running host.** It works, but
  the moment you do, `bootc upgrade` will refuse to proceed on that host
  because it doesn't understand the local mutation. You're in
  rpm-ostree-managed-land permanently until you reset.
- **Don't `dnf install` at runtime on hosts.** It won't survive upgrade and
  isn't the model. If you need a package, add it to the Containerfile.
- **Don't put secrets in the image.** Public registry, world-readable,
  forever in image history.
- **Don't put per-host config in the image** (hostnames, IPs, SSH keys,
  API tokens). That's cloud-init territory.
- **Don't add Docker** unless compose-file compatibility is unavoidable.
  Podman + Quadlet is the path; it integrates cleanly with bootc auto-update.
- **Don't update base image digests by hand.** Renovate handles it. Editing
  by hand means you might miss the digest change on the next AlmaLinux rebuild.
- **Don't write to `/var` from the Containerfile** with the expectation that
  it'll update on hosts. Use `/usr/share/<app>/` for canonical data and a
  systemd unit or tmpfiles entry to sync to `/var/` at boot.

## Common commands

On a host:
```bash
sudo bootc status                # current deployment, available image
sudo bootc upgrade               # pull latest, stage for next reboot
sudo bootc rollback              # boot previous deployment on next reboot
sudo ostree admin config-diff    # what's been locally modified in /etc
journalctl -u bootc-fetch-apply-updates  # auto-update logs
```

Local builds and testing:
```bash
# Build an image locally
podman build -t localhost/test:dev -f images//Containerfile .

# Convert a built image to a bootable qcow2 for VM testing
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --local --type qcow2 \
  localhost/test:dev
```

## When in doubt

Working principles, in order:

1. The Containerfile is the source of truth for what's in the OS. If the
   answer is "edit a file on the running host," that's usually wrong.
2. State that varies per host goes through cloud-init or `/var/`.
3. State that's the same on every host goes in the image, under `/usr/lib/`
   wherever the tool allows it.
4. If you can't decide whether something belongs in the image or in cloud-init,
   ask: "do I want every host to get this when I change it?" Yes → image.
   No → cloud-init.

## Useful references

- AlmaLinux bootc images: https://github.com/AlmaLinux/bootc-images
- bootc docs: https://bootc-dev.github.io/bootc/
- bootc-image-builder: https://github.com/osbuild/bootc-image-builder
- Quadlet: `man podman-systemd.unit`
- The 3-way merge explainer: https://developers.redhat.com/articles/2025/08/25/what-image-mode-3-way-merge
