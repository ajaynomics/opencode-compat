#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${OPENCODE_IMAGE:?set OPENCODE_IMAGE to an immutable image digest}"
gem_path="${OPENCODE_RUBY_PATH:?set OPENCODE_RUBY_PATH to the candidate checkout}"

if [[ "$image" != *@sha256:* ]]; then
  if [[ "${ALLOW_EXACT_IMAGE_ID:-0}" != "1" || "$image" != sha256:* ]]; then
    echo "OPENCODE_IMAGE must be an OCI digest (or an exact local image ID with ALLOW_EXACT_IMAGE_ID=1)" >&2
    exit 2
  fi
fi

container_name="opencode-compat-${RANDOM}-$$"
llm_container_name="opencode-compat-llm-${RANDOM}-$$"
network_name="opencode-compat-net-${RANDOM}-$$"
python_image="python@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0"

cleanup() {
  status=$?
  if [[ "$status" != "0" ]]; then
    echo "OpenCode compatibility probe failed; container log follows" >&2
    docker logs "$container_name" >&2 2>/dev/null || true
    echo "Deterministic model request summary follows" >&2
    docker exec "$llm_container_name" wget -qO- http://127.0.0.1:8080/stats >&2 2>/dev/null || true
    echo >&2
  fi
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker rm -f "$llm_container_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  return "$status"
}
trap cleanup EXIT

docker network create "$network_name" >/dev/null
docker run --detach \
  --name "$llm_container_name" \
  --network "$network_name" \
  --network-alias compat-llm \
  --volume "$repo_root/scripts:/compat:ro" \
  "$python_image" \
  python /compat/fake_llm.py --port 8080 --port-file /tmp/compat-port \
  >/dev/null

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
  --publish 127.0.0.1::4096 \
  --env "OPENCODE_CONFIG_CONTENT=$config_json" \
  --env OPENCODE_DISABLE_AUTOUPDATE=1 \
  --env OPENCODE_DISABLE_AUTOCOMPACT=1 \
  --env OPENCODE_DISABLE_MODELS_FETCH=1 \
  --env OPENCODE_DISABLE_PROJECT_CONFIG=1 \
  --env OPENCODE_PURE=1 \
  "$image" serve --hostname 0.0.0.0 --port 4096 \
  >/dev/null

host_port="$(docker port "$container_name" 4096/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -1)"
base_url="http://127.0.0.1:${host_port}"

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
gem_commit="$(git -C "$gem_path" rev-parse HEAD 2>/dev/null || true)"

OPENCODE_BASE_URL="$base_url" \
OPENCODE_RUBY_PATH="$gem_path" \
OPENCODE_RUBY_COMMIT="$gem_commit" \
  ruby "$repo_root/ruby/live_probe.rb"

llm_stats="$(docker exec "$llm_container_name" wget -qO- http://127.0.0.1:8080/stats)"
request_count="$(jq -r '.request_count' <<<"$llm_stats")"
if [[ "$request_count" -lt 1 ]]; then
  echo "OpenCode never called the deterministic model" >&2
  exit 1
fi

jq -cn \
  --arg status pass \
  --arg image "$image" \
  --arg image_id "$image_id" \
  --arg server_version "$server_version" \
  --arg gem_commit "$gem_commit" \
  --argjson llm_request_count "$request_count" \
  '{status:$status,image:$image,image_id:$image_id,server_version:$server_version,opencode_ruby_commit:$gem_commit,llm_request_count:$llm_request_count}'
