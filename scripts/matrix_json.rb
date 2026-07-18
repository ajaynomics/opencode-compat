# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
manifest = JSON.parse(File.read(File.join(root, "manifests/image-matrix.json")))
matrix = manifest.fetch("public_ci").map do |target|
  {
    "id" => target.fetch("id"),
    "version" => target.fetch("version"),
    "image" => target.fetch("image")
  }
end

puts JSON.generate("include" => matrix)
