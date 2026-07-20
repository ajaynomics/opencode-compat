#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${OPENCODE_IMAGE:-}"
gem_path="${OPENCODE_RUBY_PATH:-}"
expected_gem_commit="${OPENCODE_RUBY_COMMIT:-}"
evidence_path="${OPENCODE_COMPAT_EVIDENCE_PATH:-}"
probe_host="${OPENCODE_PROBE_HOST:-127.0.0.1}"
container_name="opencode-compat-${RANDOM}-$$"
llm_container_name="opencode-compat-llm-${RANDOM}-$$"
network_name="opencode-compat-net-${RANDOM}-$$"
python_image="python@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0"
network_created=0
llm_container_started=0
opencode_container_started=0
gem_commit=""

write_failure_evidence() {
  local exit_status="$1"
  [[ -n "$evidence_path" ]] || return 0

  mkdir -p "$(dirname "$evidence_path")"
  jq -n \
    --argjson schema_version 1 \
    --arg kind shared-client-image-contract \
    --arg status fail \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg matrix_target "${OPENCODE_MATRIX_ID:-local}" \
    --arg image "$image" \
    --arg ruby_commit "${gem_commit:-}" \
    --arg rails_commit "${OPENCODE_RAILS_COMMIT:-}" \
    --arg run_id "${OPENCODE_COMPAT_RUN_ID:-}" \
    --arg run_attempt "${OPENCODE_COMPAT_RUN_ATTEMPT:-}" \
    --arg head_sha "${OPENCODE_COMPAT_HEAD_SHA:-}" \
    --arg repository "${OPENCODE_COMPAT_REPOSITORY:-}" \
    --arg run_url "${OPENCODE_COMPAT_RUN_URL:-}" \
    --argjson exit_status "$exit_status" \
    '{
      schema_version:$schema_version,
      kind:$kind,
      status:$status,
      checked_at:$checked_at,
      matrix_target:$matrix_target,
      certification_scope:"shared-client-contract-only",
      executed_profiles:[],
      image:{requested:$image},
      clients:{opencode_ruby:{commit:$ruby_commit},opencode_rails:{commit:$rails_commit,executed:false}},
      failure:{exit_status:$exit_status},
      workflow:{run_id:$run_id,run_attempt:$run_attempt,head_sha:$head_sha,repository:$repository,run_url:$run_url}
    }' >"$evidence_path"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" != "0" ]]; then
    echo "OpenCode compatibility probe failed; container log follows" >&2
    if [[ "$opencode_container_started" == "1" ]]; then
      docker logs "$container_name" >&2 2>/dev/null || true
    fi
    echo "Deterministic model request summary follows" >&2
    if [[ "$llm_container_started" == "1" ]]; then
      docker exec "$llm_container_name" wget -qO- http://127.0.0.1:8080/stats >&2 2>/dev/null || true
    fi
    echo >&2
    write_failure_evidence "$status" || true
  fi
  if [[ "$opencode_container_started" == "1" ]]; then
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  if [[ "$llm_container_started" == "1" ]]; then
    docker rm -f "$llm_container_name" >/dev/null 2>&1 || true
  fi
  if [[ "$network_created" == "1" ]]; then
    docker network rm "$network_name" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ -n "$evidence_path" ]]; then
  mkdir -p "$(dirname "$evidence_path")"
  : >"$evidence_path"
fi

if [[ -z "$image" ]]; then
  echo "set OPENCODE_IMAGE to an immutable image digest" >&2
  exit 2
fi
if [[ -z "$gem_path" ]]; then
  echo "set OPENCODE_RUBY_PATH to the candidate checkout" >&2
  exit 2
fi
if [[ ! "$image" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  if [[ "${ALLOW_EXACT_IMAGE_ID:-0}" != "1" || ! "$image" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "OPENCODE_IMAGE must be an OCI digest (or an exact local image ID with ALLOW_EXACT_IMAGE_ID=1)" >&2
    exit 2
  fi
fi
if ! ruby -ripaddr -e '
  begin
    address = IPAddr.new(ARGV.fetch(0))
    valid = address.ipv4? && (address.loopback? || address.private?)
  rescue IPAddr::InvalidAddressError
    valid = false
  end
  exit(valid ? 0 : 1)
' "$probe_host"; then
  echo "OPENCODE_PROBE_HOST must be a loopback or private IPv4 address" >&2
  exit 2
fi

if [[ ! "$expected_gem_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "OPENCODE_RUBY_COMMIT must be a full lowercase 40-character Git commit" >&2
  exit 2
fi
if ! gem_commit="$(git -C "$gem_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
  echo "OPENCODE_RUBY_PATH must be a readable Git checkout" >&2
  exit 2
fi
if [[ "$gem_commit" != "$expected_gem_commit" ]]; then
  echo "opencode-ruby checkout HEAD $gem_commit does not match expected commit $expected_gem_commit" >&2
  exit 2
fi
if [[ -n "$(git -C "$gem_path" status --porcelain --untracked-files=all)" ]]; then
  echo "opencode-ruby checkout must be clean before certification" >&2
  exit 2
fi

docker network create "$network_name" >/dev/null
network_created=1
docker run --detach \
  --name "$llm_container_name" \
  --network "$network_name" \
  --network-alias compat-llm \
  "$python_image" \
  python -c 'import time; time.sleep(3600)' \
  >/dev/null
llm_container_started=1
docker cp "$repo_root/scripts/fake_llm.py" "$llm_container_name:/tmp/fake_llm.py"
docker exec --detach \
  "$llm_container_name" \
  python /tmp/fake_llm.py --port 8080 --port-file /tmp/compat-port

for _ in $(seq 1 100); do
  if docker exec "$llm_container_name" wget -qO- http://127.0.0.1:8080/health >/dev/null 2>&1; then
    llm_ready=1
    break
  fi
  sleep 0.05
done
[[ "${llm_ready:-0}" == "1" ]] || { echo "fake LLM did not start" >&2; exit 1; }

config_json="$(jq -cn --arg url "http://compat-llm:8080/v1" '{
  "$schema": "https://opencode.ai/config.json",
  formatter: false,
  lsp: false,
  provider: {
    compat: {
      name: "Compatibility fixture",
      id: "compat",
      env: [],
      npm: "@ai-sdk/openai-compatible",
      models: {
        "compat-model": {
          id: "compat-model",
          name: "Compatibility model",
          attachment: false,
          reasoning: false,
          temperature: false,
          tool_call: true,
          release_date: "2026-01-01",
          limit: {context: 100000, output: 10000},
          cost: {input: 0, output: 0},
          options: {}
        }
      },
      options: {apiKey: "compat-key", baseURL: $url}
    }
  }
}')"

docker run --detach \
  --name "$container_name" \
  --network "$network_name" \
  --publish "${probe_host}::4096" \
  --env "OPENCODE_CONFIG_CONTENT=$config_json" \
  --env OPENCODE_DISABLE_AUTOUPDATE=1 \
  --env OPENCODE_DISABLE_AUTOCOMPACT=1 \
  --env OPENCODE_DISABLE_MODELS_FETCH=1 \
  --env OPENCODE_DISABLE_PROJECT_CONFIG=1 \
  --env OPENCODE_PURE=1 \
  "$image" serve --hostname 0.0.0.0 --port 4096 \
  >/dev/null
opencode_container_started=1

host_port="$(docker port "$container_name" 4096/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -1)"
base_url="http://${probe_host}:${host_port}"

ready=0
for _ in $(seq 1 120); do
  if curl --fail --silent --connect-timeout 1 --max-time 2 "$base_url/global/health" >/dev/null; then
    ready=1
    break
  fi
  if ! docker inspect "$container_name" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
    docker logs "$container_name" >&2 || true
    exit 1
  fi
  sleep 0.25
done

if [[ "$ready" != "1" ]]; then
  docker logs "$container_name" >&2 || true
  echo "OpenCode did not become ready" >&2
  exit 1
fi

server_version="$(docker exec "$container_name" opencode --version)"
image_id="$(docker inspect "$container_name" --format '{{.Image}}')"
image_os="$(docker image inspect "$image_id" --format '{{.Os}}')"
image_architecture="$(docker image inspect "$image_id" --format '{{.Architecture}}')"
image_platform="${image_os}/${image_architecture}"
expected_version="${OPENCODE_EXPECTED_VERSION:-}"

if [[ -n "$expected_version" && "$server_version" != "$expected_version" ]]; then
  echo "OpenCode reported version $server_version; expected $expected_version" >&2
  exit 1
fi

live_contract="$(
  OPENCODE_BASE_URL="$base_url" \
  OPENCODE_RUBY_PATH="$gem_path" \
  OPENCODE_RUBY_COMMIT="$gem_commit" \
    ruby "$repo_root/ruby/live_probe.rb"
)"
printf '%s\n' "$live_contract"

llm_stats="$(docker exec "$llm_container_name" wget -qO- http://127.0.0.1:8080/stats)"
request_count="$(jq -r '.request_count' <<<"$llm_stats")"
ruby "$repo_root/ruby/exact_live_contract.rb" "$request_count"

evidence="$(jq -cn \
  --argjson schema_version 1 \
  --arg status pass \
  --arg kind shared-client-image-contract \
  --arg matrix_target "${OPENCODE_MATRIX_ID:-local}" \
  --arg certification_scope "shared-client-contract-only" \
  --argjson executed_profiles '["ruby-rest-sse"]' \
  --argjson required_consumer_profiles "${OPENCODE_REQUIRED_CONSUMER_PROFILES:-[]}" \
  --arg image "$image" \
  --arg image_id "$image_id" \
  --arg image_platform "$image_platform" \
  --arg server_version "$server_version" \
  --arg gem_commit "$gem_commit" \
  --arg companion_rails_commit "${OPENCODE_RAILS_COMMIT:-}" \
  --arg run_id "${OPENCODE_COMPAT_RUN_ID:-}" \
  --arg run_attempt "${OPENCODE_COMPAT_RUN_ATTEMPT:-}" \
  --arg head_sha "${OPENCODE_COMPAT_HEAD_SHA:-}" \
  --arg repository "${OPENCODE_COMPAT_REPOSITORY:-}" \
  --arg run_url "${OPENCODE_COMPAT_RUN_URL:-}" \
  --argjson live_contract "$live_contract" \
  --argjson llm_request_count "$request_count" \
  '{
    schema_version:$schema_version,
    kind:$kind,
    status:$status,
    checked_at:$live_contract.checked_at,
    matrix_target:$matrix_target,
    certification_scope:$certification_scope,
    executed_profiles:$executed_profiles,
    required_consumer_profiles:$required_consumer_profiles,
    image:{requested:$image,docker_image_id:$image_id,platform:$image_platform,reported_version:$server_version},
    clients:{
      opencode_ruby:{version:$live_contract.opencode_ruby_version,commit:$gem_commit,executed:true},
      opencode_rails:{commit:$companion_rails_commit,executed:false}
    },
    contract:{
      expected_text:$live_contract.expected_text,
      full_text:$live_contract.full_text,
      observed_part_count:$live_contract.observed_part_count,
      authoritative_assistant_message_count:$live_contract.authoritative_assistant_message_count,
      llm_request_count:$llm_request_count
    },
    workflow:{run_id:$run_id,run_attempt:$run_attempt,head_sha:$head_sha,repository:$repository,run_url:$run_url}
  }'
)"
printf '%s\n' "$evidence"

if [[ -n "$evidence_path" ]]; then
  printf '%s\n' "$evidence" >"$evidence_path"
fi
