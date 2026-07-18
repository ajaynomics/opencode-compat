# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
gem_path = File.expand_path(ENV.fetch("OPENCODE_RUBY_PATH"))
$LOAD_PATH.unshift(File.join(gem_path, "lib"))
require "opencode-ruby"

manifest = JSON.parse(File.read(File.join(root, "fixtures/manifest.json")))
failures = []

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
  warn failures.join("\n")
  exit 1
end

puts JSON.generate(
  status: "pass",
  adapter: "opencode-ruby",
  adapter_version: Opencode::VERSION,
  adapter_commit: ENV["OPENCODE_RUBY_COMMIT"],
  fixture_count: manifest.fetch("fixtures").length
)
