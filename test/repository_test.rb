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
    paths = Dir.glob(File.join(ROOT, "{evidence,fixtures,manifests,profiles,schemas}/**/*.json"))
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

  def test_only_ruby_rest_sse_can_be_certified_by_the_shared_ruby_probe
    Dir.glob(File.join(ROOT, "profiles/*.json")).each do |path|
      profile = JSON.parse(File.read(path))
      if profile.fetch("id") == "ruby-rest-sse"
        assert_equal "shared-ruby-fixture-and-live-probe", profile.fetch("certification_mode")
        assert_equal true, profile.fetch("shared_ruby_probe_sufficient")
      else
        assert_equal "executable-consumer-attestation", profile.fetch("certification_mode")
        assert_equal false, profile.fetch("shared_ruby_probe_sufficient")
      end
    end
  end

  def test_public_matrix_uses_only_immutable_oci_digests
    targets = json("manifests/image-matrix.json").fetch("public_ci")
    refute_empty targets
    targets.each do |target|
      assert_match %r{\Aghcr\.io/anomalyco/opencode@sha256:[0-9a-f]{64}\z}, target.fetch("image")
      refute_includes target.fetch("image"), ":latest"
      refute_empty target.fetch("profiles")
      next unless target.fetch("certification_status") == "certified"

      assert_match(/\A[0-9a-f]{40}\z/, target.fetch("certified_client_commit"))
      assert_equal target.fetch("expected_text"), target.fetch("full_text")
      assert_equal 1, target.fetch("llm_request_count")
    end
  end

  def test_candidate_is_bound_to_an_annotated_tag
    candidate = json("manifests/client-candidate.json")
    provenance = candidate.fetch("tag_provenance")

    assert_match(/\A[0-9a-f]{40}\z/, candidate.fetch("ref"))
    assert_match(/\Av\d+\.\d+\.\d+\.alpha\d+\z/, provenance.fetch("tag"))
    assert_match(/\A[0-9a-f]{40}\z/, provenance.fetch("annotated_tag_object"))
    assert_equal candidate.fetch("ref"), provenance.fetch("peeled_commit")
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
    schema = json("schemas/runtime-tuples.schema.json")

    assert_equal 2, tuples.fetch("schema_version")
    assert_equal 2, schema.dig("properties", "schema_version", "const")
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

  def test_pull_request_heads_are_explicitly_candidate_only
    tuples = json("manifests/runtime-tuples.json")

    tuples.fetch("consumers").each do |name, consumer|
      candidate = consumer.fetch("candidate")
      reference = candidate.fetch("consumer_ref")

      assert_equal "pre-merge-pr-head-candidate-only", candidate.fetch("certification_scope"), name
      assert_equal false, candidate.fetch("promotion_eligible"), name
      assert_equal "pull-request-head", reference.fetch("kind"), name
      assert_equal candidate.fetch("consumer_commit"), reference.fetch("commit"), name
      assert_match(/\A[0-9a-f]{40}\z/, reference.fetch("tree"), name)
      assert_match(%r{\Ahttps://.+/pulls/\d+\z}, reference.fetch("review_url"), name)
    end
  end

  def test_candidate_gems_use_peeled_refs_and_loaded_source_proof
    tuples = json("manifests/runtime-tuples.json")

    tuples.fetch("consumers").each do |consumer_name, consumer|
      candidate = consumer.fetch("candidate")
      %w[opencode_ruby opencode_rails].each do |client_name|
        client = candidate[client_name]
        next unless client

        commit = client.fetch("git_commit")
        source = client.fetch("source")
        proof = source.fetch("loaded_source_proof")

        assert_equal "git", source.fetch("type"), "#{consumer_name} #{client_name}"
        assert_equal commit, source.fetch("requested_ref"), "#{consumer_name} #{client_name}"
        assert_equal commit, source.fetch("locked_revision"), "#{consumer_name} #{client_name}"
        assert_equal "pass", proof.fetch("status"), "#{consumer_name} #{client_name}"
        assert_equal "Bundler::Source::Git", proof.fetch("source_class"), "#{consumer_name} #{client_name}"
        assert_equal client.fetch("version"), proof.fetch("loaded_version"), "#{consumer_name} #{client_name}"
        assert_equal commit, proof.fetch("observed_ref"), "#{consumer_name} #{client_name}" if proof.key?("observed_ref")
        assert_equal commit, proof.fetch("observed_revision"), "#{consumer_name} #{client_name}"
        refute_empty proof.fetch("test"), "#{consumer_name} #{client_name}"
      end
    end
  end

  def test_ajent_records_current_selection_drift_and_exact_candidate_selection
    ajent = json("manifests/runtime-tuples.json").fetch("consumers").fetch("ajent-rails")
    expected_products = %w[aigl blackline raven]

    current_runtime = ajent.fetch("current").fetch("runtime")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, current_runtime.fetch("docker_image_id"))
    deployed = current_runtime.fetch("deployed_product_selection")
    assert_equal "mutable-latest", deployed.fetch("strategy")
    assert_equal "observed-configuration-drift-failure", deployed.fetch("status")
    assert_equal expected_products, deployed.fetch("references").keys.sort
    deployed.fetch("references").each_value { |reference| assert reference.end_with?(":latest") }

    built = current_runtime.fetch("ci_built_product_images")
    assert_equal expected_products, built.keys.sort
    built.each_value do |coordinate|
      assert_match(/\Asha256:[0-9a-f]{64}\z/, coordinate.fetch("docker_image_id"))
      assert_equal ajent.dig("current", "consumer_commit"), coordinate.fetch("source_commit")
    end

    candidate_runtime = ajent.fetch("candidate").fetch("runtime")
    selected = candidate_runtime.fetch("product_selection")
    assert_equal expected_products, selected.fetch("references").keys.sort
    selected.fetch("references").each_value do |reference|
      assert reference.end_with?(":#{ajent.dig('candidate', 'consumer_commit')}")
      refute reference.end_with?(":latest")
    end
    assert_equal ["blackline"], candidate_runtime.fetch("product_images").keys
    assert_includes ajent.dig("candidate", "promotion_blockers"),
      "aigl-and-raven-candidate-content-artifacts-have-not-been-built-and-canaried"
  end

  def test_manifest_candidates_cannot_be_promoted_from_pre_merge_evidence
    promoter = OpenCodeCompat::RuntimeTuplePromoter.new(root: ROOT)
    tuples = json("manifests/runtime-tuples.json")

    tuples.fetch("consumers").each do |name, consumer|
      error = assert_raises(OpenCodeCompat::PromotionError) do
        promoter.promote(
          consumer: name,
          consumer_commit: consumer.dig("candidate", "consumer_commit"),
          certification: {},
          dry_run: true
        )
      end
      assert_match(/pre-merge pull-request evidence is candidate-only/, error.message)
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
      assert_equal "pre-merge-pr-head-candidate-only", evidence.fetch("certification_scope")
      assert_equal false, evidence.fetch("promotion_eligible")
      assert_equal "pass", evidence.fetch("status")
    end
  end

  def test_watcher_has_no_deployment_commands
    workflow = File.read(File.join(ROOT, ".github/workflows/watch-upstream.yml"))
    refute_match(/\b(kamal|kubectl|helm|nomad|docker\s+service)\b/i, workflow)
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
    refute_includes probe, "full_text.include?"
    assert_includes runner, "exact_live_contract.rb"
    refute_match(/request_count.*-lt\s+1/, runner)
  end
end
