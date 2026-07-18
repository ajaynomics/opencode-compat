# frozen_string_literal: true

require "json"
require "minitest/autorun"

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
      refute_empty target.fetch("profiles")
    end
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
end
