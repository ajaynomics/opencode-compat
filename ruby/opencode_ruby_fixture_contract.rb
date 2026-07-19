# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

root = File.expand_path("..", __dir__)
gem_path = File.expand_path(ENV.fetch("OPENCODE_RUBY_PATH"))
$LOAD_PATH.unshift(File.join(gem_path, "lib"))
require "opencode-ruby"

manifest = JSON.parse(File.read(File.join(root, "fixtures/manifest.json")))
failures = []
write_evidence = lambda do |document|
  next unless (evidence_path = ENV["OPENCODE_COMPAT_EVIDENCE_PATH"])

  FileUtils.mkdir_p(File.dirname(evidence_path))
  File.write(evidence_path, JSON.pretty_generate(document) + "\n")
end

manifest.fetch("fixtures").each do |entry|
  reply = Opencode::Reply.new
  event_path = File.join(root, "fixtures", entry.fetch("events"))
  expected_path = File.join(root, "fixtures", entry.fetch("expected"))

  File.foreach(event_path) do |line|
    next if line.strip.empty?

    reply.apply(JSON.parse(line, symbolize_names: true))
  end

  result = reply.result
  expected = JSON.parse(File.read(expected_path))
  actual = {
    "full_text" => result.full_text,
    "reasoning_text" => result.reasoning_text,
    "tool_count" => result.tool_parts.length,
    "prompt_blocked" => reply.prompt_blocked?,
    "total_cost" => reply.total_cost,
    "total_input_tokens" => reply.total_input_tokens,
    "total_output_tokens" => reply.total_output_tokens
  }

  if (tool_expectation = expected["tool"])
    tool = result.tool_parts.first || reply.parts.find { |part| part["type"] == "tool" }
    actual["tool"] = {
      "tool" => tool&.fetch("tool", nil),
      "status" => tool&.fetch("status", nil),
      "callID" => tool&.fetch("callID", nil),
      "opencode_request_id" => tool&.dig("input", "opencode_request_id")
    }
    expected["tool"] = tool_expectation
  end

  expected.each do |key, value|
    next if actual[key] == value

    failures << "#{entry.fetch("id")}: #{key} expected #{value.inspect}, got #{actual[key].inspect}"
  end

  unless failures.any? { |failure| failure.start_with?("#{entry.fetch("id")}:") }
    puts "PASS #{entry.fetch("id")}"
  end
end

unless failures.empty?
  evidence = {
    schema_version: 1,
    kind: "shared-ruby-fixture-contract",
    status: "fail",
    checked_at: Time.now.utc.iso8601,
    adapter: "opencode-ruby",
    adapter_version: Opencode::VERSION,
    adapter_commit: ENV["OPENCODE_RUBY_COMMIT"],
    fixture_count: manifest.fetch("fixtures").length,
    failures: failures,
    workflow: {
      run_id: ENV["OPENCODE_COMPAT_RUN_ID"],
      run_attempt: ENV["OPENCODE_COMPAT_RUN_ATTEMPT"],
      head_sha: ENV["OPENCODE_COMPAT_HEAD_SHA"],
      repository: ENV["OPENCODE_COMPAT_REPOSITORY"],
      run_url: ENV["OPENCODE_COMPAT_RUN_URL"]
    }
  }
  write_evidence.call(evidence)
  warn failures.join("\n")
  exit 1
end

evidence = {
  schema_version: 1,
  kind: "shared-ruby-fixture-contract",
  status: "pass",
  checked_at: Time.now.utc.iso8601,
  adapter: "opencode-ruby",
  adapter_version: Opencode::VERSION,
  adapter_commit: ENV["OPENCODE_RUBY_COMMIT"],
  fixture_count: manifest.fetch("fixtures").length,
  workflow: {
    run_id: ENV["OPENCODE_COMPAT_RUN_ID"],
    run_attempt: ENV["OPENCODE_COMPAT_RUN_ATTEMPT"],
    head_sha: ENV["OPENCODE_COMPAT_HEAD_SHA"],
    repository: ENV["OPENCODE_COMPAT_REPOSITORY"],
    run_url: ENV["OPENCODE_COMPAT_RUN_URL"]
  }
}
puts JSON.generate(evidence)
write_evidence.call(evidence)
