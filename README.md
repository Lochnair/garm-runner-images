# garm-runner-images

Prebuilt Incus container image for the GARM runners on TheBeast.

The image is intentionally treated as a generated artifact rather than a long-lived machine:

- GitHub Actions rebuilds it every Sunday and whenever the image definition changes on `main`.
- The build starts from Ubuntu Resolute and runs a full package upgrade before installing the runner toolchain.
- Packages that were previously installed by GARM/cloud-init are baked into the image.
- GARM can therefore use `disable_updates: true` and avoid doing an `apt upgrade` plus a large package install for every ephemeral runner.
- Each successful non-PR build is published as its own GitHub release. The `latest` release URL remains stable for TheBeast.

## Image contents

`image.yaml` is the source of truth for the image. It currently includes the general-purpose toolchain used by the Gitea/GARM runners: C/C++, LLVM/Clang, Rust, Go, Node.js, Python, Docker/buildx/Compose, Git, shellcheck and the networking/debugging utilities from the previous runner bootstrap.

The image includes cloud-init and is built as an Incus **container** image. Nested Docker is expected to be enabled by the Incus project/profile used for GARM.

## Published image

Pull requests build and upload the image as a short-lived Actions artifact, but do not publish a release.

Successful non-PR builds first create a **draft** release and upload both files:

- `garm-runner-incus.tar.xz`
- `garm-runner-incus.tar.xz.sha256`

Only after both uploads succeed is the release published and marked as the latest release. That keeps the stable download URL on the previous known-good pair if a build or upload fails.

The stable download URL is:

```text
https://github.com/Lochnair/garm-runner-images/releases/latest/download/garm-runner-incus.tar.xz
```

## Install the updater on TheBeast

The updater imports a new image only when the published checksum changes, moves the old current image to `garm-runner-previous`, and keeps only the current and previous managed images.

```bash
sudo install -m 0755 scripts/update-incus-image.sh /usr/local/sbin/update-garm-runner-image
sudo install -m 0644 systemd/garm-runner-image-update.service /etc/systemd/system/
sudo install -m 0644 systemd/garm-runner-image-update.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now garm-runner-image-update.timer

# Initial import now rather than waiting for the timer.
sudo systemctl start garm-runner-image-update.service
```

The defaults match the current Incus setup:

```text
project:        garm-runners
current alias:  garm-runner-current
previous alias: garm-runner-previous
```

They can be overridden with `INCUS_PROJECT`, `CURRENT_ALIAS`, `PREVIOUS_ALIAS`, `STAGING_ALIAS`, `IMAGE_URL`, `CHECKSUM_URL`, or `STATE_DIR`.

Once the first image is imported, point the GARM container pool at the local image alias:

```text
garm-runner-current
```

Set the pool's Incus provider extra specs to disable boot-time package updates:

```json
{"disable_updates": true}
```

The old `extra_packages` list should be removed from the pool because those packages are now part of the image.

## Rollback

The updater retains one previous image as `garm-runner-previous`. To roll back:

```bash
PROJECT=garm-runners
OLD="$(
  incus image alias list --project "$PROJECT" --format csv,noheader --columns af |
    awk -F, '$1 == "garm-runner-previous" { print $2; exit }'
)"

test -n "$OLD"
incus image alias delete --project "$PROJECT" garm-runner-current
incus image alias create --project "$PROJECT" garm-runner-current "$OLD"
```

A manual rollback is intentionally sticky until a newer weekly image is published. To force the updater to reapply the currently published image, remove `/var/lib/garm-runner-image/sha256` and run the service again.

The updater does not modify GARM itself. GARM remains the only runner lifecycle manager; this repository only provides the local image alias that its Incus pool launches.
