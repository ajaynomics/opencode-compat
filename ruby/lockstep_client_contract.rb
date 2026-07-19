# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rubygems"

module OpenCodeCompat
  class LockstepClientContract
    class ContractError < StandardError; end

    CONTRACT_NAME = "opencode-client-lockstep"
    REQUIRED_ENV = %w[
      OPENCODE_RUBY_PATH
      OPENCODE_RUBY_COMMIT
      OPENCODE_RUBY_TAG
      OPENCODE_RUBY_TAG_OBJECT
      OPENCODE_RUBY_VERSION
      OPENCODE_RAILS_PATH
      OPENCODE_RAILS_COMMIT
      OPENCODE_RAILS_TAG
      OPENCODE_RAILS_TAG_OBJECT
      OPENCODE_RAILS_VERSION
    ].freeze

    def self.from_environment(env: ENV, git_resolver: nil, git_head_resolver: nil)
      require "bundler"
      require "opencode-rails"

      new(
        env: env,
        git_resolver: git_resolver,
        git_head_resolver: git_head_resolver,
        loaded_specs: Gem.loaded_specs,
        bundle_specs: Bundler.load.specs,
        runtime_ruby_version: RUBY_VERSION,
        ruby_version: Opencode::VERSION,
        rails_version: Opencode::RAILS_VERSION
      )
    end

    def self.canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def self.canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h do |key|
          source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          [key, canonicalize(value.fetch(source_key))]
        end
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end
    private_class_method :canonicalize

    def initialize(
      env:,
      loaded_specs:,
      bundle_specs:,
      ruby_version:,
      rails_version:,
      runtime_ruby_version: RUBY_VERSION,
      git_resolver: nil,
      git_head_resolver: nil
    )
      @env = env
      @loaded_specs = loaded_specs
      @bundle_specs = bundle_specs
      @ruby_version = ruby_version.to_s
      @rails_version = rails_version.to_s
      @runtime_ruby_version = runtime_ruby_version.to_s
      @git_resolver = git_resolver || method(:resolve_git)
      @git_head_resolver = git_head_resolver
    end

    def verify
      ensure_required_environment!

      ruby_path = realpath("OPENCODE_RUBY_PATH")
      rails_path = realpath("OPENCODE_RAILS_PATH")
      ruby_commit = exact_commit("OPENCODE_RUBY_COMMIT")
      rails_commit = exact_commit("OPENCODE_RAILS_COMMIT")
      expected_ruby_version = exact_version("OPENCODE_RUBY_VERSION")
      expected_rails_version = exact_version("OPENCODE_RAILS_VERSION")

      assert_equal!(ruby_commit, checkout_head(ruby_path, "opencode-ruby"), "opencode-ruby checkout commit")
      assert_equal!(rails_commit, checkout_head(rails_path, "opencode-rails"), "opencode-rails checkout commit")
      ruby_tag_provenance = annotated_tag_provenance(
        path: ruby_path,
        label: "opencode-ruby",
        tag_name: "OPENCODE_RUBY_TAG",
        tag_object: "OPENCODE_RUBY_TAG_OBJECT",
        expected_commit: ruby_commit
      )
      rails_tag_provenance = annotated_tag_provenance(
        path: rails_path,
        label: "opencode-rails",
        tag_name: "OPENCODE_RAILS_TAG",
        tag_object: "OPENCODE_RAILS_TAG_OBJECT",
        expected_commit: rails_commit
      )
      assert_equal!(expected_ruby_version, @ruby_version, "loaded Opencode::VERSION")
      assert_equal!(expected_rails_version, @rails_version, "loaded Opencode::RAILS_VERSION")
      assert_equal!(expected_ruby_version, expected_rails_version, "lockstep client version")

      ruby_spec = loaded_spec!("opencode-ruby")
      rails_spec = loaded_spec!("opencode-rails")
      assert_equal!(expected_ruby_version, ruby_spec.version.to_s, "loaded opencode-ruby gem version")
      assert_equal!(expected_rails_version, rails_spec.version.to_s, "loaded opencode-rails gem version")
      assert_equal!(rails_path, File.realpath(rails_spec.full_gem_path), "loaded opencode-rails checkout")

      dependency = exact_runtime_dependency!(rails_spec, expected_ruby_version)
      bundle_spec = bundled_ruby_spec!
      source = bundle_spec.source
      unless source && source.respond_to?(:revision) && source.class.name.match?(/(?:\A|::)Git\z/)
        raise ContractError, "Bundler opencode-ruby source must be a Git source"
      end

      bundler_revision = source.revision.to_s
      assert_exact_commit!(bundler_revision, "Bundler opencode-ruby revision")
      assert_equal!(ruby_commit, bundler_revision, "Bundler opencode-ruby revision")

      {
        "contract" => CONTRACT_NAME,
        "opencode_rails" => {
          "checkout_commit" => rails_commit,
          "gem_version" => rails_spec.version.to_s,
          "loaded_version" => @rails_version,
          "tag_provenance" => rails_tag_provenance,
          "runtime_dependency" => {
            "name" => dependency.name,
            "requirement" => dependency.requirement.to_s
          }
        },
        "opencode_ruby" => {
          "bundler_git_revision" => bundler_revision,
          "bundler_source" => source.class.name,
          "checkout_commit" => ruby_commit,
          "gem_version" => ruby_spec.version.to_s,
          "loaded_version" => @ruby_version,
          "tag_provenance" => ruby_tag_provenance
        },
        "ruby_runtime_version" => @runtime_ruby_version,
        "schema_version" => 1,
        "status" => "pass",
        "workflow" => {
          "head_sha" => @env["OPENCODE_COMPAT_HEAD_SHA"],
          "repository" => @env["OPENCODE_COMPAT_REPOSITORY"],
          "run_attempt" => @env["OPENCODE_COMPAT_RUN_ATTEMPT"],
          "run_id" => @env["OPENCODE_COMPAT_RUN_ID"],
          "run_url" => @env["OPENCODE_COMPAT_RUN_URL"]
        }
      }
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ContractError, error.message
    end

    def emit(io: $stdout)
      document = verify
      json = self.class.canonical_json(document)
      evidence_path = @env["OPENCODE_COMPAT_EVIDENCE_PATH"].to_s

      unless evidence_path.empty?
        expanded_path = File.expand_path(evidence_path)
        FileUtils.mkdir_p(File.dirname(expanded_path))
        File.binwrite(expanded_path, "#{json}\n")
      end

      io.puts(json)
      document
    end

    private

    def ensure_required_environment!
      missing = REQUIRED_ENV.select { |name| @env[name].to_s.empty? }
      return if missing.empty?

      raise ContractError, "missing required environment: #{missing.join(', ')}"
    end

    def realpath(name)
      File.realpath(@env.fetch(name))
    end

    def exact_commit(name)
      value = @env.fetch(name)
      assert_exact_commit!(value, name)
      value
    end

    def exact_tag(name)
      value = @env.fetch(name)
      if value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) && !value.include?("..") && !value.end_with?(".")
        return value
      end

      raise ContractError, "#{name} must be a safe exact Git tag name, got #{value.inspect}"
    end

    def exact_tag_object(name)
      value = @env.fetch(name)
      return value if value.match?(/\A[0-9a-f]{40}\z/)

      raise ContractError,
        "#{name} must be a full lowercase 40-character Git object ID, got #{value.inspect}"
    end

    def assert_exact_commit!(value, label)
      return if value.match?(/\A[0-9a-f]{40}\z/)

      raise ContractError, "#{label} must be a full lowercase 40-character Git commit, got #{value.inspect}"
    end

    def exact_version(name)
      value = @env.fetch(name)
      return value if Gem::Version.correct?(value)

      raise ContractError, "#{name} must be an exact RubyGems version, got #{value.inspect}"
    end

    def checkout_head(path, label)
      head = if @git_head_resolver
        @git_head_resolver.call(path).to_s.strip
      else
        git_value(path, "#{label} checkout HEAD", "rev-parse", "--verify", "HEAD^{commit}")
      end
      assert_exact_commit!(head, "#{label} checkout HEAD")
      head
    rescue ContractError
      raise
    rescue StandardError => error
      raise ContractError, "could not resolve #{label} checkout HEAD: #{error.message}"
    end

    def annotated_tag_provenance(path:, label:, tag_name:, tag_object:, expected_commit:)
      tag = exact_tag(tag_name)
      object = exact_tag_object(tag_object)
      tag_ref = "refs/tags/#{tag}"

      object_type = git_value(path, "#{label} annotated tag object type", "cat-file", "-t", object)
      assert_equal!("tag", object_type, "#{label} annotated tag object type")

      resolved_object = git_value(path, "#{label} local tag ref", "rev-parse", "--verify", tag_ref)
      assert_exact_commit!(resolved_object, "#{label} local tag ref object")
      assert_equal!(object, resolved_object, "#{label} local tag ref object")

      object_commit = git_value(path, "#{label} annotated tag peel", "rev-parse", "--verify", "#{object}^{commit}")
      assert_exact_commit!(object_commit, "#{label} annotated tag peeled commit")
      assert_equal!(expected_commit, object_commit, "#{label} annotated tag peeled commit")

      ref_commit = git_value(path, "#{label} local tag ref peel", "rev-parse", "--verify", "#{tag_ref}^{commit}")
      assert_exact_commit!(ref_commit, "#{label} local tag ref peeled commit")
      assert_equal!(expected_commit, ref_commit, "#{label} local tag ref peeled commit")

      {
        "annotated_tag_object" => object,
        "peeled_commit" => object_commit,
        "tag" => tag
      }
    end

    def git_value(path, label, *arguments)
      @git_resolver.call(path, *arguments).to_s.strip
    rescue StandardError => error
      raise ContractError, "could not resolve #{label}: #{error.message}"
    end

    def resolve_git(path, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", path, *arguments)
      return stdout.strip if status.success?

      detail = stderr.strip
      detail = "git exited #{status.exitstatus}" if detail.empty?
      raise ContractError, detail
    end

    def loaded_spec!(name)
      @loaded_specs.fetch(name)
    rescue KeyError
      raise ContractError, "#{name} is not present in Gem.loaded_specs"
    end

    def exact_runtime_dependency!(rails_spec, ruby_version)
      dependencies = rails_spec.runtime_dependencies.select { |dependency| dependency.name == "opencode-ruby" }
      unless dependencies.length == 1
        raise ContractError, "opencode-rails must declare exactly one runtime dependency on opencode-ruby"
      end

      dependency = dependencies.first
      expected = [["=", Gem::Version.new(ruby_version)]]
      unless dependency.requirement.requirements == expected
        raise ContractError,
          "opencode-rails must require opencode-ruby = #{ruby_version}, got #{dependency.requirement}"
      end

      dependency
    end

    def bundled_ruby_spec!
      specs = @bundle_specs.select { |spec| spec.name == "opencode-ruby" }
      return specs.first if specs.length == 1

      raise ContractError, "Bundler must resolve exactly one opencode-ruby spec, found #{specs.length}"
    end

    def assert_equal!(expected, actual, label)
      return if expected == actual

      raise ContractError, "#{label} must equal #{expected.inspect}, got #{actual.inspect}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    OpenCodeCompat::LockstepClientContract.from_environment.emit
  rescue StandardError => error
    failure = OpenCodeCompat::LockstepClientContract.canonical_json(
      "contract" => OpenCodeCompat::LockstepClientContract::CONTRACT_NAME,
      "error" => "#{error.class}: #{error.message}",
      "schema_version" => 1,
      "status" => "fail"
    )
    if (evidence_path = ENV["OPENCODE_COMPAT_EVIDENCE_PATH"]) && !evidence_path.empty?
      expanded_path = File.expand_path(evidence_path)
      FileUtils.mkdir_p(File.dirname(expanded_path))
      File.binwrite(expanded_path, "#{failure}\n")
    end
    warn failure
    exit 1
  end
end
