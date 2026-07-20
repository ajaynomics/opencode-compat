# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class ImageContractEvidenceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNNER = File.join(ROOT, "scripts/run_image_contract.sh")
  VALID_IMAGE = "ghcr.io/anomalyco/opencode@sha256:#{'a' * 64}"

  def setup
    @tmp = Dir.mktmpdir("opencode-image-evidence")
    @bin = File.join(@tmp, "bin")
    @docker_marker = File.join(@tmp, "docker-called")
    FileUtils.mkdir_p(@bin)
    docker = File.join(@bin, "docker")
    File.write(docker, <<~SH)
      #!/usr/bin/env bash
      : >"$DOCKER_CALLED_MARKER"
      exit 99
    SH
    FileUtils.chmod(0o755, docker)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_invalid_input_overwrites_stale_pass_without_touching_docker
    evidence_path = File.join(@tmp, "evidence.json")
    File.write(evidence_path, JSON.generate("status" => "pass"))

    _output, _error, status = run_contract(
      "OPENCODE_IMAGE" => "latest",
      "OPENCODE_RUBY_PATH" => ROOT,
      "OPENCODE_COMPAT_EVIDENCE_PATH" => evidence_path
    )

    assert_equal 2, status.exitstatus
    refute_path_exists @docker_marker
    evidence = JSON.parse(File.read(evidence_path))
    assert_equal "fail", evidence.fetch("status")
    assert_equal 2, evidence.dig("failure", "exit_status")
    assert_equal "latest", evidence.dig("image", "requested")
    assert_equal [], evidence.fetch("executed_profiles")
  end

  def test_rejects_truncated_registry_and_local_image_ids_before_docker
    {
      "ghcr.io/anomalyco/opencode@sha256:#{'a' * 12}" => {},
      "sha256:#{'b' * 12}" => {"ALLOW_EXACT_IMAGE_ID" => "1"}
    }.each_with_index do |(image, extra_environment), index|
      evidence_path = File.join(@tmp, "truncated-#{index}.json")
      _output, error, status = run_contract(
        {
          "OPENCODE_IMAGE" => image,
          "OPENCODE_RUBY_PATH" => ROOT,
          "OPENCODE_COMPAT_EVIDENCE_PATH" => evidence_path
        }.merge(extra_environment)
      )

      assert_equal 2, status.exitstatus
      assert_match(/must be an OCI digest/, error)
      assert_equal image, JSON.parse(File.read(evidence_path)).dig("image", "requested")
    end
    refute_path_exists @docker_marker
  end

  def test_rejects_a_checkout_at_a_different_commit_before_docker
    checkout, _commit = git_checkout
    evidence_path = File.join(@tmp, "mismatch.json")

    _output, error, status = run_contract(
      base_environment(checkout, "f" * 40, evidence_path)
    )

    assert_equal 2, status.exitstatus
    assert_match(/does not match expected commit/, error)
    assert_failed_without_docker(evidence_path)
  end

  def test_rejects_a_dirty_checkout_before_docker
    checkout, commit = git_checkout
    File.write(File.join(checkout, "dirty.txt"), "not certified\n")
    evidence_path = File.join(@tmp, "dirty.json")

    _output, error, status = run_contract(base_environment(checkout, commit, evidence_path))

    assert_equal 2, status.exitstatus
    assert_match(/checkout must be clean/, error)
    assert_failed_without_docker(evidence_path)
  end

  def test_rejects_a_non_git_path_before_docker
    checkout = File.join(@tmp, "not-a-checkout")
    FileUtils.mkdir_p(checkout)
    evidence_path = File.join(@tmp, "not-git.json")

    _output, error, status = run_contract(
      base_environment(checkout, "f" * 40, evidence_path)
    )

    assert_equal 2, status.exitstatus
    assert_match(/readable Git checkout/, error)
    assert_failed_without_docker(evidence_path)
  end

  def test_rejects_malformed_ipv6_and_public_probe_hosts_before_docker
    checkout, commit = git_checkout

    ["not-an-address", "::1", "8.8.8.8"].each_with_index do |probe_host, index|
      evidence_path = File.join(@tmp, "probe-host-#{index}.json")
      environment = base_environment(checkout, commit, evidence_path).merge(
        "OPENCODE_PROBE_HOST" => probe_host
      )

      _output, error, status = run_contract(environment)

      assert_equal 2, status.exitstatus
      assert_match(/loopback or private IPv4 address/, error)
      assert_failed_without_docker(evidence_path)
    end
  end

  private

  def base_environment(checkout, commit, evidence_path)
    {
      "OPENCODE_IMAGE" => VALID_IMAGE,
      "OPENCODE_RUBY_PATH" => checkout,
      "OPENCODE_RUBY_COMMIT" => commit,
      "OPENCODE_COMPAT_EVIDENCE_PATH" => evidence_path
    }
  end

  def run_contract(environment)
    env = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "DOCKER_CALLED_MARKER" => @docker_marker
    }.merge(environment)
    Open3.capture3(env, "bash", RUNNER)
  end

  def git_checkout
    path = File.join(@tmp, "checkout-#{rand(1_000_000)}")
    FileUtils.mkdir_p(path)
    run_git!(path, "init", "--quiet")
    run_git!(path, "config", "user.name", "Compatibility Test")
    run_git!(path, "config", "user.email", "compat@example.test")
    File.write(File.join(path, "tracked.txt"), "clean\n")
    run_git!(path, "add", "tracked.txt")
    run_git!(path, "commit", "--quiet", "-m", "fixture")
    commit = run_git!(path, "rev-parse", "HEAD").strip
    [path, commit]
  end

  def run_git!(path, *arguments)
    output, error, status = Open3.capture3("git", "-C", path, *arguments)
    assert status.success?, error
    output
  end

  def assert_failed_without_docker(evidence_path)
    refute_path_exists @docker_marker
    assert_equal "fail", JSON.parse(File.read(evidence_path)).fetch("status")
  end
end
