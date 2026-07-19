# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
manifest = JSON.parse(File.read(File.join(root, "manifests/image-matrix.json")))
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
