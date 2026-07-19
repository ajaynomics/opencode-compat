# frozen_string_literal: true

require "json"
require "time"

root = File.expand_path("..", __dir__)
tag, published_at, release_url, digest = ARGV
abort "usage: record_upstream_candidate.rb TAG PUBLISHED_AT RELEASE_URL DIGEST" unless digest
abort "invalid upstream release tag: #{tag.inspect}" unless tag.match?(/\Av\d+\.\d+\.\d+\z/)
abort "invalid OCI digest: #{digest.inspect}" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
begin
  Time.iso8601(published_at)
rescue ArgumentError, TypeError
  abort "invalid upstream publication timestamp: #{published_at.inspect}"
end
expected_release_url = "https://github.com/anomalyco/opencode/releases/tag/#{tag}"
abort "invalid upstream release URL: #{release_url.inspect}" unless release_url == expected_release_url

version = tag.delete_prefix("v")
image = "ghcr.io/anomalyco/opencode@#{digest}"
upstream_path = File.join(root, "manifests/upstream.json")
matrix_path = File.join(root, "manifests/image-matrix.json")
upstream = JSON.parse(File.read(upstream_path))
matrix = JSON.parse(File.read(matrix_path))
public_ci = matrix.fetch("public_ci")
abort "public_ci must be an array" unless public_ci.is_a?(Array)

matching_targets = public_ci.select { |target| target.fetch("image") == image }
if matching_targets.length > 1
  abort "image #{image} must appear exactly once in public_ci; found #{matching_targets.length}"
end

matrix_changed = false
if matching_targets.empty?
  target_id = "upstream-#{version}-#{digest.delete_prefix('sha256:')}"
  if public_ci.any? { |target| target.fetch("id") == target_id }
    abort "cannot add #{image}: public_ci id #{target_id.inspect} is already used by another image"
  end

  public_ci << {
    "id" => target_id,
    "version" => version,
    "image" => image,
    "tag_provenance" => "ghcr.io/anomalyco/opencode:#{version}",
    "consumers" => [],
    "profiles" => ["ruby-rest-sse"],
    "required_consumer_profiles" => [],
    "certification_scope" => "shared-client-contract-only",
    "certification_status" => "pending"
  }
  matrix_changed = true
end

upstream_changed = upstream.fetch("release_tag") != tag || upstream.fetch("image") != image
if upstream_changed
  upstream.merge!(
    "release_tag" => tag,
    "version" => version,
    "published_at" => published_at,
    "release_url" => release_url,
    "image" => image,
    "observed_at" => Time.now.utc.iso8601
  )
end

File.write(upstream_path, JSON.pretty_generate(upstream) + "\n") if upstream_changed
File.write(matrix_path, JSON.pretty_generate(matrix) + "\n") if matrix_changed
