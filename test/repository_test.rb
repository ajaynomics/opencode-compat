# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/opencode_compat/runtime_tuple_promoter"

class RepositoryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def json(path)
    JSON.parse(File.read(File.join(ROOT, path)))
  end

  def test_every_json_document_parses
    paths = Dir.glob(File.join(ROOT, "{evidence,fixtures,manifests,profiles}/**/*.json"))
    refute_empty paths
    paths.each { |path| JSON.parse(File.read(path)) }
  end

  def test_fixture_manifest_is_complete_and_unique
    entries = json("fixtures/manifest.json").fetch("fixtures")
    ids = entries.map { |entry| entry.fetch("id") }
    assert_equal ids.uniq, ids

    entries.each do |entry|
      assert_path_exists File.join(ROOT, "fixtures", entry.fetch("events"))
      assert_path_exists File.join(ROOT, "fixtures", entry.fetch("expected"))
    end
  end

  def test_profile_fixture_references_exist
    fixture_ids = json("fixtures/manifest.json").fetch("fixtures").map { |entry| entry.fetch("id") }
    Dir.glob(File.join(ROOT, "profiles/*.json")).each do |path|
      profile = JSON.parse(File.read(path))
      Array(profile["required_fixtures"]).each { |id| assert_includes fixture_ids, id }
    end
  end

  def test_public_matrix_uses_only_immutable_oci_digests
    targets = json("manifests/image-matrix.json").fetch("public_ci")
    refute_empty targets
    targets.each do |target|
      assert_match %r{\Aghcr\.io/anomalyco/opencode@sha256:[0-9a-f]{64}\z}, target.fetch("image")
      refute_includes target.fetch("image"), ":latest"
      assert_equal ["ruby-rest-sse"], target.fetch("profiles")
      assert_equal "shared-client-contract-only",
        target.fetch("certification_scope", "shared-client-contract-only")
      next unless target.fetch("certification_status") == "certified"

      assert_match(/\A[0-9a-f]{40}\z/, target.fetch("certified_client_commit"))
      assert_equal target.fetch("expected_text"), target.fetch("full_text")
      assert_equal 1, target.fetch("llm_request_count")
    end
  end

  def test_candidate_client_train_is_lockstep_and_bound_to_annotated_tags
    candidate = json("manifests/client-candidate.json")
    clients = candidate.fetch("clients")
    release_train = candidate.fetch("release_train")

    assert_equal 2, candidate.fetch("schema_version")
    assert_equal "candidate", candidate.fetch("status")
    assert_equal %w[opencode-rails opencode-ruby], clients.keys.sort

    clients.each do |name, client|
      provenance = client.fetch("tag_provenance")
      assert_equal "ajaynomics/#{name}", client.fetch("repository")
      assert_equal release_train, client.fetch("version")
      assert_match(/\A[0-9a-f]{40}\z/, client.fetch("ref"))
      assert_equal "v#{release_train}", provenance.fetch("tag")
      assert_match(/\A[0-9a-f]{40}\z/, provenance.fetch("annotated_tag_object"))
      assert_equal client.fetch("ref"), provenance.fetch("peeled_commit")
    end

    dependency = clients.fetch("opencode-rails").fetch("runtime_dependencies").fetch("opencode-ruby")
    assert_equal "= #{release_train}", dependency.fetch("requirement")
    assert_equal clients.fetch("opencode-ruby").fetch("ref"), dependency.fetch("ref")
  end

  def test_certified_migration_keeps_previous_tuple
    tuples = json("manifests/runtime-tuples.json")
    return unless tuples.fetch("migration_state") == "certified"

    tuples.fetch("consumers").each_value do |consumer|
      %w[current previous].each do |slot|
        tuple = consumer.fetch(slot)
        assert_equal "certified", tuple.fetch("status")
        assert_equal "pass", tuple.fetch("certification").fetch("status")
        assert_match(/\Asha256:[0-9a-f]{64}\z/, tuple.fetch("certification").fetch("tuple_sha256"))
        refute_empty tuple.fetch("certification").fetch("evidence")
      end
    end
  end

  def test_runtime_tuple_profiles_exist
    tuples = json("manifests/runtime-tuples.json")
    tuples.fetch("consumers").each_value do |consumer|
      profile = consumer.fetch("profile")
      assert_path_exists File.join(ROOT, "profiles", "#{profile}.json")
    end
  end

  def test_runtime_tuples_use_full_commits_and_no_mutable_registry_coordinate
    tuples = json("manifests/runtime-tuples.json")
    tuples.fetch("consumers").each_value do |consumer|
      %w[current candidate previous].each do |slot|
        tuple = consumer[slot]
        next unless tuple

        assert_match(/\A[0-9a-f]{40}\z/, tuple.fetch("consumer_commit"))
        %w[opencode_ruby opencode_rails].each do |client_name|
          client = tuple[client_name]
          assert_match(/\A[0-9a-f]{40}\z/, client.fetch("git_commit")) if client
        end

        runtime = tuple.fetch("runtime")
        if runtime.key?("registry_ref")
          assert_match(/\A[^@\s]+@sha256:[0-9a-f]{64}\z/, runtime.fetch("registry_ref"))
        end
        if runtime.key?("tag_provenance")
          refute_empty runtime.fetch("tag_provenance")
        end
      end
    end
  end

  def test_failed_alpha2_baselines_block_promotion_instead_of_becoming_previous
    tuples = json("manifests/runtime-tuples.json")
    readiness = tuples.fetch("promotion_readiness")

    assert_equal "blocked", readiness.fetch("status")
    assert_path_exists File.join(ROOT, readiness.fetch("evidence"))
    tuples.fetch("consumers").each_value do |consumer|
      assert_equal "observed-production-contract-failed", consumer.dig("current", "status")
      assert_nil consumer.fetch("previous")
    end
  end

  def test_candidate_evidence_is_bound_to_complete_tuple_fingerprints
    promoter = OpenCodeCompat::RuntimeTuplePromoter.new(root: ROOT)
    evidence_paths = {
      "ajent-rails" => "evidence/2026-07-18-ajent-rails-alpha7-candidate.json",
      "travelwolf" => "evidence/2026-07-18-travelwolf-alpha7-candidate.json",
      "mushu" => "evidence/2026-07-18-mushu-alpha7-candidate.json"
    }

    evidence_paths.each do |consumer, path|
      evidence = json(path)
      fingerprints = promoter.fingerprints(
        consumer: consumer,
        consumer_commit: evidence.fetch("consumer_commit")
      )

      assert_equal consumer, evidence.fetch("consumer")
      assert_equal fingerprints.fetch("profile"), evidence.fetch("profile")
      assert_equal fingerprints.fetch("candidate_tuple_sha256"), evidence.fetch("tuple_sha256")
      assert_equal "pass", evidence.fetch("status")
    end
  end

  def test_watcher_has_no_deployment_commands
    workflow = File.read(File.join(ROOT, ".github/workflows/watch-upstream.yml"))
    refute_match(/\b(kamal|kubectl|helm|nomad|docker\s+service)\b/i, workflow)
  end

  def test_workflow_actions_are_pinned_to_exact_commits
    workflows = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}"))
    refute_empty workflows

    workflows.each do |path|
      File.foreach(path).with_index(1) do |line, number|
        next unless (match = line.match(/\buses:\s+[^\s@]+@([^\s#]+)/))

        assert_match(/\A[0-9a-f]{40}\z/, match[1], "#{path}:#{number} must pin an exact action commit")
      end
    end
  end

  def test_candidate_workflow_verifies_and_preserves_the_lockstep_client_tuple
    workflow = File.read(File.join(ROOT, ".github/workflows/candidate.yml"))

    refute_includes workflow, "inputs.opencode_ruby_ref"
    refute_includes workflow, "inputs.opencode_rails_ref"
    assert_includes workflow, "repository: ajaynomics/opencode-ruby"
    assert_includes workflow, "repository: ajaynomics/opencode-rails"
    assert_includes workflow, "ruby: [\"3.2\", \"3.3\", \"3.4\"]"
    assert_includes workflow, "ruby/lockstep_client_contract.rb"
    assert_includes workflow, "OPENCODE_RUBY_TAG_OBJECT"
    assert_includes workflow, "OPENCODE_RAILS_TAG_OBJECT"
    assert_operator workflow.scan("fetch-tags: true").length, :>=, 2
    assert_operator workflow.scan("actions/upload-artifact@").length, :>=, 3
    assert_includes workflow, "OPENCODE_COMPAT_EVIDENCE_PATH"
    assert_includes workflow, "OPENCODE_REQUIRED_CONSUMER_PROFILES"
    assert_includes workflow, 'BUNDLE_PATH: ${{ runner.temp }}/opencode-ruby-bundle'
    assert_includes workflow, "Install candidate dependencies outside the checkout"
    refute_includes workflow, "OPENCODE_MATRIX_PROFILES"
    refute_includes workflow, "OPENCODE_CERTIFICATION_SCOPE"
    refute_match(/\b(kamal|kubectl|helm|nomad|docker\s+service|gh\s+pr\s+merge)\b/i, workflow)
  end

  def test_tuple_promotion_has_no_command_execution_or_deployment_client
    paths = %w[
      lib/opencode_compat/runtime_tuple_promoter.rb
      scripts/promote_runtime_tuple.rb
    ]
    implementation = paths.map { |path| File.read(File.join(ROOT, path)) }.join("\n")

    refute_match(/\b(system|exec|spawn|popen|Open3)\b/, implementation)
    refute_match(/`[^`]+`/, implementation)
    refute_match(/\b(kamal|kubectl|helm|nomad|docker\s+service)\b/i, implementation)
  end

  def test_live_contract_requires_exact_text_and_one_model_request
    probe = File.read(File.join(ROOT, "ruby/live_probe.rb"))
    runner = File.read(File.join(ROOT, "scripts/run_image_contract.sh"))

    assert_includes probe, "ExactLiveContract.assert_final_text!"
    assert_includes probe, "ExactLiveContract.assert_authoritative_assistant_count!"
    refute_includes probe, "full_text.include?"
    assert_includes runner, "exact_live_contract.rb"
    assert_includes runner, "OPENCODE_COMPAT_EVIDENCE_PATH"
    assert_includes runner, "OPENCODE_EXPECTED_VERSION"
    refute_match(/request_count.*-lt\s+1/, runner)
  end
end
