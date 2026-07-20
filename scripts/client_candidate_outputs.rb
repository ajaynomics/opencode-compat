#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/opencode_compat/client_candidate"

root = File.expand_path("..", __dir__)
path = ARGV.fetch(0, File.join(root, "manifests/client-candidate.json"))
candidate = OpenCodeCompat::ClientCandidate.load(path)
candidate.github_outputs.each { |key, value| puts "#{key}=#{value}" }
