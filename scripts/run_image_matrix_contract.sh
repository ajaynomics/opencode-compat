#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence_dir="${OPENCODE_COMPAT_EVIDENCE_DIR:-$repo_root/.compat-evidence}"
matrix_json="$(ruby "$repo_root/scripts/matrix_json.rb")"
entry_count="$(jq -er '.include | length' <<<"$matrix_json")"

if [[ ! "$entry_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "exact image matrix must contain at least one entry" >&2
  exit 2
fi

mkdir -p "$evidence_dir"

for ((index = 0; index < entry_count; index++)); do
  entry="$(jq -ec --argjson index "$index" '.include[$index]' <<<"$matrix_json")"
  matrix_id="$(jq -er '.id' <<<"$entry")"
  image="$(jq -er '.image' <<<"$entry")"
  expected_version="$(jq -er '.version' <<<"$entry")"
  required_profiles="$(jq -ec '.required_consumer_profiles' <<<"$entry")"
  evidence_path="$evidence_dir/$matrix_id.json"

  printf 'Running exact image matrix entry %s (%s)\n' "$matrix_id" "$image"
  OPENCODE_IMAGE="$image" \
  OPENCODE_EXPECTED_VERSION="$expected_version" \
  OPENCODE_MATRIX_ID="$matrix_id" \
  OPENCODE_REQUIRED_CONSUMER_PROFILES="$required_profiles" \
  OPENCODE_COMPAT_EVIDENCE_PATH="$evidence_path" \
    bundle exec "$repo_root/scripts/run_image_contract.sh"

  jq -e \
    --arg matrix_id "$matrix_id" \
    --arg image "$image" \
    --arg version "$expected_version" \
    '.status == "pass" and
      .matrix_target == $matrix_id and
      .image.requested == $image and
      .image.reported_version == $version' \
    "$evidence_path" >/dev/null
  printf 'Exact image matrix entry %s passed; JSON remains transient on this forge.\n' "$matrix_id"
done

printf 'Full exact image matrix passed (%s entries).\n' "$entry_count"
