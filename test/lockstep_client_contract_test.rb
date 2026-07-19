# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../ruby/lockstep_client_contract"

module LockstepClientContractTestSources
  class Git
    attr_reader :revision

    def initialize(revision)
      @revision = revision
    end
  end

  class Path; end
end

class LockstepClientContractTest < Minitest::Test
  RUBY_COMMIT = "1" * 40
  RAILS_COMMIT = "2" * 40
  RUBY_TAG_OBJECT = "3" * 40
  RAILS_TAG_OBJECT = "4" * 40
  RUBY_TAG = "v0.0.1.alpha7"
  RAILS_TAG = "v0.0.1.alpha7"
  VERSION = "0.0.1.alpha7"

  FakeSpec = Struct.new(:name, :version, :runtime_dependencies, :source, :full_gem_path, keyword_init: true)

  def setup
    @root = Dir.mktmpdir("opencode-lockstep-contract")
    @ruby_path = File.join(@root, "opencode-ruby")
    @rails_path = File.join(@root, "opencode-rails")
    Dir.mkdir(@ruby_path)
    Dir.mkdir(@rails_path)
    @env = {
      "OPENCODE_RUBY_PATH" => @ruby_path,
      "OPENCODE_RUBY_COMMIT" => RUBY_COMMIT,
      "OPENCODE_RUBY_TAG" => RUBY_TAG,
      "OPENCODE_RUBY_TAG_OBJECT" => RUBY_TAG_OBJECT,
      "OPENCODE_RUBY_VERSION" => VERSION,
      "OPENCODE_RAILS_PATH" => @rails_path,
      "OPENCODE_RAILS_COMMIT" => RAILS_COMMIT,
      "OPENCODE_RAILS_TAG" => RAILS_TAG,
      "OPENCODE_RAILS_TAG_OBJECT" => RAILS_TAG_OBJECT,
      "OPENCODE_RAILS_VERSION" => VERSION
    }
    @heads = {@ruby_path => RUBY_COMMIT, @rails_path => RAILS_COMMIT}
    @git_results = {}
    seed_annotated_tag(@ruby_path, RUBY_TAG, RUBY_TAG_OBJECT, RUBY_COMMIT)
    seed_annotated_tag(@rails_path, RAILS_TAG, RAILS_TAG_OBJECT, RAILS_COMMIT)
    @ruby_spec = FakeSpec.new(name: "opencode-ruby", version: Gem::Version.new(VERSION))
    @rails_spec = FakeSpec.new(
      name: "opencode-rails",
      version: Gem::Version.new(VERSION),
      runtime_dependencies: [Gem::Dependency.new("opencode-ruby", "= #{VERSION}")],
      full_gem_path: @rails_path
    )
    @bundle_ruby_spec = FakeSpec.new(
      name: "opencode-ruby",
      source: LockstepClientContractTestSources::Git.new(RUBY_COMMIT)
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_verifies_and_emits_canonical_lockstep_evidence
    evidence_path = File.join(@root, "evidence", "lockstep.json")
    @env["OPENCODE_COMPAT_EVIDENCE_PATH"] = evidence_path
    output = StringIO.new

    document = contract.emit(io: output)

    expected_json = OpenCodeCompat::LockstepClientContract.canonical_json(document)
    assert_equal "#{expected_json}\n", output.string
    assert_equal "#{expected_json}\n", File.binread(evidence_path)
    assert_equal "pass", document.fetch("status")
    assert_equal RUBY_COMMIT, document.dig("opencode_ruby", "checkout_commit")
    assert_equal RUBY_COMMIT, document.dig("opencode_ruby", "bundler_git_revision")
    assert_equal RUBY_TAG_OBJECT, document.dig("opencode_ruby", "tag_provenance", "annotated_tag_object")
    assert_equal RUBY_COMMIT, document.dig("opencode_ruby", "tag_provenance", "peeled_commit")
    assert_equal RUBY_TAG, document.dig("opencode_ruby", "tag_provenance", "tag")
    assert_equal RAILS_COMMIT, document.dig("opencode_rails", "checkout_commit")
    assert_equal RAILS_TAG_OBJECT, document.dig("opencode_rails", "tag_provenance", "annotated_tag_object")
    assert_equal RAILS_COMMIT, document.dig("opencode_rails", "tag_provenance", "peeled_commit")
    assert_equal "= #{VERSION}", document.dig("opencode_rails", "runtime_dependency", "requirement")
    assert_equal RUBY_VERSION, document.fetch("ruby_runtime_version")
    assert_nil document.dig("workflow", "run_id")
    assert_equal expected_json, JSON.generate(JSON.parse(expected_json).sort.to_h)
  end

  def test_rejects_checkout_commit_mismatch_for_either_client
    {
      @ruby_path => "opencode-ruby checkout commit",
      @rails_path => "opencode-rails checkout commit"
    }.each do |path, message|
      original = @heads.fetch(path)
      @heads[path] = "f" * 40

      error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
      assert_match message, error.message
    ensure
      @heads[path] = original
    end
  end

  def test_rejects_non_annotated_tag_object_for_either_client
    {
      @ruby_path => RUBY_TAG_OBJECT,
      @rails_path => RAILS_TAG_OBJECT
    }.each do |path, object|
      set_git_result(path, ["cat-file", "-t", object], "commit")

      error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
      assert_match(/annotated tag object type must equal "tag"/, error.message)
    ensure
      set_git_result(path, ["cat-file", "-t", object], "tag")
    end
  end

  def test_rejects_tampered_annotated_tag_object_coordinate
    tampered_object = "f" * 40
    @env["OPENCODE_RUBY_TAG_OBJECT"] = tampered_object
    set_git_result(@ruby_path, ["cat-file", "-t", tampered_object], "tag")
    set_git_result(@ruby_path, ["rev-parse", "--verify", "#{tampered_object}^{commit}"], RUBY_COMMIT)

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }

    assert_match(/opencode-ruby local tag ref object/, error.message)
    assert_match(/#{RUBY_TAG_OBJECT}/, error.message)
  end

  def test_rejects_local_tag_ref_resolving_to_another_object
    set_git_result(
      @rails_path,
      ["rev-parse", "--verify", "refs/tags/#{RAILS_TAG}"],
      "e" * 40
    )

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }

    assert_match(/opencode-rails local tag ref object/, error.message)
  end

  def test_rejects_wrong_object_or_ref_peel
    object_peel_key = ["rev-parse", "--verify", "#{RUBY_TAG_OBJECT}^{commit}"]
    set_git_result(@ruby_path, object_peel_key, "e" * 40)

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/opencode-ruby annotated tag peeled commit/, error.message)

    set_git_result(@ruby_path, object_peel_key, RUBY_COMMIT)
    set_git_result(
      @ruby_path,
      ["rev-parse", "--verify", "refs/tags/#{RUBY_TAG}^{commit}"],
      "e" * 40
    )

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/opencode-ruby local tag ref peeled commit/, error.message)
  end

  def test_rejects_missing_local_tag
    @git_results.delete([@ruby_path, ["rev-parse", "--verify", "refs/tags/#{RUBY_TAG}"]])

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }

    assert_match(/could not resolve opencode-ruby local tag ref/, error.message)
  end

  def test_rejects_loaded_or_gem_version_drift
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) do
      contract(ruby_version: "0.0.1.alpha8").verify
    end
    assert_match(/loaded Opencode::VERSION/, error.message)

    @rails_spec.version = Gem::Version.new("0.0.1.alpha8")
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/loaded opencode-rails gem version/, error.message)
  end

  def test_rejects_non_lockstep_expected_versions
    @env["OPENCODE_RAILS_VERSION"] = "0.0.1.alpha8"

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) do
      contract(rails_version: "0.0.1.alpha8").verify
    end

    assert_match(/lockstep client version/, error.message)
  end

  def test_rejects_non_exact_or_wrong_rails_runtime_dependency
    ["~> #{VERSION}", "= 0.0.1.alpha6"].each do |requirement|
      @rails_spec.runtime_dependencies = [Gem::Dependency.new("opencode-ruby", requirement)]

      error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
      assert_match(/must require opencode-ruby = #{Regexp.escape(VERSION)}/, error.message)
    end
  end

  def test_rejects_missing_or_duplicate_rails_runtime_dependency
    @rails_spec.runtime_dependencies = []
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/exactly one runtime dependency/, error.message)

    @rails_spec.runtime_dependencies = [
      Gem::Dependency.new("opencode-ruby", "= #{VERSION}"),
      Gem::Dependency.new("opencode-ruby", "= #{VERSION}")
    ]
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/exactly one runtime dependency/, error.message)
  end

  def test_rejects_non_git_or_mismatched_bundler_source
    @bundle_ruby_spec.source = LockstepClientContractTestSources::Path.new
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/must be a Git source/, error.message)

    @bundle_ruby_spec.source = LockstepClientContractTestSources::Git.new("f" * 40)
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/Bundler opencode-ruby revision/, error.message)
  end

  def test_rejects_loaded_rails_gem_from_another_checkout
    other_path = File.join(@root, "other-opencode-rails")
    Dir.mkdir(other_path)
    @rails_spec.full_gem_path = other_path

    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }

    assert_match(/loaded opencode-rails checkout/, error.message)
  end

  def test_requires_full_exact_candidate_coordinates
    @env.delete("OPENCODE_RUBY_COMMIT")
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/missing required environment: OPENCODE_RUBY_COMMIT/, error.message)

    @env["OPENCODE_RUBY_COMMIT"] = "main"
    error = assert_raises(OpenCodeCompat::LockstepClientContract::ContractError) { contract.verify }
    assert_match(/full lowercase 40-character Git commit/, error.message)
  end

  def test_cli_failure_writes_failure_evidence
    stub_path = File.join(@root, "cli-stubs")
    evidence_path = File.join(@root, "cli-evidence", "lockstep.json")
    FileUtils.mkdir_p(stub_path)
    File.binwrite(File.join(stub_path, "bundler.rb"), <<~RUBY)
      module Bundler
        LoadedDefinition = Struct.new(:specs)

        def self.load
          LoadedDefinition.new([])
        end
      end
    RUBY
    File.binwrite(File.join(stub_path, "opencode-rails.rb"), <<~RUBY)
      module Opencode
        VERSION = #{VERSION.inspect}
        RAILS_VERSION = #{VERSION.inspect}
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      {"OPENCODE_COMPAT_EVIDENCE_PATH" => evidence_path},
      RbConfig.ruby,
      "-I",
      stub_path,
      File.expand_path("../ruby/lockstep_client_contract.rb", __dir__),
      unsetenv_others: true
    )

    refute status.success?
    assert_equal 1, status.exitstatus
    failure = JSON.parse(File.binread(evidence_path))
    assert_equal "opencode-client-lockstep", failure.fetch("contract")
    assert_equal "fail", failure.fetch("status")
    assert_match(/missing required environment/, failure.fetch("error"))
    assert_equal failure, JSON.parse(stderr)
  end

  private

  def contract(ruby_version: VERSION, rails_version: VERSION)
    OpenCodeCompat::LockstepClientContract.new(
      env: @env,
      git_resolver: method(:resolve_git),
      loaded_specs: {
        "opencode-ruby" => @ruby_spec,
        "opencode-rails" => @rails_spec
      },
      bundle_specs: [@bundle_ruby_spec],
      ruby_version: ruby_version,
      rails_version: rails_version
    )
  end

  def resolve_git(path, *arguments)
    return @heads.fetch(path) if arguments == ["rev-parse", "--verify", "HEAD^{commit}"]

    @git_results.fetch([path, arguments])
  end

  def seed_annotated_tag(path, tag, object, commit)
    set_git_result(path, ["cat-file", "-t", object], "tag")
    set_git_result(path, ["rev-parse", "--verify", "refs/tags/#{tag}"], object)
    set_git_result(path, ["rev-parse", "--verify", "#{object}^{commit}"], commit)
    set_git_result(path, ["rev-parse", "--verify", "refs/tags/#{tag}^{commit}"], commit)
  end

  def set_git_result(path, arguments, result)
    @git_results[[path, arguments]] = result
  end
end
