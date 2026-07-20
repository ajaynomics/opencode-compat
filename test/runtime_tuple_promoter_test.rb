# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/opencode_compat/runtime_tuple_promoter"

class RuntimeTuplePromoterTest < Minitest::Test
  CONSUMER = "example"
  CURRENT_COMMIT = "1" * 40
  CANDIDATE_COMMIT = "2" * 40
  NEXT_COMMIT = "7" * 40
  RUBY_CURRENT = "3" * 40
  RUBY_CANDIDATE = "4" * 40
  RUBY_NEXT = "8" * 40
  RAILS_CURRENT = "5" * 40
  RAILS_CANDIDATE = "6" * 40
  RAILS_NEXT = "9" * 40
  CURRENT_TREE = "a" * 40
  CANDIDATE_TREE = "b" * 40
  NEXT_TREE = "c" * 40
  CURRENT_IMAGE = "ghcr.io/anomalyco/opencode@sha256:#{'a' * 64}"
  CANDIDATE_IMAGE = "ghcr.io/anomalyco/opencode@sha256:#{'b' * 64}"
  NEXT_IMAGE = "ghcr.io/anomalyco/opencode@sha256:#{'c' * 64}"
  CURRENT_TIME = "2026-07-17T12:00:00Z"
  CANDIDATE_TIME = "2026-07-18T12:00:00Z"
  NEXT_TIME = "2026-07-19T12:00:00Z"

  def setup
    @root = Dir.mktmpdir("opencode-compat-promotion")
    FileUtils.mkdir_p(File.join(@root, "manifests"))
    FileUtils.mkdir_p(File.join(@root, "evidence"))
    FileUtils.mkdir_p(File.join(@root, "profiles"))
    File.write(File.join(@root, "profiles", "rails-persisted-turn.json"), "{}\n")
    write_manifest(valid_manifest)
    @promoter = OpenCodeCompat::RuntimeTuplePromoter.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_promotion_atomically_moves_certified_tuples_and_clears_candidate
    candidate, previous = write_matching_evidence

    promoted = @promoter.promote(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, candidate),
      previous_certification: certification(CURRENT_TIME, previous)
    )

    consumer = promoted.fetch("consumers").fetch(CONSUMER)
    assert_nil consumer["candidate"]
    assert_equal CANDIDATE_COMMIT, consumer.dig("current", "consumer_commit")
    assert_equal RUBY_CANDIDATE, consumer.dig("current", "opencode_ruby", "git_commit")
    assert_equal "certified", consumer.dig("current", "status")
    assert_equal candidate.fetch("tuple_sha256"), consumer.dig("current", "certification", "tuple_sha256")
    assert_equal evidence_reference(candidate), consumer.dig("current", "certification", "evidence", 0)
    assert_equal CURRENT_COMMIT, consumer.dig("previous", "consumer_commit")
    assert_equal RUBY_CURRENT, consumer.dig("previous", "opencode_ruby", "git_commit")
    assert_equal "certified", consumer.dig("previous", "status")
    assert_equal previous.fetch("tuple_sha256"), consumer.dig("previous", "certification", "tuple_sha256")
    assert_equal evidence_reference(previous), consumer.dig("previous", "certification", "evidence", 0)
    assert_equal "certified", promoted.fetch("migration_state")
    assert_equal promoted, JSON.parse(File.read(manifest_path))
  end

  def test_dry_run_returns_promotion_without_changing_manifest
    candidate, previous = write_matching_evidence
    before = File.binread(manifest_path)

    promoted = @promoter.promote(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, candidate),
      previous_certification: certification(CURRENT_TIME, previous),
      dry_run: true
    )

    assert_equal "certified", promoted.dig("consumers", CONSUMER, "current", "status")
    assert_equal before, File.binread(manifest_path)
  end

  def test_rejects_missing_candidate_without_touching_manifest
    manifest = valid_manifest
    manifest.fetch("consumers").fetch(CONSUMER)["candidate"] = nil
    write_manifest(manifest)
    before = File.binread(manifest_path)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, {"path" => "evidence/missing.json"})
      )
    end

    assert_match(/no candidate/, error.message)
    assert_equal before, File.binread(manifest_path)
  end

  def test_rejects_mutable_candidate_image_even_with_an_exact_image_id
    manifest = valid_manifest
    runtime = manifest.dig("consumers", CONSUMER, "candidate", "runtime")
    runtime["registry_ref"] = "ghcr.io/anomalyco/opencode:latest"
    runtime["docker_image_id"] = "sha256:#{'c' * 64}"
    write_manifest(manifest)
    before = File.binread(manifest_path)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
    end

    assert_match(/immutable image@sha256 digest/, error.message)
    assert_equal before, File.binread(manifest_path)
  end

  def test_rejects_short_consumer_and_client_commits
    assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.fingerprints(consumer: CONSUMER, consumer_commit: "abc123")
    end

    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "candidate", "opencode_ruby")["git_commit"] = "abc123"
    write_manifest(manifest)
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
    end
    assert_match(/full 40-character/, error.message)
  end

  def test_rejects_malformed_immutable_tuple_coordinates_but_allows_unknown_build_source
    mutations = {
      "consumer tree" => lambda { |candidate| candidate["consumer_tree"] = "abc123" },
      "build source commit" => lambda { |candidate| candidate.fetch("runtime")["build_source_commit"] = "abc123" },
      "rollback commit" => lambda do |candidate|
        candidate["rollback_operability"] = {"immediate_platform_rollback_commit" => "abc123"}
      end,
      "artifact digest" => lambda do |candidate|
        candidate["application_canary"] = {"database_sha256" => "sha256:abc123"}
      end
    }

    mutations.each do |label, mutate|
      manifest = valid_manifest
      mutate.call(manifest.dig("consumers", CONSUMER, "candidate"))
      write_manifest(manifest)

      error = assert_raises(OpenCodeCompat::PromotionError, label) do
        @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
      end
      assert_match(/full 40-character|exact sha256 digest/, error.message, label)
    end

    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "candidate", "runtime")["build_source_commit"] = nil
    write_manifest(manifest)
    assert_match(
      /\Asha256:[0-9a-f]{64}\z/,
      @promoter.fingerprints(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT
      ).fetch("candidate_tuple_sha256")
    )
  end

  def test_rejects_missing_server_version_or_unknown_profile
    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "candidate", "runtime").delete("reported_version")
    write_manifest(manifest)
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
    end
    assert_match(/reported OpenCode server version/, error.message)

    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER)["profile"] = "untracked-profile"
    write_manifest(manifest)
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
    end
    assert_match(/profile does not exist/, error.message)
  end

  def test_rejects_missing_previous_certification_for_an_uncertified_baseline
    candidate, = write_matching_evidence
    before = File.binread(manifest_path)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate)
      )
    end

    assert_match(/current tuple is not certified/, error.message)
    assert_equal before, File.binread(manifest_path)
  end

  def test_rejects_known_failed_baseline_even_with_passing_evidence
    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "current")["status"] = "observed-production-contract-failed"
    write_manifest(manifest)
    candidate, previous = write_matching_evidence
    before = File.binread(manifest_path)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate),
        previous_certification: certification(CURRENT_TIME, previous)
      )
    end

    assert_match(/known to fail/, error.message)
    assert_equal before, File.binread(manifest_path)
  end

  def test_explicit_degraded_bootstrap_preserves_failed_emergency_provenance
    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "current")["status"] = "observed-production-contract-failed"
    write_manifest(manifest)
    candidate_fingerprint = @promoter.fingerprints(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT
    ).fetch("candidate_tuple_sha256")
    evidence = write_evidence(
      "bootstrap-candidate.json",
      commit: CANDIDATE_COMMIT,
      timestamp: CANDIDATE_TIME,
      fingerprint: candidate_fingerprint
    )
    before = File.binread(manifest_path)

    preview = @promoter.bootstrap_current(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, evidence),
      acknowledgement: OpenCodeCompat::RuntimeTuplePromoter::DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT,
      dry_run: true
    )

    assert_equal before, File.binread(manifest_path)
    assert_equal "bootstrap-current-only", preview.fetch("migration_state")

    bootstrapped = @promoter.bootstrap_current(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, evidence),
      acknowledgement: OpenCodeCompat::RuntimeTuplePromoter::DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT
    )
    consumer = bootstrapped.dig("consumers", CONSUMER)

    assert_equal "certified", consumer.dig("current", "status")
    assert_equal CANDIDATE_COMMIT, consumer.dig("current", "consumer_commit")
    assert_nil consumer["candidate"]
    assert_nil consumer["previous"]
    assert_equal "observed-production-contract-failed", consumer.dig("emergency_provenance", "status")
    assert_nil consumer.dig("emergency_provenance", "certification")
    assert_equal "degraded-no-certified-previous", consumer.dig("rollback_state", "status")
    assert_equal "bootstrap-current-only", bootstrapped.dig("promotion_readiness", "status")
    assert_equal bootstrapped, JSON.parse(File.read(manifest_path))
  end

  def test_bootstrap_then_normal_promotion_retains_the_first_passing_tuple_as_previous
    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "current")["status"] = "observed-production-contract-failed"
    write_manifest(manifest)
    bootstrap_fingerprint = @promoter.fingerprints(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT
    ).fetch("candidate_tuple_sha256")
    bootstrap_evidence = write_evidence(
      "bootstrap-rollback.json",
      commit: CANDIDATE_COMMIT,
      timestamp: CANDIDATE_TIME,
      fingerprint: bootstrap_fingerprint
    )
    @promoter.bootstrap_current(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, bootstrap_evidence),
      acknowledgement: OpenCodeCompat::RuntimeTuplePromoter::DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT
    )

    manifest = JSON.parse(File.read(manifest_path))
    manifest.dig("consumers", CONSUMER)["candidate"] = {
      "status" => "compatibility-certified",
      "certified_at" => NEXT_TIME,
      "consumer_commit" => NEXT_COMMIT,
      "opencode_ruby" => {"version" => "0.0.1.alpha8", "git_commit" => RUBY_NEXT},
      "opencode_rails" => {"version" => "0.0.1.alpha8", "git_commit" => RAILS_NEXT},
      "runtime" => {"image" => NEXT_IMAGE, "reported_version" => "1.19.0"}
    }
    write_manifest(manifest)
    next_fingerprint = @promoter.fingerprints(
      consumer: CONSUMER,
      consumer_commit: NEXT_COMMIT
    ).fetch("candidate_tuple_sha256")
    next_evidence = write_evidence(
      "next-current.json",
      commit: NEXT_COMMIT,
      timestamp: NEXT_TIME,
      fingerprint: next_fingerprint
    )

    promoted = @promoter.promote(
      consumer: CONSUMER,
      consumer_commit: NEXT_COMMIT,
      certification: certification(NEXT_TIME, next_evidence)
    )
    consumer = promoted.dig("consumers", CONSUMER)

    assert_equal NEXT_COMMIT, consumer.dig("current", "consumer_commit")
    assert_equal CANDIDATE_COMMIT, consumer.dig("previous", "consumer_commit")
    assert_equal "certified", consumer.dig("previous", "status")
    assert_equal "observed-production-contract-failed", consumer.dig("emergency_provenance", "status")
    refute consumer.key?("rollback_state")
    assert_equal "certified", promoted.fetch("migration_state")
    assert_equal "certified", promoted.dig("promotion_readiness", "status")
  end

  def test_degraded_bootstrap_requires_exact_acknowledgement
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.bootstrap_current(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: {},
        acknowledgement: "yes",
        dry_run: true
      )
    end

    assert_match(/explicit acknowledgement/, error.message)
  end

  def test_degraded_bootstrap_rejects_a_passing_baseline_or_existing_previous_tuple
    candidate, = write_matching_evidence
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.bootstrap_current(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate),
        acknowledgement: OpenCodeCompat::RuntimeTuplePromoter::DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT,
        dry_run: true
      )
    end
    assert_match(/only for a current tuple known to fail/, error.message)

    manifest = valid_manifest
    manifest.dig("consumers", CONSUMER, "current")["status"] = "observed-production-contract-failed"
    manifest.dig("consumers", CONSUMER)["previous"] = manifest.dig("consumers", CONSUMER, "current").dup
    write_manifest(manifest)
    candidate_fingerprint = @promoter.fingerprints(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT
    ).fetch("candidate_tuple_sha256")
    evidence = write_evidence(
      "bootstrap-existing-previous.json",
      commit: CANDIDATE_COMMIT,
      timestamp: CANDIDATE_TIME,
      fingerprint: candidate_fingerprint
    )
    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.bootstrap_current(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, evidence),
        acknowledgement: OpenCodeCompat::RuntimeTuplePromoter::DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT,
        dry_run: true
      )
    end
    assert_match(/cannot replace an existing previous/, error.message)
  end

  def test_rejects_evidence_that_does_not_match_the_complete_tuple
    candidate, previous = write_matching_evidence
    manifest = JSON.parse(File.read(manifest_path))
    manifest.dig("consumers", CONSUMER, "candidate", "runtime")["image"] =
      "ghcr.io/anomalyco/opencode@sha256:#{'f' * 64}"
    write_manifest(manifest)
    before = File.binread(manifest_path)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate),
        previous_certification: certification(CURRENT_TIME, previous)
      )
    end

    assert_match(/tuple_sha256/, error.message)
    assert_equal before, File.binread(manifest_path)
  end

  def test_hash_binds_evidence_and_accepts_a_structured_reference
    candidate, previous = write_matching_evidence
    structured_candidate = evidence_reference(candidate)
    structured_previous = evidence_reference(previous)

    promoted = @promoter.promote(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, candidate).merge("evidence" => [structured_candidate]),
      previous_certification: certification(CURRENT_TIME, previous).merge("evidence" => [structured_previous]),
      dry_run: true
    )

    assert_equal structured_candidate, promoted.dig("consumers", CONSUMER, "current", "certification", "evidence", 0)

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate).merge(
          "evidence" => [structured_candidate.merge("sha256" => "sha256:#{'0' * 64}")]
        ),
        previous_certification: certification(CURRENT_TIME, previous).merge("evidence" => [structured_previous]),
        dry_run: true
      )
    end
    assert_match(/has sha256=.*expected/, error.message)
  end

  def test_rejects_evidence_coordinates_that_disagree_with_the_tuple
    mutations = {
      "consumer_tree" => lambda { |document| document["consumer_tree"] = "f" * 40 },
      "opencode_ruby.commit" => lambda do |document|
        document["clients"] = {
          "opencode_ruby" => {"version" => "0.0.1.alpha7", "commit" => "f" * 40}
        }
      end,
      "runtime.image" => lambda do |document|
        document["runtime"] = {
          "image" => "ghcr.io/anomalyco/opencode@sha256:#{'f' * 64}",
          "reported_version" => "1.18.3"
        }
      end
    }

    mutations.each do |field, mutate|
      write_manifest(valid_manifest)
      candidate, previous = write_matching_evidence
      path = File.join(@root, candidate.fetch("path"))
      document = JSON.parse(File.read(path))
      mutate.call(document)
      File.write(path, JSON.pretty_generate(document) + "\n")

      error = assert_raises(OpenCodeCompat::PromotionError, field) do
        @promoter.promote(
          consumer: CONSUMER,
          consumer_commit: CANDIDATE_COMMIT,
          certification: certification(CANDIDATE_TIME, candidate),
          previous_certification: certification(CURRENT_TIME, previous),
          dry_run: true
        )
      end
      assert_match(/#{Regexp.escape(field)}/, error.message, field)
    end
  end

  def test_recorded_certifications_require_hash_bound_evidence_references
    candidate, previous = write_matching_evidence
    promoted = @promoter.promote(
      consumer: CONSUMER,
      consumer_commit: CANDIDATE_COMMIT,
      certification: certification(CANDIDATE_TIME, candidate),
      previous_certification: certification(CURRENT_TIME, previous)
    )
    consumer = promoted.dig("consumers", CONSUMER)
    consumer.dig("current", "certification")["evidence"] = [candidate.fetch("path")]
    consumer["candidate"] = {
      "status" => "compatibility-certified",
      "certified_at" => NEXT_TIME,
      "consumer_commit" => NEXT_COMMIT,
      "consumer_tree" => NEXT_TREE,
      "opencode_ruby" => {"version" => "0.0.1.alpha8", "git_commit" => RUBY_NEXT},
      "opencode_rails" => {"version" => "0.0.1.alpha8", "git_commit" => RAILS_NEXT},
      "runtime" => {"image" => NEXT_IMAGE, "reported_version" => "1.19.0"}
    }
    write_manifest(promoted)
    fingerprint = @promoter.fingerprints(
      consumer: CONSUMER,
      consumer_commit: NEXT_COMMIT
    ).fetch("candidate_tuple_sha256")
    next_evidence = write_evidence(
      "next-after-legacy-reference.json",
      commit: NEXT_COMMIT,
      timestamp: NEXT_TIME,
      fingerprint: fingerprint
    )

    error = assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: NEXT_COMMIT,
        certification: certification(NEXT_TIME, next_evidence),
        dry_run: true
      )
    end
    assert_match(/hash-bound \{path, sha256\}/, error.message)
  end

  def test_rejects_non_passing_or_implicit_certification_metadata
    candidate, previous = write_matching_evidence

    assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate).merge("status" => "pending"),
        previous_certification: certification(CURRENT_TIME, previous),
        dry_run: true
      )
    end

    assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification("today", candidate),
        previous_certification: certification(CURRENT_TIME, previous),
        dry_run: true
      )
    end
  end

  def test_rejects_duplicate_or_unversioned_evidence
    candidate, previous = write_matching_evidence

    assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate).merge(
          "evidence" => [candidate.fetch("path"), candidate.fetch("path")]
        ),
        previous_certification: certification(CURRENT_TIME, previous),
        dry_run: true
      )
    end

    path = File.join(@root, candidate.fetch("path"))
    document = JSON.parse(File.read(path))
    document.delete("schema_version")
    File.write(path, JSON.pretty_generate(document) + "\n")
    assert_raises(OpenCodeCompat::PromotionError) do
      @promoter.promote(
        consumer: CONSUMER,
        consumer_commit: CANDIDATE_COMMIT,
        certification: certification(CANDIDATE_TIME, candidate),
        previous_certification: certification(CURRENT_TIME, previous),
        dry_run: true
      )
    end
  end

  private

  def valid_manifest
    {
      "schema_version" => 1,
      "migration_state" => "candidate",
      "consumers" => {
        CONSUMER => {
          "profile" => "rails-persisted-turn",
          "current" => {
            "status" => "observed-production",
            "consumer_commit" => CURRENT_COMMIT,
            "consumer_tree" => CURRENT_TREE,
            "opencode_ruby" => {"version" => "0.0.1.alpha2", "git_commit" => RUBY_CURRENT},
            "opencode_rails" => {"version" => "0.0.1.alpha2", "git_commit" => RAILS_CURRENT},
            "runtime" => {"image" => CURRENT_IMAGE, "reported_version" => "1.16.1"}
          },
          "candidate" => {
            "status" => "compatibility-certified",
            "certified_at" => "2026-07-18T10:00:00Z",
            "consumer_tree" => CANDIDATE_TREE,
            "opencode_ruby" => {"version" => "0.0.1.alpha7", "git_commit" => RUBY_CANDIDATE},
            "opencode_rails" => {"version" => "0.0.1.alpha7", "git_commit" => RAILS_CANDIDATE},
            "runtime" => {"image" => CANDIDATE_IMAGE, "reported_version" => "1.18.3"}
          },
          "previous" => nil
        }
      }
    }
  end

  def write_matching_evidence
    fingerprints = @promoter.fingerprints(consumer: CONSUMER, consumer_commit: CANDIDATE_COMMIT)
    candidate = write_evidence(
      "candidate.json",
      commit: CANDIDATE_COMMIT,
      timestamp: CANDIDATE_TIME,
      fingerprint: fingerprints.fetch("candidate_tuple_sha256")
    )
    previous = write_evidence(
      "previous.json",
      commit: CURRENT_COMMIT,
      timestamp: CURRENT_TIME,
      fingerprint: fingerprints.fetch("current_tuple_sha256")
    )
    [candidate, previous]
  end

  def write_evidence(name, commit:, timestamp:, fingerprint:)
    path = File.join("evidence", name)
    document = {
      "schema_version" => 1,
      "consumer" => CONSUMER,
      "profile" => "rails-persisted-turn",
      "consumer_commit" => commit,
      "status" => "pass",
      "certified_at" => timestamp,
      "tuple_sha256" => fingerprint
    }
    File.write(File.join(@root, path), JSON.pretty_generate(document) + "\n")
    {"path" => path, "tuple_sha256" => fingerprint}
  end

  def certification(timestamp, evidence)
    {
      "status" => "pass",
      "certified_at" => timestamp,
      "evidence" => [evidence.fetch("path")]
    }
  end

  def evidence_reference(evidence)
    path = evidence.fetch("path")
    {
      "path" => path,
      "sha256" => "sha256:#{Digest::SHA256.file(File.join(@root, path)).hexdigest}"
    }
  end

  def manifest_path
    File.join(@root, "manifests", "runtime-tuples.json")
  end

  def write_manifest(manifest)
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  end
end
