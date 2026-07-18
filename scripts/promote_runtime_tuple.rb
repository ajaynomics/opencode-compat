#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/opencode_compat/runtime_tuple_promoter"

root = File.expand_path("..", __dir__)
command = ARGV.shift
options = {
  "evidence" => [],
  "previous_evidence" => []
}

parser = OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage:
      ruby scripts/promote_runtime_tuple.rb fingerprint --consumer NAME --consumer-commit SHA
      ruby scripts/promote_runtime_tuple.rb promote --consumer NAME --consumer-commit SHA \\
        --status pass --certified-at TIMESTAMP --evidence evidence/FILE.json \\
        [--previous-status pass --previous-certified-at TIMESTAMP \\
         --previous-evidence evidence/FILE.json] [--dry-run]
  USAGE

  opts.on("--consumer NAME") { |value| options["consumer"] = value }
  opts.on("--consumer-commit SHA") { |value| options["consumer_commit"] = value }
  opts.on("--status STATUS") { |value| options["status"] = value }
  opts.on("--certified-at TIMESTAMP") { |value| options["certified_at"] = value }
  opts.on("--evidence PATH") { |value| options["evidence"] << value }
  opts.on("--previous-status STATUS") { |value| options["previous_status"] = value }
  opts.on("--previous-certified-at TIMESTAMP") { |value| options["previous_certified_at"] = value }
  opts.on("--previous-evidence PATH") { |value| options["previous_evidence"] << value }
  opts.on("--dry-run") { options["dry_run"] = true }
end

def required!(options, *keys)
  missing = keys.reject { |key| options[key] && (!options[key].respond_to?(:empty?) || !options[key].empty?) }
  raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?
end

begin
  parser.parse!(ARGV)
  raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

  promoter = OpenCodeCompat::RuntimeTuplePromoter.new(root: root)
  case command
  when "fingerprint"
    required!(options, "consumer", "consumer_commit")
    puts JSON.pretty_generate(
      promoter.fingerprints(
        consumer: options.fetch("consumer"),
        consumer_commit: options.fetch("consumer_commit")
      )
    )
  when "promote"
    required!(options, "consumer", "consumer_commit", "status", "certified_at", "evidence")
    previous_fields = %w[previous_status previous_certified_at previous_evidence]
    supplied_previous_fields = previous_fields.select do |key|
      value = options[key]
      value && (!value.respond_to?(:empty?) || !value.empty?)
    end
    if supplied_previous_fields.any? && supplied_previous_fields.length != previous_fields.length
      raise OptionParser::MissingArgument, (previous_fields - supplied_previous_fields).join(", ")
    end

    previous_certification = if supplied_previous_fields.empty?
                               nil
                             else
                               {
                                 "status" => options.fetch("previous_status"),
                                 "certified_at" => options.fetch("previous_certified_at"),
                                 "evidence" => options.fetch("previous_evidence")
                               }
                             end
    promoted = promoter.promote(
      consumer: options.fetch("consumer"),
      consumer_commit: options.fetch("consumer_commit"),
      certification: {
        "status" => options.fetch("status"),
        "certified_at" => options.fetch("certified_at"),
        "evidence" => options.fetch("evidence")
      },
      previous_certification: previous_certification,
      dry_run: options.fetch("dry_run", false)
    )
    if options.fetch("dry_run", false)
      puts JSON.pretty_generate(promoted)
    else
      current = promoted.fetch("consumers").fetch(options.fetch("consumer")).fetch("current")
      puts JSON.pretty_generate(
        "consumer" => options.fetch("consumer"),
        "current_consumer_commit" => current.fetch("consumer_commit"),
        "current_tuple_sha256" => current.dig("certification", "tuple_sha256"),
        "migration_state" => promoted.fetch("migration_state")
      )
    end
  else
    raise OptionParser::InvalidArgument, "command must be fingerprint or promote"
  end
rescue OpenCodeCompat::PromotionError, OptionParser::ParseError => e
  warn "error: #{e.message}"
  warn parser
  exit 1
end
