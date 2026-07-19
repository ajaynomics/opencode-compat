# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class WatcherTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBY = RbConfig.ruby

  def setup
    @tmp = Dir.mktmpdir("opencode-watcher")
    FileUtils.mkdir_p(File.join(@tmp, "scripts"))
    FileUtils.mkdir_p(File.join(@tmp, "manifests"))
    FileUtils.cp(File.join(ROOT, "scripts/record_upstream_candidate.rb"), File.join(@tmp, "scripts"))
    %w[upstream.json image-matrix.json].each do |name|
      FileUtils.cp(File.join(ROOT, "manifests", name), File.join(@tmp, "manifests"))
    end
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_same_tag_and_digest_is_an_exact_noop
    upstream = read_json("manifests/upstream.json")
    before = watched_bytes

    run_recorder!(
      upstream.fetch("release_tag"),
      upstream.fetch("published_at"),
      upstream.fetch("release_url"),
      upstream.fetch("image").split("@").last
    )

    assert_equal before, watched_bytes
  end

  def test_same_tag_and_digest_repairs_a_missing_public_target_then_noops
    upstream = read_json("manifests/upstream.json")
    matrix = read_json("manifests/image-matrix.json")
    image = upstream.fetch("image")
    matrix.fetch("public_ci").reject! { |target| target.fetch("image") == image }
    write_json("manifests/image-matrix.json", matrix)
    upstream_before = File.binread(File.join(@tmp, "manifests/upstream.json"))

    arguments = [
      upstream.fetch("release_tag"),
      upstream.fetch("published_at"),
      upstream.fetch("release_url"),
      image.split("@").last
    ]
    run_recorder!(*arguments)

    repaired = read_json("manifests/image-matrix.json")
    targets = repaired.fetch("public_ci").select { |target| target.fetch("image") == image }
    assert_equal 1, targets.length
    assert_equal "pending", targets.first.fetch("certification_status")
    assert_equal ["ruby-rest-sse"], targets.first.fetch("profiles")
    assert_equal upstream_before, File.binread(File.join(@tmp, "manifests/upstream.json"))

    after = watched_bytes
    run_recorder!(*arguments)
    assert_equal after, watched_bytes
  end

  def test_duplicate_public_targets_are_rejected_without_writing_either_manifest
    upstream = read_json("manifests/upstream.json")
    matrix = read_json("manifests/image-matrix.json")
    target = matrix.fetch("public_ci").find { |entry| entry.fetch("image") == upstream.fetch("image") }
    duplicate = target.merge("id" => "#{target.fetch('id')}-duplicate")
    matrix.fetch("public_ci") << duplicate
    write_json("manifests/image-matrix.json", matrix)
    before = watched_bytes

    _output, error, status = capture_recorder(
      upstream.fetch("release_tag"),
      upstream.fetch("published_at"),
      upstream.fetch("release_url"),
      upstream.fetch("image").split("@").last
    )

    refute status.success?
    assert_match(/must appear exactly once in public_ci; found 2/, error)
    assert_equal before, watched_bytes
  end

  def test_missing_public_target_with_conflicting_generated_id_is_rejected_without_writing
    upstream = read_json("manifests/upstream.json")
    matrix = read_json("manifests/image-matrix.json")
    image = upstream.fetch("image")
    removed = matrix.fetch("public_ci").find { |target| target.fetch("image") == image }
    matrix.fetch("public_ci").reject! { |target| target.fetch("image") == image }
    matrix.fetch("public_ci") << removed.merge(
      "id" => "upstream-#{upstream.fetch('version')}-#{image.split('sha256:').last}",
      "image" => "ghcr.io/anomalyco/opencode@sha256:#{'e' * 64}"
    )
    write_json("manifests/image-matrix.json", matrix)
    before = watched_bytes

    _output, error, status = capture_recorder(
      upstream.fetch("release_tag"),
      upstream.fetch("published_at"),
      upstream.fetch("release_url"),
      image.split("@").last
    )

    refute status.success?
    assert_match(/public_ci id .* is already used by another image/, error)
    assert_equal before, watched_bytes
  end

  def test_same_tag_with_new_digest_records_a_distinct_pending_target_once
    upstream = read_json("manifests/upstream.json")
    replacement = "sha256:#{'f' * 64}"
    arguments = [
      upstream.fetch("release_tag"),
      upstream.fetch("published_at"),
      upstream.fetch("release_url"),
      replacement
    ]

    run_recorder!(*arguments)
    changed_upstream = read_json("manifests/upstream.json")
    matrix = read_json("manifests/image-matrix.json")
    target = matrix.fetch("public_ci").last

    assert_equal "ghcr.io/anomalyco/opencode@#{replacement}", changed_upstream.fetch("image")
    expected_version = upstream.fetch("release_tag").delete_prefix("v")
    assert_equal "upstream-#{expected_version}-#{'f' * 64}", target.fetch("id")
    assert_equal "ghcr.io/anomalyco/opencode@#{replacement}", target.fetch("image")
    assert_equal "pending", target.fetch("certification_status")
    assert_equal "shared-client-contract-only", target.fetch("certification_scope")
    assert_empty target.fetch("consumers")
    assert_empty target.fetch("required_consumer_profiles")

    after = watched_bytes
    run_recorder!(*arguments)
    assert_equal after, watched_bytes
  end

  def test_recorder_rejects_untrusted_release_metadata
    upstream = read_json("manifests/upstream.json")
    digest = upstream.fetch("image").split("@").last

    refute recorder_status("branch-name", upstream.fetch("published_at"), upstream.fetch("release_url"), digest).success?
    refute recorder_status(upstream.fetch("release_tag"), "yesterday", upstream.fetch("release_url"), digest).success?
    refute recorder_status(upstream.fetch("release_tag"), upstream.fetch("published_at"), "https://example.test/release", digest).success?
    refute recorder_status(upstream.fetch("release_tag"), upstream.fetch("published_at"), upstream.fetch("release_url"), "sha256:nope").success?
  end

  def test_branch_names_bind_the_full_tag_and_digest_and_support_retries
    script = File.join(ROOT, "scripts/upstream_branch_name.rb")
    digest = "sha256:#{'a' * 64}"
    replacement = "sha256:#{'b' * 64}"

    base = run_script!(script, "v1.18.3", digest).strip
    changed = run_script!(script, "v1.18.3", replacement).strip
    retry_branch = run_script!(script, "v1.18.3", digest, "123-2").strip

    assert_equal "compat/upstream-1.18.3-#{'a' * 64}", base
    refute_equal base, changed
    assert_equal "#{base}-r123-2", retry_branch
    refute run_status(script, "v1.18.3", digest, "bad/value").success?
  end

  def test_workflow_can_only_update_manifests_and_open_a_pr
    workflow = File.read(File.join(ROOT, ".github/workflows/watch-upstream.yml"))

    assert_includes workflow, "contents: write"
    assert_includes workflow, "pull-requests: write"
    assert_includes workflow, "git add manifests/image-matrix.json manifests/upstream.json"
    assert_includes workflow, "gh pr create"
    assert_includes workflow, "scripts/upstream_branch_name.rb"
    assert_includes workflow, "git ls-remote --exit-code --heads"
    assert_includes workflow, "--base main"
    assert_includes workflow, ".baseRefName == \"main\""
    assert_includes workflow, "isCrossRepository == false"
    assert_includes workflow, "headRefOid"
    assert_includes workflow, "application/vnd.github.raw+json"
    assert_includes workflow, "current_image_count"
    assert_includes workflow, '[.public_ci[]? | select(.image == $image)] | length'
    assert_includes workflow, '[ "$current_image_count" -eq 1 ]'
    assert_includes workflow, ".release_tag == $tag and .image == $image"
    assert_includes workflow, "([.public_ci[]? | select(.image == $image)] | length) == 1"
    content_check = workflow.index(".release_tag == $tag and .image == $image")
    skip = workflow.index('echo "skip=true"')
    assert_operator content_check, :<, skip
    refute_match(/gh\s+pr\s+merge|repository_dispatch|workflow_dispatches|git\s+push\s+--force/i, workflow)
    refute_match(/\b(kamal|kubectl|helm|nomad|docker\s+service)\b/i, workflow)
  end

  private

  def run_recorder!(*arguments)
    run_script!(File.join(@tmp, "scripts/record_upstream_candidate.rb"), *arguments)
  end

  def recorder_status(*arguments)
    run_status(File.join(@tmp, "scripts/record_upstream_candidate.rb"), *arguments)
  end

  def capture_recorder(*arguments)
    Open3.capture3(RUBY, File.join(@tmp, "scripts/record_upstream_candidate.rb"), *arguments)
  end

  def run_script!(script, *arguments)
    output, error, status = Open3.capture3(RUBY, script, *arguments)
    assert status.success?, error
    output
  end

  def run_status(script, *arguments)
    _output, _error, status = Open3.capture3(RUBY, script, *arguments)
    status
  end

  def read_json(relative_path)
    JSON.parse(File.read(File.join(@tmp, relative_path)))
  end

  def write_json(relative_path, value)
    File.write(File.join(@tmp, relative_path), JSON.pretty_generate(value) + "\n")
  end

  def watched_bytes
    %w[manifests/upstream.json manifests/image-matrix.json].map do |relative_path|
      File.binread(File.join(@tmp, relative_path))
    end
  end
end
