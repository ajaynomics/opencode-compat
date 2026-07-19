# frozen_string_literal: true

tag = ARGV.fetch(0)
digest = ARGV.fetch(1)
disambiguator = ARGV[2]

abort "release tag must be vMAJOR.MINOR.PATCH" unless tag.match?(/\Av\d+\.\d+\.\d+\z/)
abort "digest must be an exact sha256" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)

branch = "compat/upstream-#{tag.delete_prefix('v')}-#{digest.delete_prefix('sha256:')}"
if disambiguator
  unless disambiguator.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\z/)
    abort "disambiguator must contain only letters, digits, and hyphens"
  end

  branch = "#{branch}-r#{disambiguator}"
end

abort "generated branch is longer than 128 characters" if branch.length > 128

puts branch
