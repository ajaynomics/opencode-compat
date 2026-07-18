# frozen_string_literal: true

require "json"
require "time"

root = File.expand_path("..", __dir__)
tag, published_at, release_url, digest = ARGV
abort "usage: record_upstream_candidate.rb TAG PUBLISHED_AT RELEASE_URL DIGEST" unless digest
abort "invalid upstream release tag: #{tag.inspect}" unless tag.match?(/\Av\d+\.\d+\.\d+\z/)
abort "invalid OCI digest: #{digest.inspect}" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)

version = tag.delete_prefix("v")
image = "ghcr.io/anomalyco/opencode@#{digest}"
upstream_path = File.join(root, "manifests/upstream.json")
matrix_path = File.join(root, "manifests/image-matrix.json")
upstream = JSON.parse(File.read(upstream_path))
matrix = JSON.parse(File.read(matrix_path))

exit 0 if upstream.fetch("release_tag") == tag

upstream.merge!(
  "release_tag" => tag,
  "version" => version,
  "published_at" => published_at,
  "release_url" => release_url,
  "image" => image,
  "observed_at" => Time.now.utc.iso8601
)

unless matrix.fetch("public_ci").any? { |target| target.fetch("image") == image }
  matrix.fetch("public_ci") << {
    "id" => "upstream-#{version}",
    "version" => version,
    "image" => image,
    "tag_provenance" => "ghcr.io/anomalyco/opencode:#{version}",
    "consumers" => ["upstream-candidate"],
    "profiles" => ["ruby-rest-sse", "rails-persisted-turn", "voice-stream", "strict-v2", "plugin-ledger", "provider-hooks"],
    "certification_status" => "pending"
  }
end

File.write(upstream_path, JSON.pretty_generate(upstream) + "\n")
File.write(matrix_path, JSON.pretty_generate(matrix) + "\n")
