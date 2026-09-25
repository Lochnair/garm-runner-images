#!/usr/bin/env bash
set -euo pipefail

PROJECT="${INCUS_PROJECT:-garm-runners}"
CURRENT_ALIAS="${CURRENT_ALIAS:-garm-runner-current}"
PREVIOUS_ALIAS="${PREVIOUS_ALIAS:-garm-runner-previous}"
STAGING_ALIAS="${STAGING_ALIAS:-garm-runner-staging}"
IMAGE_URL="${IMAGE_URL:-https://github.com/Lochnair/garm-runner-images/releases/latest/download/garm-runner-incus.tar.xz}"
CHECKSUM_URL="${CHECKSUM_URL:-${IMAGE_URL}.sha256}"
STATE_DIR="${STATE_DIR:-/var/lib/garm-runner-image}"

mkdir -p "$STATE_DIR"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

checksum_file="$tmpdir/garm-runner-incus.tar.xz.sha256"
image_file="$tmpdir/garm-runner-incus.tar.xz"
state_file="$STATE_DIR/sha256"

curl -fsSL --retry 5 --retry-delay 2 "$CHECKSUM_URL" -o "$checksum_file"
remote_sha="$(awk 'NF {print $1; exit}' "$checksum_file")"

if [[ ! "$remote_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Invalid checksum from $CHECKSUM_URL" >&2
  exit 1
fi

if [[ -f "$state_file" ]] && [[ "$(cat "$state_file")" == "$remote_sha" ]]; then
  echo "GARM runner image is already current ($remote_sha)"
  exit 0
fi

curl -fL --retry 5 --retry-delay 2 "$IMAGE_URL" -o "$image_file"

(
  cd "$tmpdir"
  sha256sum -c "$(basename "$checksum_file")"
)

alias_fingerprint() {
  local alias="$1"

  incus image alias list \
    --project "$PROJECT" \
    --format csv,noheader \
    --columns af |
    awk -F, -v alias="$alias" '$1 == alias { print $2; exit }'
}

if [[ -n "$(alias_fingerprint "$STAGING_ALIAS")" ]]; then
  incus image alias delete --project "$PROJECT" "$STAGING_ALIAS"
fi

incus image import \
  --project "$PROJECT" \
  --alias "$STAGING_ALIAS" \
  "$image_file" \
  user.garm-runner=true \
  source.url="$IMAGE_URL"

new_fingerprint="$(alias_fingerprint "$STAGING_ALIAS")"
if [[ -z "$new_fingerprint" ]]; then
  echo "Could not determine imported image fingerprint" >&2
  exit 1
fi

current_fingerprint="$(alias_fingerprint "$CURRENT_ALIAS")"
previous_fingerprint="$(alias_fingerprint "$PREVIOUS_ALIAS")"

if [[ "$new_fingerprint" != "$current_fingerprint" ]]; then
  if [[ -n "$previous_fingerprint" ]]; then
    incus image alias delete --project "$PROJECT" "$PREVIOUS_ALIAS"
  fi

  if [[ -n "$current_fingerprint" ]]; then
    incus image alias delete --project "$PROJECT" "$CURRENT_ALIAS"
    incus image alias create --project "$PROJECT" "$PREVIOUS_ALIAS" "$current_fingerprint"
  fi

  if ! incus image alias create --project "$PROJECT" "$CURRENT_ALIAS" "$new_fingerprint"; then
    if [[ -n "$current_fingerprint" ]]; then
      incus image alias create --project "$PROJECT" "$CURRENT_ALIAS" "$current_fingerprint" || true
    fi
    exit 1
  fi
fi

incus image alias delete --project "$PROJECT" "$STAGING_ALIAS"

printf '%s\n' "$remote_sha" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

# Re-read the final alias targets after any rotation. These are the only two
# managed images that should survive pruning.
current_fingerprint="$(alias_fingerprint "$CURRENT_ALIAS")"
previous_fingerprint="$(alias_fingerprint "$PREVIOUS_ALIAS")"

while IFS= read -r fingerprint; do
  [[ -z "$fingerprint" ]] && continue
  [[ "$fingerprint" == "$current_fingerprint" ]] && continue
  [[ -n "$previous_fingerprint" && "$fingerprint" == "$previous_fingerprint" ]] && continue

  incus image delete --project "$PROJECT" "$fingerprint"
done < <(
  incus image list \
    --project "$PROJECT" \
    user.garm-runner=true \
    --format csv,noheader \
    --columns f
)

echo "GARM runner image now points to $current_fingerprint"
if [[ -n "$previous_fingerprint" ]]; then
  echo "Rollback alias $PREVIOUS_ALIAS points to $previous_fingerprint"
fi
