# frozen_string_literal: true

require "json"
require "time"

gem_path = File.expand_path(ENV.fetch("OPENCODE_RUBY_PATH"))
$LOAD_PATH.unshift(File.join(gem_path, "lib"))
require "opencode-ruby"

base_url = ENV.fetch("OPENCODE_BASE_URL")
model = ENV.fetch("OPENCODE_COMPAT_MODEL", "compat/compat-model")
expected_text = ENV.fetch("OPENCODE_COMPAT_EXPECTED_TEXT", "compat-ok")
client = Opencode::Client.new(base_url: base_url, timeout: 30)
session_id = nil

begin
  health = client.health
  raise "OpenCode health did not report healthy: #{health.inspect}" unless health[:healthy] || health[:ok]

  session = client.create_session(title: "opencode-compat isolated probe")
  session_id = session.fetch(:id)
  observed_parts = []

  result = client.stream(
    session_id,
    "Reply with exactly: #{expected_text}",
    model: model,
    stream_timeout: 30,
    first_event_timeout: 15,
    idle_stream_timeout: 15
  ) do |part|
    observed_parts << JSON.parse(JSON.generate(part))
  end

  unless result.full_text.include?(expected_text)
    raise "Expected final text to include #{expected_text.inspect}, got #{result.full_text.inspect}"
  end

  messages = client.get_messages(session_id)
  assistant_messages = Array(messages).select { |message| message.dig(:info, :role) == "assistant" }
  raise "No authoritative assistant exchange returned" if assistant_messages.empty?

  puts JSON.generate(
    status: "pass",
    checked_at: Time.now.utc.iso8601,
    opencode_base_url: base_url,
    opencode_health: health,
    opencode_ruby_version: Opencode::VERSION,
    opencode_ruby_commit: ENV["OPENCODE_RUBY_COMMIT"],
    session_id: session_id,
    expected_text: expected_text,
    full_text: result.full_text,
    observed_part_count: observed_parts.length,
    authoritative_assistant_message_count: assistant_messages.length
  )
rescue StandardError => error
  diagnostic = {error: "#{error.class}: #{error.message}"}
  if session_id
    diagnostic[:session_status] = client.session_status
    diagnostic[:messages] = client.get_messages(session_id)
  end
  warn JSON.generate(diagnostic)
  raise
ensure
  client.delete_session(session_id) if session_id
end
