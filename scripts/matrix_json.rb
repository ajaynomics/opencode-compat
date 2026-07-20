# frozen_string_literal: true

require "json"
require_relative "../lib/opencode_compat/client_candidate"

root = File.expand_path("..", __dir__)
manifest = JSON.parse(File.read(File.join(root, "manifests/image-matrix.json")))
candidate = OpenCodeCompat::ClientCandidate.load(File.join(root, "manifests/client-candidate.json"))
candidate.verify!
clients = candidate.document.fetch("clients")
expected_candidate = {
  "release_train" => candidate.document.fetch("release_train"),
  "publication_state" => candidate.document.fetch("publication_state"),
  "opencode_ruby_commit" => clients.dig("opencode-ruby", "ref"),
  "opencode_rails_commit" => clients.dig("opencode-rails", "ref")
}
matrix_candidate = manifest.fetch("client_candidate")
unless expected_candidate.all? { |key, value| matrix_candidate[key] == value }
  abort "image matrix client_candidate must equal the exact client candidate"
end
unless %w[pending certified].include?(matrix_candidate.fetch("certification_status"))
  abort "image matrix client_candidate certification_status must be pending or certified"
end

matrix = manifest.fetch("public_ci").map do |target|
  id = target.fetch("id")
  profiles = target.fetch("profiles")
  certification_scope = target.fetch("certification_scope", "shared-client-contract-only")
  unless profiles == ["ruby-rest-sse"]
    abort "#{id}: public CI executes exactly ruby-rest-sse; got profiles=#{profiles.inspect}"
  end
  unless certification_scope == "shared-client-contract-only"
    abort "#{id}: certification_scope must be shared-client-contract-only; got #{certification_scope.inspect}"
  end

  {
    "id" => id,
    "version" => target.fetch("version"),
    "image" => target.fetch("image"),
    "consumers" => target.fetch("consumers"),
    "profiles" => profiles,
    "required_consumer_profiles" => target.fetch("required_consumer_profiles"),
    "certification_scope" => certification_scope,
    "certification_status" => target.fetch("certification_status")
  }
end

puts JSON.generate("include" => matrix)
