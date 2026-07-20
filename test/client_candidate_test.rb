# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/opencode_compat/client_candidate"

class ClientCandidateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBY_COMMIT = "9277646a4bb2cf25a8384ffc140b154f49ea5766"
  RAILS_COMMIT = "a9add2a7c1dd3eb978aa8b4ebf9ef7e111d1057f"

  def setup
    @document = JSON.parse(File.binread(File.join(ROOT, "manifests/client-candidate.json")))
  end

  def test_accepts_exact_unpublished_commit_candidate_and_emits_safe_outputs
    outputs = OpenCodeCompat::ClientCandidate.new(@document).github_outputs

    assert_equal "unpublished", outputs.fetch("publication_state")
    assert_equal "commit", outputs.fetch("ruby_provenance_kind")
    assert_equal RUBY_COMMIT, outputs.fetch("ruby_ref")
    assert_equal "", outputs.fetch("ruby_tag")
    assert_equal "commit", outputs.fetch("rails_provenance_kind")
    assert_equal RAILS_COMMIT, outputs.fetch("rails_ref")
    assert_equal "", outputs.fetch("rails_tag_object")
  end

  def test_unpublished_candidate_rejects_mixed_or_mismatched_provenance
    @document.dig("clients", "opencode-ruby", "provenance")["tag"] = "v0.0.1.alpha8"
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/commit provenance keys/, error.message)

    @document.dig("clients", "opencode-ruby", "provenance").delete("tag")
    @document.dig("clients", "opencode-ruby", "provenance")["commit"] = "f" * 40
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/provenance commit/, error.message)
  end

  def test_published_candidate_requires_annotated_tag_provenance_for_both_clients
    publish_document!

    candidate.verify!

    @document.dig("clients", "opencode-ruby")["provenance"] = {
      "kind" => "commit",
      "commit" => RUBY_COMMIT
    }
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/provenance kind must equal "annotated-tag"/, error.message)
  end

  def test_published_candidate_rejects_wrong_tag_object_shape_or_peel
    publish_document!
    ruby_provenance = @document.dig("clients", "opencode-ruby", "provenance")
    ruby_provenance["annotated_tag_object"] = "short"
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/annotated tag object must be a full lowercase 40-character/, error.message)

    ruby_provenance["annotated_tag_object"] = "3" * 40
    ruby_provenance["peeled_commit"] = "f" * 40
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/peeled commit/, error.message)
  end

  def test_rejects_non_lockstep_runtime_dependency
    dependency = @document.dig("clients", "opencode-rails", "runtime_dependencies", "opencode-ruby")
    dependency["requirement"] = "~> 0.0.1.alpha8"
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/runtime dependency requirement/, error.message)

    dependency["requirement"] = "= 0.0.1.alpha8"
    dependency["ref"] = "f" * 40
    error = assert_raises(OpenCodeCompat::ClientCandidate::ValidationError) { candidate.verify! }
    assert_match(/runtime dependency ref/, error.message)
  end

  def test_output_script_validates_the_repository_manifest
    output, error, status = Open3.capture3(
      RbConfig.ruby,
      File.join(ROOT, "scripts/client_candidate_outputs.rb")
    )

    assert status.success?, error
    assert_includes output.lines, "ruby_ref=#{RUBY_COMMIT}\n"
    assert_includes output.lines, "rails_ref=#{RAILS_COMMIT}\n"
    assert_includes output.lines, "publication_state=unpublished\n"
  end

  private

  def candidate
    OpenCodeCompat::ClientCandidate.new(@document)
  end

  def publish_document!
    @document["publication_state"] = "published"
    {
      "opencode-ruby" => "3" * 40,
      "opencode-rails" => "4" * 40
    }.each do |name, tag_object|
      client = @document.fetch("clients").fetch(name)
      client["provenance"] = {
        "kind" => "annotated-tag",
        "tag" => "v#{client.fetch('version')}",
        "annotated_tag_object" => tag_object,
        "peeled_commit" => client.fetch("ref")
      }
    end
  end
end
