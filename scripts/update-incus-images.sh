#!/usr/bin/env bash
set -euo pipefail

PROJECT="${INCUS_PROJECT:-garm-runners}"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/Lochnair/garm-runner-images/releases/latest/download/manifest.json}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-${MANIFEST_URL%/manifest.json}}"
STATE_DIR="${STATE_DIR:-/var/lib/garm-runner-images}"

mkdir -p "$STATE_DIR"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

manifest_file="$tmpdir/manifest.json"

curl -fsSL --retry 5 --retry-delay 2 "$MANIFEST_URL" -o "$manifest_file"

manifest_rows="$(
  python3 - "$manifest_file" <<'PY'
import json
import re
import sys
from pathlib import Path

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("schema_version") != 1:
    raise SystemExit("unsupported manifest schema")

images = manifest.get("images")
if not isinstance(images, list) or not images:
    raise SystemExit("manifest contains no images")

safe_name = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
seen_ids = set()
seen_assets = set()
reserved_aliases = set()

for image in images:
    image_id = image.get("id")
    asset = image.get("asset")
    checksum = image.get("sha256")
    alias = image.get("alias")

    if not all(isinstance(value, str) and value for value in (image_id, asset, checksum, alias)):
        raise SystemExit("manifest contains an invalid image entry")
    if not safe_name.fullmatch(image_id):
        raise SystemExit(f"unsafe image id: {image_id!r}")
    if not safe_name.fullmatch(asset) or Path(asset).name != asset or not asset.endswith(".tar.xz"):
        raise SystemExit(f"unsafe image asset: {asset!r}")
    if not safe_name.fullmatch(alias):
        raise SystemExit(f"unsafe image alias: {alias!r}")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", checksum):
        raise SystemExit(f"invalid checksum for {image_id}")
    if image_id in seen_ids or asset in seen_assets:
        raise SystemExit("manifest contains duplicate ids or assets")

    aliases = (alias, f"{alias}-previous", f"{alias}-staging")
    if any(candidate in reserved_aliases for candidate in aliases):
        raise SystemExit(f"manifest alias namespace collision for {alias}")

    seen_ids.add(image_id)
    seen_assets.add(asset)
    reserved_aliases.update(aliases)

    print("\t".join((image_id, asset, checksum.lower(), alias)))
PY
)"

alias_fingerprint() {
  local alias="$1"

  incus image alias list \
    --project "$PROJECT" \
    --format csv,noheader \
    --columns af |
    awk -F, -v alias="$alias" '$1 == alias { print $2; exit }'
}

update_image() {
  local image_id="$1"
  local asset="$2"
  local remote_sha="$3"
  local current_alias="$4"
  local previous_alias="${current_alias}-previous"
  local staging_alias="${current_alias}-staging"
  local state_file="$STATE_DIR/${image_id}.sha256"
  local image_file="$tmpdir/$asset"
  local image_url="$RELEASE_BASE_URL/$asset"

  if [[ -f "$state_file" ]]; then
    local state_sha=""
    local state_alias=""
    IFS=$'\t' read -r state_sha state_alias < "$state_file" || true

    if [[ "$state_sha" == "$remote_sha" && "$state_alias" == "$current_alias" ]]; then
      echo "$image_id is already current ($remote_sha)"
      return
    fi
  fi

  curl -fL --retry 5 --retry-delay 2 "$image_url" -o "$image_file"

  local actual_sha
  actual_sha="$(sha256sum "$image_file" | awk '{print $1}')"
  if [[ "${actual_sha,,}" != "$remote_sha" ]]; then
    echo "Checksum mismatch for $image_url" >&2
    echo "Expected: $remote_sha" >&2
    echo "Actual:   $actual_sha" >&2
    return 1
  fi

  if [[ -n "$(alias_fingerprint "$staging_alias")" ]]; then
    incus image alias delete --project "$PROJECT" "$staging_alias"
  fi

  incus image import \
    --project "$PROJECT" \
    --alias "$staging_alias" \
    "$image_file" \
    user.garm-runner=true \
    user.garm-runner.image="$image_id" \
    source.url="$image_url"

  local new_fingerprint
  local current_fingerprint
  local previous_fingerprint

  new_fingerprint="$(alias_fingerprint "$staging_alias")"
  if [[ -z "$new_fingerprint" ]]; then
    echo "Could not determine imported image fingerprint for $image_id" >&2
    return 1
  fi

  current_fingerprint="$(alias_fingerprint "$current_alias")"
  previous_fingerprint="$(alias_fingerprint "$previous_alias")"

  if [[ "$new_fingerprint" != "$current_fingerprint" ]]; then
    if [[ -n "$previous_fingerprint" ]]; then
      incus image alias delete --project "$PROJECT" "$previous_alias"
    fi

    if [[ -n "$current_fingerprint" ]]; then
      incus image alias delete --project "$PROJECT" "$current_alias"
      incus image alias create --project "$PROJECT" "$previous_alias" "$current_fingerprint"
    fi

    if ! incus image alias create --project "$PROJECT" "$current_alias" "$new_fingerprint"; then
      if [[ -n "$current_fingerprint" ]]; then
        incus image alias create --project "$PROJECT" "$current_alias" "$current_fingerprint" || true
      fi
      return 1
    fi
  fi

  incus image alias delete --project "$PROJECT" "$staging_alias"

  current_fingerprint="$(alias_fingerprint "$current_alias")"
  previous_fingerprint="$(alias_fingerprint "$previous_alias")"

  local managed_images
  managed_images="$(
    incus image list \
      --project "$PROJECT" \
      "user.garm-runner.image=$image_id" \
      --format csv,noheader \
      --columns f
  )"

  while IFS= read -r fingerprint; do
    [[ -z "$fingerprint" ]] && continue
    [[ "$fingerprint" == "$current_fingerprint" ]] && continue
    [[ -n "$previous_fingerprint" && "$fingerprint" == "$previous_fingerprint" ]] && continue

    incus image delete --project "$PROJECT" "$fingerprint"
  done <<< "$managed_images"

  printf '%s\t%s\n' "$remote_sha" "$current_alias" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  echo "$image_id now points to $current_fingerprint"
  if [[ -n "$previous_fingerprint" ]]; then
    echo "$previous_alias points to $previous_fingerprint"
  fi
}

while IFS=$'\t' read -r image_id asset checksum alias; do
  [[ -z "$image_id" ]] && continue
  update_image "$image_id" "$asset" "$checksum" "$alias"
done <<< "$manifest_rows"
