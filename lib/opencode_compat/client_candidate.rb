# frozen_string_literal: true

require "json"
require "rubygems"

module OpenCodeCompat
  class ClientCandidate
    class ValidationError < StandardError; end

    SCHEMA_VERSION = 3
    CLIENT_NAMES = %w[opencode-rails opencode-ruby].freeze
    PUBLICATION_PROVENANCE = {
      "published" => "annotated-tag",
      "unpublished" => "commit"
    }.freeze
    SHA_PATTERN = /\A[0-9a-f]{40}\z/

    def self.load(path)
      new(JSON.parse(File.binread(path)))
    rescue JSON::ParserError => error
      raise ValidationError, "client candidate is not valid JSON: #{error.message}"
    end

    attr_reader :document

    def initialize(document)
      @document = document
    end

    def verify!
      assert_exact_keys!(document,
        %w[clients publication_state release_train schema_version status], "client candidate")
      assert_equal!(SCHEMA_VERSION, document.fetch("schema_version"), "schema_version")
      assert_equal!("candidate", document.fetch("status"), "status")

      release_train = exact_version!(document.fetch("release_train"), "release_train")
      publication_state = document.fetch("publication_state")
      expected_kind = PUBLICATION_PROVENANCE.fetch(publication_state) do
        raise ValidationError,
          "publication_state must be one of #{PUBLICATION_PROVENANCE.keys.join(', ')}, got #{publication_state.inspect}"
      end

      clients = document.fetch("clients")
      assert_equal!(CLIENT_NAMES, clients.keys.sort, "client names")
      clients.each do |name, client|
        validate_client!(name, client, release_train, expected_kind)
      end
      validate_runtime_dependency!(clients, release_train)

      self
    rescue KeyError => error
      raise ValidationError, "client candidate is missing required field #{error.key.inspect}"
    end

    def github_outputs
      verify!
      clients = document.fetch("clients")

      {
        "publication_state" => document.fetch("publication_state"),
        "ruby_provenance_kind" => provenance(clients, "opencode-ruby").fetch("kind"),
        "ruby_ref" => clients.dig("opencode-ruby", "ref"),
        "ruby_tag" => provenance(clients, "opencode-ruby")["tag"].to_s,
        "ruby_tag_object" => provenance(clients, "opencode-ruby")["annotated_tag_object"].to_s,
        "ruby_version" => clients.dig("opencode-ruby", "version"),
        "rails_provenance_kind" => provenance(clients, "opencode-rails").fetch("kind"),
        "rails_ref" => clients.dig("opencode-rails", "ref"),
        "rails_tag" => provenance(clients, "opencode-rails")["tag"].to_s,
        "rails_tag_object" => provenance(clients, "opencode-rails")["annotated_tag_object"].to_s,
        "rails_version" => clients.dig("opencode-rails", "version")
      }
    end

    private

    def validate_client!(name, client, release_train, expected_kind)
      expected_keys = %w[provenance ref repository version]
      expected_keys << "runtime_dependencies" if name == "opencode-rails"
      assert_exact_keys!(client, expected_keys.sort, "#{name} candidate")
      assert_equal!("ajaynomics/#{name}", client.fetch("repository"), "#{name} repository")
      assert_equal!(release_train, exact_version!(client.fetch("version"), "#{name} version"), "#{name} version")

      ref = exact_commit!(client.fetch("ref"), "#{name} ref")
      source = client.fetch("provenance")
      assert_equal!(expected_kind, source.fetch("kind"), "#{name} provenance kind")

      case expected_kind
      when "commit"
        assert_exact_keys!(source, %w[commit kind], "#{name} commit provenance")
        assert_equal!(ref, exact_commit!(source.fetch("commit"), "#{name} provenance commit"),
          "#{name} provenance commit")
      when "annotated-tag"
        assert_exact_keys!(source, %w[annotated_tag_object kind peeled_commit tag],
          "#{name} annotated-tag provenance")
        assert_equal!("v#{release_train}", exact_tag!(source.fetch("tag"), "#{name} tag"), "#{name} tag")
        exact_commit!(source.fetch("annotated_tag_object"), "#{name} annotated tag object")
        assert_equal!(ref, exact_commit!(source.fetch("peeled_commit"), "#{name} peeled commit"),
          "#{name} peeled commit")
      end
    end

    def validate_runtime_dependency!(clients, release_train)
      dependency = clients.fetch("opencode-rails")
        .fetch("runtime_dependencies")
        .fetch("opencode-ruby")
      assert_exact_keys!(dependency, %w[ref requirement], "opencode-rails runtime dependency")
      assert_equal!("= #{release_train}", dependency.fetch("requirement"),
        "opencode-rails runtime dependency requirement")
      assert_equal!(clients.dig("opencode-ruby", "ref"),
        exact_commit!(dependency.fetch("ref"), "opencode-rails runtime dependency ref"),
        "opencode-rails runtime dependency ref")
    end

    def provenance(clients, name)
      clients.fetch(name).fetch("provenance")
    end

    def exact_commit!(value, label)
      return value if value.is_a?(String) && value.match?(SHA_PATTERN)

      raise ValidationError, "#{label} must be a full lowercase 40-character Git commit, got #{value.inspect}"
    end

    def exact_tag!(value, label)
      if value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) &&
          !value.include?("..") && !value.end_with?(".")
        return value
      end

      raise ValidationError, "#{label} must be a safe exact Git tag, got #{value.inspect}"
    end

    def exact_version!(value, label)
      if value.is_a?(String) && value.match?(/\A[0-9A-Za-z][0-9A-Za-z.-]*\z/) && Gem::Version.correct?(value)
        return value
      end

      raise ValidationError, "#{label} must be an exact RubyGems version, got #{value.inspect}"
    end

    def assert_exact_keys!(value, expected, label)
      actual = value.keys.sort
      return if actual == expected

      raise ValidationError, "#{label} keys must equal #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_equal!(expected, actual, label)
      return if expected == actual

      raise ValidationError, "#{label} must equal #{expected.inspect}, got #{actual.inspect}"
    end
  end
end
