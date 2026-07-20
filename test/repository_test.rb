# frozen_string_literal: true

require "json"
require "digest"
require "minitest/autorun"
require_relative "../lib/opencode_compat/client_candidate"
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
    manifest = json("manifests/image-matrix.json")
    assert_equal 2, manifest.fetch("schema_version")
    targets = manifest.fetch("public_ci")
    refute_empty targets
    targets.each do |target|
      assert_match %r{\Aghcr\.io/anomalyco/opencode@sha256:[0-9a-f]{64}\z}, target.fetch("image")
      refute_includes target.fetch("image"), ":latest"
      assert_equal ["ruby-rest-sse"], target.fetch("profiles")
      assert_equal "shared-client-contract-only",
        target.fetch("certification_scope", "shared-client-contract-only")
      assert_equal "certified", target.fetch("certification_status")
      current = target.fetch("current_certification")
      assert_equal "certified", current.fetch("status")
      assert_match(/\A[0-9a-f]{40}\z/, current.fetch("client_commit"))
      assert_match(/\A[0-9a-f]{40}\z/, current.fetch("rails_commit"))
      assert_equal current.fetch("expected_text"), current.fetch("full_text")
      assert_equal 1, current.fetch("llm_request_count")
      assert_path_exists File.join(ROOT, current.fetch("evidence"))
      previous = target["previous_certification"]
      next unless previous

      assert_equal "certified", previous.fetch("status")
      assert_match(/\A[0-9a-f]{40}\z/, previous.fetch("client_commit"))
      assert_equal previous.fetch("expected_text"), previous.fetch("full_text")
      assert_equal 1, previous.fetch("llm_request_count")
    end
  end

  def test_candidate_client_train_is_lockstep_and_bound_to_unpublished_commits
    candidate = json("manifests/client-candidate.json")
    OpenCodeCompat::ClientCandidate.new(candidate).verify!
    clients = candidate.fetch("clients")
    release_train = candidate.fetch("release_train")

    assert_equal 3, candidate.fetch("schema_version")
    assert_equal "candidate", candidate.fetch("status")
    assert_equal "unpublished", candidate.fetch("publication_state")
    assert_equal "0.0.1.alpha8", release_train
    assert_equal %w[opencode-rails opencode-ruby], clients.keys.sort

    clients.each do |name, client|
      provenance = client.fetch("provenance")
      assert_equal "ajaynomics/#{name}", client.fetch("repository")
      assert_equal release_train, client.fetch("version")
      assert_match(/\A[0-9a-f]{40}\z/, client.fetch("ref"))
      assert_equal "commit", provenance.fetch("kind")
      assert_equal client.fetch("ref"), provenance.fetch("commit")
      refute provenance.key?("tag")
    end

    assert_equal "9277646a4bb2cf25a8384ffc140b154f49ea5766", clients.dig("opencode-ruby", "ref")
    assert_equal "a9add2a7c1dd3eb978aa8b4ebf9ef7e111d1057f", clients.dig("opencode-rails", "ref")
    dependency = clients.fetch("opencode-rails").fetch("runtime_dependencies").fetch("opencode-ruby")
    assert_equal "= #{release_train}", dependency.fetch("requirement")
    assert_equal clients.fetch("opencode-ruby").fetch("ref"), dependency.fetch("ref")
  end

  def test_image_matrix_is_certified_and_bound_to_the_exact_unpublished_client_candidate
    candidate = json("manifests/client-candidate.json")
    clients = candidate.fetch("clients")
    matrix_candidate = json("manifests/image-matrix.json").fetch("client_candidate")

    assert_equal "certified", matrix_candidate.fetch("certification_status")
    assert_equal "unpublished", matrix_candidate.fetch("publication_state")
    assert_path_exists File.join(ROOT, matrix_candidate.fetch("evidence"))
    assert_equal candidate.fetch("release_train"), matrix_candidate.fetch("release_train")
    assert_equal candidate.fetch("publication_state"), matrix_candidate.fetch("publication_state")
    assert_equal clients.dig("opencode-ruby", "ref"), matrix_candidate.fetch("opencode_ruby_commit")
    assert_equal clients.dig("opencode-rails", "ref"), matrix_candidate.fetch("opencode_rails_commit")

    json("manifests/image-matrix.json").fetch("host_canary").each do |target|
      assert_equal "certified", target.fetch("certification_status")
      current = target.fetch("current_certification")
      assert_equal "certified", current.fetch("status")
      assert_match(/\A[0-9a-f]{40}\z/, current.fetch("client_commit"))
      assert_path_exists File.join(ROOT, current.fetch("evidence"))
      previous = target.fetch("previous_certification")
      assert_equal "certified", previous.fetch("status")
      assert_match(/\A[0-9a-f]{40}\z/, previous.fetch("client_commit"))
      assert_path_exists File.join(ROOT, previous.fetch("evidence"))
    end
  end

  def test_alpha8_local_image_evidence_is_review_input_not_app_certification
    evidence = json("evidence/2026-07-20-opencode-alpha8-pre-release-shared-client.json")
    candidate = json("manifests/client-candidate.json").fetch("clients")

    assert_equal "not-certified", evidence.fetch("certification_status")
    assert_equal "shared-client-contract-only", evidence.fetch("coverage_scope")
    assert_equal "unpublished", evidence.fetch("publication_state")
    assert_equal candidate.dig("opencode-ruby", "ref"), evidence.dig("clients", "opencode_ruby", "commit")
    assert_equal candidate.dig("opencode-rails", "ref"), evidence.dig("clients", "opencode_rails", "commit")
    assert_equal true, evidence.dig("clients", "opencode_ruby", "executed")
    assert_equal false, evidence.dig("clients", "opencode_rails", "executed_by_image_contract")
    assert_equal 5, evidence.fetch("checks").length
    evidence.fetch("checks").each do |check|
      assert_equal "pass", check.fetch("status")
      assert_equal ["ruby-rest-sse"], check.fetch("executed_profiles")
      assert_equal check.fetch("expected_text"), check.fetch("full_text")
      assert_equal 1, check.fetch("authoritative_assistant_message_count")
      assert_equal 1, check.fetch("llm_request_count")
    end
    assert evidence.fetch("limitations").any? { |entry| entry.include?("remain unverified") }
  end

  def test_alpha8_ci_evidence_certifies_shared_and_lockstep_scopes_without_claiming_apps
    evidence = json("evidence/2026-07-20-opencode-alpha8-shared-client-ci.json")
    candidate = json("manifests/client-candidate.json").fetch("clients")

    assert_equal "pass", evidence.fetch("status")
    assert_equal "unpublished", evidence.fetch("publication_state")
    assert_equal candidate.dig("opencode-ruby", "ref"), evidence.dig("clients", "opencode_ruby", "commit")
    assert_equal candidate.dig("opencode-rails", "ref"), evidence.dig("clients", "opencode_rails", "commit")
    assert_equal "29725021192", evidence.dig("github_workflow", "run_id")
    assert_equal "2717", evidence.dig("gitea_workflow", "run_id")
    assert_equal false, evidence.dig("gitea_workflow", "artifact_evidence_claimed")
    assert_operator evidence.fetch("certified_at"), :>=, evidence.dig("github_workflow", "completed_at")
    assert_operator evidence.fetch("certified_at"), :>=, evidence.dig("gitea_workflow", "completed_at")
    assert_equal %w[3.2.11 3.3.12 3.4.10 4.0.6],
      evidence.fetch("rails_lockstep").map { |entry| entry.fetch("ruby_runtime_version") }
    assert evidence.fetch("rails_lockstep").all? { |entry| entry.fetch("status") == "pass" }
    assert_equal 3, evidence.fetch("exact_image_contracts").length
    evidence.fetch("exact_image_contracts").each do |contract|
      assert_equal "pass", contract.fetch("status")
      assert_equal contract.fetch("expected_text"), contract.fetch("full_text")
      assert_equal 1, contract.fetch("authoritative_assistant_message_count")
      assert_equal 1, contract.fetch("llm_request_count")
    end
    assert evidence.fetch("limitations").any? { |entry| entry.include?("application profile") }
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
      %w[current candidate previous emergency_provenance].each do |slot|
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

  def test_failed_alpha2_baselines_remain_uncertified_emergency_provenance
    tuples = json("manifests/runtime-tuples.json")
    readiness = tuples.fetch("promotion_readiness")

    assert_equal "certified", tuples.fetch("migration_state")
    assert_equal "certified", readiness.fetch("status")
    tuples.fetch("consumers").each_value do |consumer|
      emergency = consumer.fetch("emergency_provenance")
      assert_equal "observed-production-contract-failed", emergency.fetch("status")
      refute emergency.key?("certification")
      assert_equal "certified", consumer.dig("current", "status")
      assert_equal "0.0.1.alpha8", consumer.dig("current", "opencode_ruby", "version")
      assert_equal "certified", consumer.dig("previous", "status")
      assert_equal "0.0.1.alpha7", consumer.dig("previous", "opencode_ruby", "version")
      refute consumer.key?("rollback_state")
    end
  end

  def test_platform_one_click_targets_are_explicitly_uncertified_and_separate
    consumers = json("manifests/runtime-tuples.json").fetch("consumers")

    %w[travelwolf mushu].each do |name|
      rollback = consumers.fetch(name).fetch("immediate_platform_rollback")
      assert_match(/\Auncertified-/, rollback.fetch("status"))
      assert_match(/\A[0-9a-f]{40}\z/, rollback.fetch("consumer_commit"))
      assert_match(/\A[0-9a-f]{40}\z/, rollback.dig("opencode_ruby", "git_commit"))
      refute rollback.key?("certification")
      refute_equal consumers.dig(name, "previous", "consumer_commit"), rollback.fetch("consumer_commit")
    end

    travelwolf_runtime = consumers.dig("travelwolf", "immediate_platform_rollback", "runtime")
    assert_match(/@sha256:[0-9a-f]{64}\z/, travelwolf_runtime.fetch("image"))
    assert_match(/\Asha256:[0-9a-f]{64}\z/, travelwolf_runtime.fetch("application_image_id"))

    mushu_runtime = consumers.dig("mushu", "immediate_platform_rollback", "runtime")
    assert_match(/@sha256:[0-9a-f]{64}\z/, mushu_runtime.fetch("registry_ref"))
    assert_nil mushu_runtime.fetch("application_image")
    assert_equal "not-retained", mushu_runtime.fetch("application_image_provenance")
  end

  def test_certified_tuple_evidence_is_bound_to_complete_tuple_fingerprints
    promoter = OpenCodeCompat::RuntimeTuplePromoter.new(root: ROOT)

    json("manifests/runtime-tuples.json").fetch("consumers").each do |consumer, entry|
      profile = entry.fetch("profile")
      %w[current previous].each do |slot|
        tuple = entry.fetch(slot)
        fingerprint = promoter.send(:tuple_fingerprint, tuple, consumer: consumer, profile: profile)
        certification = tuple.fetch("certification")
        promoter.send(
          :validate_recorded_certification!,
          tuple,
          consumer: consumer,
          profile: profile,
          expected_fingerprint: fingerprint,
          label: "#{consumer} #{slot}"
        )

        assert_equal "certified", tuple.fetch("status")
        assert_equal "pass", certification.fetch("status")
        assert_equal fingerprint, certification.fetch("tuple_sha256")
        refute_empty certification.fetch("evidence")

        certification.fetch("evidence").each do |reference|
          assert_equal %w[path sha256], reference.keys.sort
          path = reference.fetch("path")
          bytes = File.binread(File.join(ROOT, path))
          assert_equal "sha256:#{Digest::SHA256.hexdigest(bytes)}", reference.fetch("sha256")
          evidence = json(path)
          assert_equal consumer, evidence.fetch("consumer")
          assert_equal profile, evidence.fetch("profile")
          assert_equal tuple.fetch("consumer_commit"), evidence.fetch("consumer_commit")
          assert_equal certification.fetch("certified_at"), evidence.fetch("certified_at")
          assert_equal fingerprint, evidence.fetch("tuple_sha256")
          assert_equal "pass", evidence.fetch("status")
        end
      end
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

  def test_workflow_actions_use_reviewed_node24_compatible_pins
    expected = {
      "actions/checkout" => "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
      "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
      "ruby/setup-ruby" => "003a5c4d8d6321bd302e38f6f0ec593f77f06600"
    }
    observed = Hash.new { |hash, key| hash[key] = [] }

    Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).each do |path|
      File.read(path).scan(/\buses:\s+([^\s@]+)@([0-9a-f]{40})/) do |action, commit|
        observed[action] << commit if expected.key?(action)
      end
    end

    expected.each do |action, commit|
      refute_empty observed.fetch(action), "expected at least one #{action} use"
      assert_equal [commit], observed.fetch(action).uniq, "#{action} must stay on the reviewed Node 24 pin"
    end
  end

  def test_candidate_workflow_verifies_and_preserves_the_lockstep_client_tuple
    workflow = File.read(File.join(ROOT, ".github/workflows/candidate.yml"))

    refute_includes workflow, "inputs.opencode_ruby_ref"
    refute_includes workflow, "inputs.opencode_rails_ref"
    assert_includes workflow, "repository: ajaynomics/opencode-ruby"
    assert_includes workflow, "repository: ajaynomics/opencode-rails"
    assert_includes workflow, "path: opencode-rails"
    assert_includes workflow, "ruby: [\"3.2\", \"3.3\", \"3.4\", \"4.0\"]"
    assert_includes workflow, "scripts/client_candidate_outputs.rb"
    assert_includes workflow, "OPENCODE_CLIENT_PUBLICATION_STATE"
    assert_includes workflow, "OPENCODE_RUBY_PROVENANCE_KIND"
    assert_includes workflow, "OPENCODE_RAILS_PROVENANCE_KIND"
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

  def test_candidate_workflow_has_an_explicit_dual_forge_evidence_boundary
    workflow = File.read(File.join(ROOT, ".github/workflows/candidate.yml"))
    upload_conditions = workflow.scan(
      /- name: Upload (?:fixture|lockstep|exact-image) evidence\n\s+if: ([^\n]+)\n\s+uses: actions\/upload-artifact@/
    ).flatten

    assert_equal 3, upload_conditions.length
    assert_equal ["always() && github.server_url == 'https://github.com'"], upload_conditions.uniq
    assert_includes workflow, "bundler-cache: ${{ github.server_url == 'https://github.com' }}"
    assert_includes workflow, "exact-image-contract-gitea:"
    assert_includes workflow, "if: github.server_url != 'https://github.com'"
    assert_includes workflow, "run: scripts/run_image_matrix_contract.sh"
    assert_includes workflow, 'probe_host="$(ruby scripts/private_default_gateway.rb)"'
    assert_includes workflow, 'echo "OPENCODE_PROBE_HOST=$probe_host" >> "$GITHUB_ENV"'
    assert_operator workflow.scan('BUNDLE_GEMFILE: ${{ github.workspace }}/ruby-client/Gemfile').length, :>=, 2
    assert_operator workflow.scan("generated JSON is transient and is not review evidence").length, :>=, 3

    gitea_job = workflow.split(/^  exact-image-contract-gitea:\n/, 2).fetch(1)
    refute_includes gitea_job, "actions/upload-artifact@"
  end

  def test_gitea_matrix_runner_uses_every_generated_entry_without_hardcoded_coordinates
    runner = File.read(File.join(ROOT, "scripts/run_image_matrix_contract.sh"))

    assert_includes runner, 'matrix_json="$(ruby "$repo_root/scripts/matrix_json.rb")"'
    assert_includes runner, 'for ((index = 0; index < entry_count; index++))'
    assert_includes runner, 'bundle exec "$repo_root/scripts/run_image_contract.sh"'
    assert_includes runner, '.image.reported_version == $version'
    refute_match(/upstream-[0-9]/, runner)
    refute_match(/ghcr\.io\/anomalyco/, runner)
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
    assert_includes runner, 'docker cp "$repo_root/scripts/fake_llm.py"'
    refute_includes runner, '--volume "$repo_root/scripts:/compat:ro"'
    assert_includes runner, '--publish "${probe_host}::4096"'
    assert_includes runner, 'base_url="http://${probe_host}:${host_port}"'
    refute_includes runner, "--publish 0.0.0.0"
    assert_includes runner, "OPENCODE_COMPAT_EVIDENCE_PATH"
    assert_includes runner, "OPENCODE_EXPECTED_VERSION"
    refute_match(/request_count.*-lt\s+1/, runner)
  end
end
