# garm-runner-images

Prebuilt Incus container images for the GARM runners on TheBeast.

The images are generated artifacts rather than long-lived machines. GitHub Actions rebuilds the full image set every Sunday and whenever an image definition, updater, or workflow changes on `main`. Toolchains are baked into the images so ephemeral GARM runners do not spend their startup time upgrading the OS and reinstalling the same development packages.

## Image set

`images/catalog.json` is the source of truth for the image set, release assets, and stable Incus aliases.

| Gitea label | Image definition | Incus alias |
| --- | --- | --- |
| `ubuntu-latest`, `ubuntu-26.04` | `images/ubuntu-26.04.yaml` | `garm-runner-ubuntu-26.04` |
| `ubuntu-24.04` | `images/ubuntu-24.04.yaml` | `garm-runner-ubuntu-24.04` |
| `archlinux` | `images/archlinux.yaml` | `garm-runner-archlinux` |
| `almalinux-10` | `images/almalinux-10.yaml` | `garm-runner-almalinux-10` |

Each definition uses distro-native package names while providing the same broad runner capabilities where the distribution supports them: C/C++ build tools, LLVM/Clang, Rust, Go, Node.js, Python, Git, Docker/buildx/Compose, and common networking/debugging tools.

Alpine is intentionally not part of this image set yet. GARM's stock Gitea Linux installer assumes systemd, while a normal Alpine runner uses OpenRC.

## Published release

Pull requests build all images and upload short-lived Actions artifacts but do not publish a release.

Successful non-PR builds wait for the complete matrix, generate `manifest.json`, then create a draft release containing the entire image set. The release is published and marked latest only after every image and the manifest have been uploaded successfully.

The stable manifest URL is:

```text
https://github.com/Lochnair/garm-runner-images/releases/latest/download/manifest.json
```

The manifest contains the asset name, SHA-256 checksum, and stable Incus alias for every image. The updater consumes this manifest, so adding or removing a distro does not require another local updater configuration.

## Install the updater on TheBeast

```bash
sudo install -m 0755 scripts/update-incus-images.sh /usr/local/sbin/update-garm-runner-images
sudo install -m 0644 systemd/garm-runner-image-update.service /etc/systemd/system/
sudo install -m 0644 systemd/garm-runner-image-update.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now garm-runner-image-update.timer

# Initial import now rather than waiting for the timer.
sudo systemctl start garm-runner-image-update.service
```

Defaults:

```text
Incus project: garm-runners
manifest:      GitHub latest release
state:         /var/lib/garm-runner-images
```

These can be overridden with `INCUS_PROJECT`, `MANIFEST_URL`, `RELEASE_BASE_URL`, or `STATE_DIR`.

For each image, the updater:

1. verifies the downloaded asset against the manifest checksum;
2. imports it under a staging alias;
3. rotates the stable alias to `<alias>-previous`;
4. removes older managed copies for that distro;
5. records completion only after rotation and cleanup succeed.

A failed image therefore remains retryable on the next timer run without disturbing images that already completed successfully.

## GARM pools

After the images are imported, point the four GARM pools at their aliases from the table above and set the Incus provider extra specs to disable boot-time package updates:

```json
{"disable_updates": true}
```

Remove the old `extra_packages` list because those packages are baked into the images.

The existing single-image aliases from the first version of this repository are not reused. Once the Ubuntu 26.04 pool has been switched to `garm-runner-ubuntu-26.04` and is working, the old `garm-runner-current` / `garm-runner-previous` aliases and their old managed images can be removed manually.

## Rollback

Every distro keeps one previous image. For example, to roll Ubuntu 26.04 back:

```bash
PROJECT=garm-runners
CURRENT=garm-runner-ubuntu-26.04
PREVIOUS="${CURRENT}-previous"

OLD="$(
  incus image alias list --project "$PROJECT" --format csv,noheader --columns af |
    awk -F, -v alias="$PREVIOUS" '$1 == alias { print $2; exit }'
)"

test -n "$OLD"
incus image alias delete --project "$PROJECT" "$CURRENT"
incus image alias create --project "$PROJECT" "$CURRENT" "$OLD"
```

The state file makes a manual rollback sticky until a newer image is published. To force the currently published image to be reapplied, remove only that distro's state file, for example:

```bash
sudo rm /var/lib/garm-runner-images/ubuntu-26.04.sha256
sudo systemctl start garm-runner-image-update.service
```

GARM remains the only runner lifecycle manager. This repository only builds and maintains the local Incus images that its pools launch.
