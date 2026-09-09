#!/usr/bin/env bash
# Diffs installed RPM packages between old/new digests of any base image
# reference (FROM ...@sha256:...) that changed in a Containerfile between
# two git refs. Writes a Markdown summary to OUT_FILE.
set -euo pipefail

BASE_SHA="$1"
HEAD_SHA="$2"
OUT_FILE="${3:-base-image-diff.md}"

command -v podman >/dev/null || { sudo apt-get update && sudo apt-get install -y podman; }

: > "$OUT_FILE"

mapfile -t pairs < <(
  git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" -- 'images/**/Containerfile' \
    | grep -E '^[+-]FROM [a-zA-Z0-9./_-]+(:[a-zA-Z0-9._-]+)?@sha256:[0-9a-f]{64}' \
    | sed -E 's/^([+-])FROM ([a-zA-Z0-9./_-]+)(:[a-zA-Z0-9._-]+)?@(sha256:[0-9a-f]{64}).*/\1 \2 \4/' \
    | sort -u
)

declare -A OLD_DIGEST
declare -A NEW_DIGEST

for line in "${pairs[@]:-}"; do
  [[ -z "$line" ]] && continue
  sign=${line%% *}
  rest=${line#* }
  image=${rest%% *}
  digest=${rest#* }
  if [[ "$sign" == "-" ]]; then
    OLD_DIGEST["$image"]="$digest"
  else
    NEW_DIGEST["$image"]="$digest"
  fi
done

# Some base images (e.g. the rpi variant) are published as arm64-only
# manifest lists, with no amd64 entry at all. podman run defaults to the
# runner's native platform, which fails immediately with "no image found
# in image index" before QEMU emulation ever comes into play. Try amd64
# first (native, no emulation needed), and only fall back to arm64 -
# which the workflow's QEMU setup step lets us actually execute - when
# the failure is specifically a missing-platform one.
rpm_list() {
  local ref="$1" platform out
  for platform in linux/amd64 linux/arm64; do
    if out=$(podman run --rm --platform "$platform" --entrypoint '' "$ref" \
        rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 2>&1); then
      echo "$out" | sort
      return 0
    fi
    if ! grep -q 'no image found in image index' <<<"$out"; then
      echo "$out" >&2
      return 1
    fi
  done
  echo "no matching platform (amd64 or arm64) in manifest for $ref" >&2
  return 1
}

for image in "${!NEW_DIGEST[@]}"; do
  old="${OLD_DIGEST[$image]:-}"
  new="${NEW_DIGEST[$image]}"
  [[ -z "$old" || "$old" == "$new" ]] && continue

  echo "Diffing $image: $old -> $new" >&2

  {
    echo "### \`$image\`"
    echo
    echo "\`${old:0:19}\`... → \`${new:0:19}\`..."
    echo
  } >> "$OUT_FILE"

  # Handle failures per-image so one bad pull doesn't abort the whole run
  # (set -e would otherwise kill the script here and skip every image
  # that hadn't been processed yet).
  if ! old_pkgs=$(rpm_list "${image}@${old}"); then
    echo "_Could not inspect \`$image@$old\`; skipping this image._" >> "$OUT_FILE"
    echo >> "$OUT_FILE"
    continue
  fi
  if ! new_pkgs=$(rpm_list "${image}@${new}"); then
    echo "_Could not inspect \`$image@$new\`; skipping this image._" >> "$OUT_FILE"
    echo >> "$OUT_FILE"
    continue
  fi

  added=$(comm -13 <(awk '{print $1}' <<<"$old_pkgs") <(awk '{print $1}' <<<"$new_pkgs"))
  removed=$(comm -23 <(awk '{print $1}' <<<"$old_pkgs") <(awk '{print $1}' <<<"$new_pkgs"))

  changed=""
  while read -r name old_evr; do
    [[ -z "$name" ]] && continue
    new_evr=$(awk -v n="$name" '$1==n{print $2}' <<<"$new_pkgs")
    if [[ -n "$new_evr" && "$new_evr" != "$old_evr" ]]; then
      changed+="| $name | $old_evr | $new_evr |\n"
    fi
  done <<<"$old_pkgs"

  if [[ -n "$changed" ]]; then
    {
      echo "**Updated packages**"
      echo
      echo "| Package | Old | New |"
      echo "|---|---|---|"
      echo -e "$changed"
    } >> "$OUT_FILE"
  fi

  if [[ -n "$added" ]]; then
    {
      echo "**Added packages**: $(echo "$added" | paste -sd, -)"
      echo
    } >> "$OUT_FILE"
  fi

  if [[ -n "$removed" ]]; then
    {
      echo "**Removed packages**: $(echo "$removed" | paste -sd, -)"
      echo
    } >> "$OUT_FILE"
  fi

  if [[ -z "$changed" && -z "$added" && -z "$removed" ]]; then
    echo "_No package changes detected._" >> "$OUT_FILE"
    echo >> "$OUT_FILE"
  fi
done
