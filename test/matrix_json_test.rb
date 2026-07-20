# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class MatrixJsonTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("opencode-matrix-json")
    FileUtils.mkdir_p(File.join(@tmp, "lib/opencode_compat"))
    FileUtils.mkdir_p(File.join(@tmp, "scripts"))
    FileUtils.mkdir_p(File.join(@tmp, "manifests"))
    FileUtils.cp(File.join(ROOT, "scripts/matrix_json.rb"), File.join(@tmp, "scripts"))
    FileUtils.cp(
      File.join(ROOT, "lib/opencode_compat/client_candidate.rb"),
      File.join(@tmp, "lib/opencode_compat")
    )
    FileUtils.cp(
      File.join(ROOT, "manifests/client-candidate.json"),
      File.join(@tmp, "manifests")
    )
    @manifest = JSON.parse(File.read(File.join(ROOT, "manifests/image-matrix.json")))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_emits_only_the_actual_shared_client_contract_profile
    output, error, status = run_matrix(@manifest)

    assert status.success?, error
    JSON.parse(output).fetch("include").each do |target|
      assert_equal ["ruby-rest-sse"], target.fetch("profiles")
      assert_equal "shared-client-contract-only", target.fetch("certification_scope")
    end
  end

  def test_rejects_a_manifest_that_overstates_the_executed_profile
    @manifest.fetch("public_ci").first["profiles"] = ["rails-persisted-turn"]

    _output, error, status = run_matrix(@manifest)

    refute status.success?
    assert_match(/executes exactly ruby-rest-sse/, error)
  end

  def test_rejects_a_manifest_that_overstates_the_certification_scope
    @manifest.fetch("public_ci").first["certification_scope"] = "consumer-runtime"

    _output, error, status = run_matrix(@manifest)

    refute status.success?
    assert_match(/certification_scope must be shared-client-contract-only/, error)
  end

  def test_rejects_a_matrix_bound_to_another_client_candidate
    @manifest.fetch("client_candidate")["opencode_ruby_commit"] = "f" * 40

    _output, error, status = run_matrix(@manifest)

    refute status.success?
    assert_match(/must equal the exact client candidate/, error)
  end

  def test_allows_reviewed_candidate_certification_without_changing_coordinates
    @manifest.fetch("client_candidate")["certification_status"] = "certified"

    _output, error, status = run_matrix(@manifest)

    assert status.success?, error
  end

  def test_rejects_unknown_candidate_certification_status
    @manifest.fetch("client_candidate")["certification_status"] = "deployed"

    _output, error, status = run_matrix(@manifest)

    refute status.success?
    assert_match(/certification_status must be pending or certified/, error)
  end

  private

  def run_matrix(manifest)
    File.write(
      File.join(@tmp, "manifests/image-matrix.json"),
      JSON.pretty_generate(manifest) + "\n"
    )
    Open3.capture3(RbConfig.ruby, File.join(@tmp, "scripts/matrix_json.rb"))
  end
end
