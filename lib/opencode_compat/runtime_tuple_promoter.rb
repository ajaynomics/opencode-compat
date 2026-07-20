# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "tempfile"
require "time"

module OpenCodeCompat
  class PromotionError < StandardError; end

  class RuntimeTuplePromoter
    FULL_COMMIT = /\A[0-9a-f]{40}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    IMMUTABLE_IMAGE = /\A[^@\s]+@sha256:[0-9a-f]{64}\z/
    UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/
    CERTIFICATION_STATUS = "pass"
    DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT =
      "accept-degraded-rollback-with-failed-emergency-provenance"
    NON_CERTIFIABLE_TUPLE_STATUSES = %w[observed-production-contract-failed].freeze
    TUPLE_METADATA_KEYS = %w[
      certification
      certified_at
      compatibility_certified_at
      promoted_at
      status
    ].freeze
    EXACT_IMAGE_REFERENCE_KEYS = %w[
      base_image
      image
      registry_ref
      source_image
      upstream_base
    ].freeze
    EVIDENCE_REFERENCE_KEYS = %w[path sha256].freeze
    NULLABLE_COMMIT_KEYS = %w[build_source_commit].freeze
    EVIDENCE_RUNTIME_KEY_MAP = {
      "custom_opencode_source_commit" => "source_commit"
    }.freeze
    EVIDENCE_RUNTIME_COORDINATE_KEYS = %w[
      application_image
      application_image_id
      base_image
      build_source_commit
      docker_image_id
      image
      provenance_strength
      registry_ref
      reported_version
      source_commit
      source_image
      tag_provenance
      upstream_base
    ].freeze

    def initialize(root:, manifest_path: File.join(root, "manifests/runtime-tuples.json"))
      @root = File.realpath(root)
      @manifest_path = File.expand_path(manifest_path)
    end

    def fingerprints(consumer:, consumer_commit:)
      validate_full_commit!(consumer_commit, "consumer commit")
      manifest = read_manifest
      consumer_entry = fetch_consumer!(manifest, consumer)
      profile = fetch_profile!(consumer_entry, consumer)
      candidate = prepare_candidate!(consumer_entry, consumer_commit)
      current = consumer_entry.fetch("current") do
        raise PromotionError, "#{consumer} has no current tuple to preserve as previous"
      end
      validate_tuple!(current, "#{consumer} current")

      {
        "consumer" => consumer,
        "profile" => profile,
        "candidate_tuple_sha256" => tuple_fingerprint(candidate, consumer: consumer, profile: profile),
        "current_tuple_sha256" => tuple_fingerprint(current, consumer: consumer, profile: profile)
      }
    end

    def promote(consumer:, consumer_commit:, certification:, previous_certification: nil, dry_run: false)
      validate_full_commit!(consumer_commit, "consumer commit")

      if dry_run
        manifest = read_manifest
        return promote_manifest(
          manifest,
          consumer: consumer,
          consumer_commit: consumer_commit,
          certification: certification,
          previous_certification: previous_certification
        )
      end

      with_current_manifest_lock do |manifest|
        promoted = promote_manifest(
          manifest,
          consumer: consumer,
          consumer_commit: consumer_commit,
          certification: certification,
          previous_certification: previous_certification
        )
        atomic_write(promoted)
        promoted
      end
    end

    def bootstrap_current(consumer:, consumer_commit:, certification:, acknowledgement:, dry_run: false)
      validate_full_commit!(consumer_commit, "consumer commit")
      unless acknowledgement == DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT
        raise PromotionError,
              "bootstrap requires explicit acknowledgement #{DEGRADED_BOOTSTRAP_ACKNOWLEDGEMENT.inspect}"
      end

      if dry_run
        manifest = read_manifest
        return bootstrap_current_manifest(
          manifest,
          consumer: consumer,
          consumer_commit: consumer_commit,
          certification: certification,
          acknowledgement: acknowledgement
        )
      end

      with_current_manifest_lock do |manifest|
        bootstrapped = bootstrap_current_manifest(
          manifest,
          consumer: consumer,
          consumer_commit: consumer_commit,
          certification: certification,
          acknowledgement: acknowledgement
        )
        atomic_write(bootstrapped)
        bootstrapped
      end
    end

    private

    def read_manifest
      parse_json(File.read(@manifest_path), @manifest_path)
    rescue Errno::ENOENT
      raise PromotionError, "runtime tuple manifest does not exist: #{@manifest_path}"
    end

    def promote_manifest(manifest, consumer:, consumer_commit:, certification:, previous_certification:)
      consumer_entry = fetch_consumer!(manifest, consumer)
      profile = fetch_profile!(consumer_entry, consumer)
      candidate = prepare_candidate!(consumer_entry, consumer_commit)
      current = consumer_entry.fetch("current") do
        raise PromotionError, "#{consumer} has no current tuple to preserve as previous"
      end
      validate_tuple!(current, "#{consumer} current")

      candidate_fingerprint = tuple_fingerprint(candidate, consumer: consumer, profile: profile)
      current_fingerprint = tuple_fingerprint(current, consumer: consumer, profile: profile)
      if candidate_fingerprint == current_fingerprint
        raise PromotionError, "#{consumer} candidate is identical to its current tuple"
      end

      certified_candidate = certify_tuple!(
        candidate,
        consumer: consumer,
        profile: profile,
        supplied: certification,
        expected_fingerprint: candidate_fingerprint,
        label: "candidate"
      )
      certified_previous = certify_previous!(
        current,
        consumer: consumer,
        profile: profile,
        supplied: previous_certification,
        expected_fingerprint: current_fingerprint
      )

      consumer_entry["previous"] = certified_previous
      consumer_entry["current"] = certified_candidate
      consumer_entry["candidate"] = nil
      consumer_entry.delete("rollback_state")
      refresh_promotion_state!(manifest)
      manifest
    end

    def bootstrap_current_manifest(manifest, consumer:, consumer_commit:, certification:, acknowledgement:)
      consumer_entry = fetch_consumer!(manifest, consumer)
      profile = fetch_profile!(consumer_entry, consumer)
      candidate = prepare_candidate!(consumer_entry, consumer_commit)
      current = consumer_entry.fetch("current") do
        raise PromotionError, "#{consumer} has no current tuple to retain as emergency provenance"
      end
      validate_tuple!(current, "#{consumer} current")
      unless NON_CERTIFIABLE_TUPLE_STATUSES.include?(current["status"])
        raise PromotionError, "degraded bootstrap is only for a current tuple known to fail the contract"
      end
      unless consumer_entry["previous"].nil?
        raise PromotionError, "degraded bootstrap cannot replace an existing previous tuple"
      end
      if consumer_entry.key?("emergency_provenance") || consumer_entry.key?("rollback_state")
        raise PromotionError, "degraded bootstrap has already been recorded for this consumer"
      end

      candidate_fingerprint = tuple_fingerprint(candidate, consumer: consumer, profile: profile)
      current_fingerprint = tuple_fingerprint(current, consumer: consumer, profile: profile)
      if candidate_fingerprint == current_fingerprint
        raise PromotionError, "#{consumer} candidate is identical to its failed current tuple"
      end

      certified_candidate = certify_tuple!(
        candidate,
        consumer: consumer,
        profile: profile,
        supplied: certification,
        expected_fingerprint: candidate_fingerprint,
        label: "bootstrap candidate"
      )

      consumer_entry["emergency_provenance"] = deep_copy(current)
      consumer_entry["current"] = certified_candidate
      consumer_entry["candidate"] = nil
      consumer_entry["previous"] = nil
      consumer_entry["rollback_state"] = {
        "status" => "degraded-no-certified-previous",
        "acknowledgement" => acknowledgement,
        "recorded_at" => certification.fetch("certified_at"),
        "emergency_provenance_status" => current.fetch("status")
      }
      refresh_promotion_state!(manifest)
      manifest
    end

    def fetch_consumer!(manifest, consumer)
      unless manifest.is_a?(Hash) && manifest["schema_version"] == 1 && manifest["consumers"].is_a?(Hash)
        raise PromotionError, "runtime tuple manifest must use schema_version 1 and contain consumers"
      end

      manifest.fetch("consumers").fetch(consumer) do
        raise PromotionError, "unknown consumer #{consumer.inspect}"
      end
    end

    def prepare_candidate!(consumer_entry, consumer_commit)
      candidate = consumer_entry["candidate"]
      unless candidate.is_a?(Hash)
        raise PromotionError, "consumer has no candidate tuple to promote"
      end
      unless candidate["status"] == "compatibility-certified"
        raise PromotionError, "candidate status must be compatibility-certified"
      end
      validate_timestamp!(candidate["certified_at"], "candidate compatibility certification timestamp")

      if candidate.key?("consumer_commit") && candidate["consumer_commit"] != consumer_commit
        raise PromotionError, "explicit consumer commit does not match the candidate"
      end

      prepared = deep_copy(candidate)
      prepared["consumer_commit"] = consumer_commit
      validate_tuple!(prepared, "candidate")
      prepared
    end

    def fetch_profile!(consumer_entry, consumer)
      profile = consumer_entry["profile"]
      unless profile.is_a?(String) && profile.match?(/\A[a-z0-9][a-z0-9-]*\z/)
        raise PromotionError, "#{consumer} must declare a valid compatibility profile"
      end

      profile_path = File.join(@root, "profiles", "#{profile}.json")
      unless File.file?(profile_path)
        raise PromotionError, "#{consumer} compatibility profile does not exist: profiles/#{profile}.json"
      end

      profile
    end

    def certify_previous!(tuple, consumer:, profile:, supplied:, expected_fingerprint:)
      if NON_CERTIFIABLE_TUPLE_STATUSES.include?(tuple["status"])
        raise PromotionError,
              "current tuple is known to fail the compatibility contract and cannot become a certified rollback"
      end

      if tuple["status"] == "certified"
        validate_recorded_certification!(
          tuple,
          consumer: consumer,
          profile: profile,
          expected_fingerprint: expected_fingerprint,
          label: "current rollback"
        )
        return deep_copy(tuple)
      end

      unless supplied
        raise PromotionError,
              "current tuple is not certified; explicit previous certification evidence, timestamp, and status are required"
      end

      certify_tuple!(
        tuple,
        consumer: consumer,
        profile: profile,
        supplied: supplied,
        expected_fingerprint: expected_fingerprint,
        label: "previous"
      )
    end

    def certify_tuple!(tuple, consumer:, profile:, supplied:, expected_fingerprint:, label:)
      certification = validate_supplied_certification!(
        supplied,
        consumer: consumer,
        profile: profile,
        tuple: tuple,
        expected_fingerprint: expected_fingerprint,
        label: label
      )

      certified = deep_copy(tuple)
      if certified.key?("certified_at")
        certified["compatibility_certified_at"] = certified.delete("certified_at")
      end
      certified["status"] = "certified"
      certified["certification"] = certification
      certified
    end

    def validate_supplied_certification!(supplied, consumer:, profile:, tuple:, expected_fingerprint:, label:)
      unless supplied.is_a?(Hash)
        raise PromotionError, "#{label} certification evidence, timestamp, and status are required"
      end

      status = supplied["status"]
      certified_at = supplied["certified_at"]
      evidence = Array(supplied["evidence"])
      unless status == CERTIFICATION_STATUS
        raise PromotionError, "#{label} certification status must be #{CERTIFICATION_STATUS.inspect}"
      end
      validate_timestamp!(certified_at, "#{label} certification timestamp")
      raise PromotionError, "#{label} certification requires at least one evidence file" if evidence.empty?

      normalized_evidence = evidence.map do |reference|
        validate_evidence!(
          reference,
          consumer: consumer,
          profile: profile,
          tuple: tuple,
          status: status,
          certified_at: certified_at,
          tuple_fingerprint: expected_fingerprint,
          label: label
        )
      end
      evidence_paths = normalized_evidence.map { |reference| reference.fetch("path") }
      unless evidence_paths.uniq == evidence_paths
        raise PromotionError, "#{label} certification evidence files must be unique"
      end

      {
        "status" => status,
        "certified_at" => certified_at,
        "tuple_sha256" => expected_fingerprint,
        "evidence" => normalized_evidence
      }
    end

    def validate_recorded_certification!(tuple, consumer:, profile:, expected_fingerprint:, label:)
      certification = tuple["certification"]
      unless certification.is_a?(Hash) && certification["tuple_sha256"] == expected_fingerprint
        raise PromotionError, "#{label} tuple has invalid or stale certification metadata"
      end

      references = Array(certification["evidence"])
      unless references.all? { |reference| structured_evidence_reference?(reference) }
        raise PromotionError,
              "#{label} recorded certification evidence must use hash-bound {path, sha256} references"
      end

      validated = validate_supplied_certification!(
        certification,
        consumer: consumer,
        profile: profile,
        tuple: tuple,
        expected_fingerprint: expected_fingerprint,
        label: label
      )
      unless certification["evidence"] == validated["evidence"]
        raise PromotionError, "#{label} recorded certification evidence references are not canonical"
      end
    end

    def validate_evidence!(
      reference,
      consumer:,
      profile:,
      tuple:,
      status:,
      certified_at:,
      tuple_fingerprint:,
      label:
    )
      reference_path, expected_sha256 = evidence_reference_parts!(reference, label)

      relative = Pathname.new(reference_path).cleanpath
      if relative.absolute? || relative.each_filename.first != "evidence"
        raise PromotionError, "#{label} evidence must be a repository-relative path under evidence/"
      end

      full_path = File.join(@root, relative.to_s)
      evidence_root = File.realpath(File.join(@root, "evidence"))
      real_path = File.realpath(full_path)
      unless real_path.start_with?("#{evidence_root}#{File::SEPARATOR}")
        raise PromotionError, "#{label} evidence resolves outside evidence/"
      end

      contents = File.binread(real_path)
      actual_sha256 = "sha256:#{Digest::SHA256.hexdigest(contents)}"
      if expected_sha256 && expected_sha256 != actual_sha256
        raise PromotionError,
              "#{label} evidence #{relative} has sha256=#{actual_sha256.inspect}; " \
              "expected #{expected_sha256.inspect}"
      end

      document = parse_json(contents, relative.to_s)
      unless document.is_a?(Hash) && document["schema_version"] == 1
        raise PromotionError, "#{label} evidence #{relative} must use schema_version 1"
      end
      validate_immutable_fields!(document, "#{label} evidence #{relative}")
      expected = {
        "consumer" => consumer,
        "profile" => profile,
        "consumer_commit" => tuple.fetch("consumer_commit"),
        "status" => status,
        "certified_at" => certified_at,
        "tuple_sha256" => tuple_fingerprint
      }
      expected.each do |key, value|
        next if document[key] == value

        raise PromotionError,
              "#{label} evidence #{relative} has #{key}=#{document[key].inspect}; expected #{value.inspect}"
      end

      validate_evidence_tuple_details!(document, tuple, "#{label} evidence #{relative}")

      {
        "path" => relative.to_s,
        "sha256" => actual_sha256
      }
    rescue Errno::ENOENT
      raise PromotionError, "#{label} evidence does not exist: #{reference_path || reference}"
    end

    def validate_tuple!(tuple, label)
      raise PromotionError, "#{label} tuple must be an object" unless tuple.is_a?(Hash)

      validate_immutable_fields!(tuple, label)
      validate_full_commit!(tuple["consumer_commit"], "#{label} consumer commit")
      validate_client!(tuple["opencode_ruby"], "#{label} opencode_ruby", required: true)
      validate_client!(tuple["opencode_rails"], "#{label} opencode_rails", required: false)
      validate_runtime!(tuple["runtime"], "#{label} runtime")
    end

    def validate_client!(client, label, required:)
      if client.nil?
        raise PromotionError, "#{label} is required" if required

        return
      end
      unless client.is_a?(Hash) && client["version"].is_a?(String) && !client["version"].empty?
        raise PromotionError, "#{label} must include a non-empty version"
      end

      validate_full_commit!(client["git_commit"], "#{label} git commit")
    end

    def validate_runtime!(runtime, label)
      raise PromotionError, "#{label} must be an object" unless runtime.is_a?(Hash)
      unless runtime["reported_version"].is_a?(String) && !runtime["reported_version"].empty?
        raise PromotionError, "#{label} must include the reported OpenCode server version"
      end

      exact_execution_coordinate = false
      runtime.each do |key, value|
        if key == "docker_image_id" || key.end_with?("_image_id")
          unless value.is_a?(String) && value.match?(DIGEST)
            raise PromotionError, "#{label} #{key} must be an exact sha256 image ID"
          end
          exact_execution_coordinate = true if key == "docker_image_id"
        elsif image_reference_key?(key)
          unless value.is_a?(String) && value.match?(IMMUTABLE_IMAGE)
            raise PromotionError, "#{label} #{key} must be an immutable image@sha256 digest, not a tag"
          end
          exact_execution_coordinate = true if %w[image registry_ref].include?(key)
        elsif key.end_with?("_commit")
          next if value.nil? && NULLABLE_COMMIT_KEYS.include?(key)

          validate_full_commit!(value, "#{label} #{key.tr('_', ' ')}")
        end
      end

      unless exact_execution_coordinate
        raise PromotionError, "#{label} must include an immutable image, registry_ref, or docker_image_id"
      end
    end

    def image_reference_key?(key)
      EXACT_IMAGE_REFERENCE_KEYS.include?(key) ||
        (key.end_with?("_image") && key != "tag_provenance") ||
        (key.end_with?("_ref") && key != "tag_provenance")
    end

    def structured_evidence_reference?(reference)
      reference.is_a?(Hash) && reference.keys.sort == EVIDENCE_REFERENCE_KEYS
    end

    def evidence_reference_parts!(reference, label)
      if reference.is_a?(String)
        unless !reference.empty?
          raise PromotionError, "#{label} evidence references must contain a non-empty path"
        end

        return [reference, nil]
      end

      unless structured_evidence_reference?(reference)
        raise PromotionError,
              "#{label} evidence references must be a path string or an object containing only path and sha256"
      end

      path = reference["path"]
      sha256 = reference["sha256"]
      unless path.is_a?(String) && !path.empty?
        raise PromotionError, "#{label} evidence references must contain a non-empty path"
      end
      unless sha256.is_a?(String) && sha256.match?(DIGEST)
        raise PromotionError, "#{label} evidence reference sha256 must be an exact sha256 digest"
      end

      [path, sha256]
    end

    def validate_evidence_tuple_details!(document, tuple, label)
      if document.key?("consumer_tree")
        expected_tree = tuple["consumer_tree"]
        unless expected_tree && document["consumer_tree"] == expected_tree
          raise PromotionError,
                "#{label} has consumer_tree=#{document['consumer_tree'].inspect}; " \
                "expected #{expected_tree.inspect}"
        end
      end

      validate_evidence_clients!(document["clients"], tuple, label) if document.key?("clients")
      validate_evidence_runtime!(document["runtime"], tuple.fetch("runtime"), label) if document.key?("runtime")
    end

    def validate_evidence_clients!(clients, tuple, label)
      unless clients.is_a?(Hash)
        raise PromotionError, "#{label} clients must be an object"
      end

      %w[opencode_ruby opencode_rails].each do |client_name|
        next unless clients.key?(client_name)

        evidence_client = clients[client_name]
        tuple_client = tuple[client_name]
        if evidence_client.nil?
          unless tuple_client.nil?
            raise PromotionError, "#{label} #{client_name} is null but the tuple declares a client"
          end
          next
        end

        unless evidence_client.is_a?(Hash) && tuple_client.is_a?(Hash)
          raise PromotionError, "#{label} #{client_name} must match the tuple client"
        end
        unless evidence_client["version"].is_a?(String) && !evidence_client["version"].empty?
          raise PromotionError, "#{label} #{client_name} must include a non-empty version"
        end

        commits = %w[commit git_commit].filter_map do |key|
          evidence_client[key] if evidence_client.key?(key)
        end
        if commits.empty?
          raise PromotionError, "#{label} #{client_name} must include commit or git_commit"
        end

        compare_evidence_coordinate!(
          evidence_client["version"],
          tuple_client["version"],
          "#{label} #{client_name}.version"
        )
        commits.each do |commit|
          compare_evidence_coordinate!(commit, tuple_client["git_commit"], "#{label} #{client_name}.commit")
        end
      end
    end

    def validate_evidence_runtime!(runtime, tuple_runtime, label)
      unless runtime.is_a?(Hash)
        raise PromotionError, "#{label} runtime must be an object"
      end

      runtime.each do |key, value|
        tuple_key = EVIDENCE_RUNTIME_KEY_MAP.fetch(key, key)
        next unless EVIDENCE_RUNTIME_COORDINATE_KEYS.include?(tuple_key)

        unless tuple_runtime.key?(tuple_key)
          raise PromotionError, "#{label} runtime.#{key} is not present in the certified tuple"
        end

        compare_evidence_coordinate!(value, tuple_runtime[tuple_key], "#{label} runtime.#{key}")
      end
    end

    def compare_evidence_coordinate!(actual, expected, label)
      return if actual == expected

      raise PromotionError, "#{label}=#{actual.inspect}; expected #{expected.inspect}"
    end

    def validate_immutable_fields!(value, label, path = [])
      case value
      when Hash
        value.each do |key, child|
          field_path = path + [key]
          field_label = "#{label} #{field_path.join('.')}"
          if key == "commit" || key.end_with?("_commit") || key == "head_sha" || key.end_with?("_head_sha")
            unless child.nil? && NULLABLE_COMMIT_KEYS.include?(key)
              validate_full_commit!(child, field_label)
            end
          elsif key == "tree" || key.end_with?("_tree")
            validate_full_oid!(child, field_label)
          elsif key == "annotated_tag_object" || key.end_with?("_tag_object")
            validate_full_oid!(child, field_label)
          elsif digest_field?(key)
            unless child.is_a?(String) && child.match?(DIGEST)
              raise PromotionError, "#{field_label} must be an exact sha256 digest"
            end
          end

          validate_immutable_fields!(child, label, field_path)
        end
      when Array
        value.each_with_index { |child, index| validate_immutable_fields!(child, label, path + [index]) }
      end
    end

    def digest_field?(key)
      key == "sha256" || key.end_with?("_sha256") ||
        key == "digest" || key.end_with?("_digest") ||
        key == "docker_image_id" || key.end_with?("_image_id")
    end

    def validate_full_oid!(value, label)
      return if value.is_a?(String) && value.match?(FULL_COMMIT)

      raise PromotionError, "#{label} must be a full 40-character lowercase Git object ID"
    end

    def validate_full_commit!(value, label)
      return if value.is_a?(String) && value.match?(FULL_COMMIT)

      raise PromotionError, "#{label} must be a full 40-character lowercase Git commit"
    end

    def validate_timestamp!(value, label)
      unless value.is_a?(String) && value.match?(UTC_TIMESTAMP)
        raise PromotionError, "#{label} must be an explicit RFC 3339 UTC timestamp"
      end

      Time.iso8601(value)
    rescue ArgumentError
      raise PromotionError, "#{label} is not a valid timestamp"
    end

    def tuple_fingerprint(tuple, consumer:, profile:)
      payload = deep_copy(tuple)
      TUPLE_METADATA_KEYS.each { |key| payload.delete(key) }
      envelope = {
        "consumer" => consumer,
        "profile" => profile,
        "tuple" => payload
      }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(envelope)))}"
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def parse_json(contents, label)
      JSON.parse(contents)
    rescue JSON::ParserError => e
      raise PromotionError, "invalid JSON in #{label}: #{e.message}"
    end

    def all_consumers_certified?(manifest)
      manifest.fetch("consumers").all? do |consumer, entry|
        next false unless entry["candidate"].nil?

        profile = fetch_profile!(entry, consumer)

        %w[current previous].all? do |slot|
          tuple = entry[slot]
          next false unless tuple.is_a?(Hash) && tuple["status"] == "certified"

          validate_tuple!(tuple, "#{consumer} #{slot}")
          validate_recorded_certification!(
            tuple,
            consumer: consumer,
            profile: profile,
            expected_fingerprint: tuple_fingerprint(tuple, consumer: consumer, profile: profile),
            label: "#{consumer} #{slot}"
          )
          true
        rescue PromotionError
          false
        end
      end
    end

    def all_consumers_bootstrapped?(manifest)
      manifest.fetch("consumers").all? do |consumer, entry|
        next false unless entry["candidate"].nil? && entry["previous"].nil?
        next false unless entry.dig("rollback_state", "status") == "degraded-no-certified-previous"
        next false unless NON_CERTIFIABLE_TUPLE_STATUSES.include?(entry.dig("emergency_provenance", "status"))

        profile = fetch_profile!(entry, consumer)
        tuple = entry["current"]
        next false unless tuple.is_a?(Hash) && tuple["status"] == "certified"

        validate_tuple!(tuple, "#{consumer} current")
        validate_recorded_certification!(
          tuple,
          consumer: consumer,
          profile: profile,
          expected_fingerprint: tuple_fingerprint(tuple, consumer: consumer, profile: profile),
          label: "#{consumer} current"
        )
        true
      rescue PromotionError
        false
      end
    end

    def migration_state_for(manifest)
      return "certified" if all_consumers_certified?(manifest)
      return "bootstrap-current-only" if all_consumers_bootstrapped?(manifest)

      "candidate"
    end

    def refresh_promotion_state!(manifest)
      manifest["migration_state"] = migration_state_for(manifest)
      manifest["promotion_readiness"] = case manifest.fetch("migration_state")
                                        when "certified"
                                          {
                                            "status" => "certified",
                                            "reason" => "Every consumer has exact current and previous passing tuples.",
                                            "required_action" => "Promote only a newly certified, materially changed tuple."
                                          }
                                        when "bootstrap-current-only"
                                          {
                                            "status" => "bootstrap-current-only",
                                            "reason" => "Every current tuple is certified, but no independently passing previous tuple exists yet.",
                                            "required_action" => "Certify the next meaningful release so normal promotion retains the current tuple as previous."
                                          }
                                        else
                                          {
                                            "status" => "candidate",
                                            "reason" => "At least one consumer transition remains incomplete.",
                                            "required_action" => "Finish exact tuple certification without treating failed emergency provenance as rollback evidence."
                                          }
                                        end
    end

    def with_current_manifest_lock
      loop do
        retry_with_new_inode = false
        result = nil

        File.open(@manifest_path, File::RDONLY) do |locked_file|
          locked_file.flock(File::LOCK_EX)
          unless File.identical?(locked_file, @manifest_path)
            retry_with_new_inode = true
            next
          end

          result = yield parse_json(locked_file.read, @manifest_path)
        end

        return result unless retry_with_new_inode
      end
    rescue Errno::ENOENT
      raise PromotionError, "runtime tuple manifest does not exist: #{@manifest_path}"
    end

    def atomic_write(manifest)
      directory = File.dirname(@manifest_path)
      mode = File.stat(@manifest_path).mode & 0o777
      payload = JSON.pretty_generate(manifest) + "\n"

      Tempfile.create([".runtime-tuples-", ".tmp"], directory) do |temporary|
        temporary.chmod(mode)
        temporary.write(payload)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, @manifest_path)
        fsync_directory(directory)
      end
    end

    def fsync_directory(directory)
      File.open(directory, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::ENOTSUP
      # Some filesystems do not support directory fsync; rename is still atomic.
    end
  end
end
