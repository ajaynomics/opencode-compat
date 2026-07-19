# frozen_string_literal: true

module OpenCodeCompat
  module ExactLiveContract
    class ContractError < StandardError; end

    module_function

    def assert_final_text!(actual, expected)
      return if actual == expected

      raise ContractError, "Expected final text to equal #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_model_request_count!(value)
      count = Integer(value.to_s, 10)
      return if count == 1

      raise ContractError, "Expected exactly one deterministic model request, got #{count}"
    rescue ArgumentError, TypeError
      raise ContractError, "Deterministic model request count is not an integer: #{value.inspect}"
    end

    def assert_authoritative_assistant_count!(value)
      count = Integer(value.to_s, 10)
      return if count == 1

      raise ContractError, "Expected exactly one authoritative assistant message, got #{count}"
    rescue ArgumentError, TypeError
      raise ContractError, "Authoritative assistant message count is not an integer: #{value.inspect}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    OpenCodeCompat::ExactLiveContract.assert_model_request_count!(ARGV.fetch(0))
  rescue IndexError, OpenCodeCompat::ExactLiveContract::ContractError => error
    warn error.message
    exit 1
  end
end
