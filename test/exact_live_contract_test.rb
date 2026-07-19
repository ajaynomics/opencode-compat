# frozen_string_literal: true

require "minitest/autorun"
require_relative "../ruby/exact_live_contract"

class ExactLiveContractTest < Minitest::Test
  def test_accepts_only_exact_final_text
    assert_nil OpenCodeCompat::ExactLiveContract.assert_final_text!("compat-ok", "compat-ok")

    error = assert_raises(OpenCodeCompat::ExactLiveContract::ContractError) do
      OpenCodeCompat::ExactLiveContract.assert_final_text!("compat-ok\n\ncompat-ok", "compat-ok")
    end
    assert_match(/equal/, error.message)

    assert_raises(OpenCodeCompat::ExactLiveContract::ContractError) do
      OpenCodeCompat::ExactLiveContract.assert_final_text!("prefix compat-ok", "compat-ok")
    end
  end

  def test_accepts_only_one_model_request
    assert_nil OpenCodeCompat::ExactLiveContract.assert_model_request_count!("1")

    %w[0 2 not-a-number].each do |count|
      assert_raises(OpenCodeCompat::ExactLiveContract::ContractError) do
        OpenCodeCompat::ExactLiveContract.assert_model_request_count!(count)
      end
    end
  end

  def test_accepts_only_one_authoritative_assistant_message
    assert_nil OpenCodeCompat::ExactLiveContract.assert_authoritative_assistant_count!(1)

    [0, 2, "not-a-number"].each do |count|
      assert_raises(OpenCodeCompat::ExactLiveContract::ContractError) do
        OpenCodeCompat::ExactLiveContract.assert_authoritative_assistant_count!(count)
      end
    end
  end
end
