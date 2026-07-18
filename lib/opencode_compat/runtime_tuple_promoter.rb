# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "tempfile"
require "time"

module OpenCodeCompat
  class PromotionError < StandardError; end

  class RuntimeTuplePromoter
    SCHEMA_VERSION = 2
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

    def initialize(root:, manifest_path: File.join(root, "manifests/runtime-tuples.json"))
      @root = File.realpath(root)
      @manifest_path = File.expand_path(manifest_path)
    end

    def fingerprints(consumer:, consumer_commit:)
      validate_full_commit!(consumer_commit, "consumer commit")
      manifest = read_manifest
      consumer_entry = fetch_consumer!(manifest, consumer)
      profile = fetch_profile!(consumer_entry, consumer)
      candidate = prepare_candidate!(consumer_entry, consumer_commit, for_promotion: false)
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
      candidate = prepare_candidate!(consumer_entry, consumer_commit, for_promotion: true)
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
      manifest["migration_state"] = migration_state_for(manifest)
      manifest
    end

    def bootstrap_current_manifest(manifest, consumer:, consumer_commit:, certification:, acknowledgement:)
      consumer_entry = fetch_consumer!(manifest, consumer)
      profile = fetch_profile!(consumer_entry, consumer)
      candidate = prepare_candidate!(consumer_entry, consumer_commit, for_promotion: true)
      current = consumer_entry.fetch("current") do
        raise PromotionError, "#{consumer} has no current tuple to retain as emergency provenance"
      end
      validate_tuple!(current, "#{consumer} current")
      unless NON_CERTIFIABLE_TUPLE_STATUSES.include?(current["status"])
        raise PromotionError, "degraded bootstrap is only for a current tuple known to fail the contract"
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
      manifest["migration_state"] = migration_state_for(manifest)
      manifest["promotion_readiness"] = {
        "status" => "bootstrap-current-only",
        "reason" => "The current tuple is certified, but no independently passing previous tuple exists.",
        "required_action" => "Certify the next meaningful release; normal promotion will then retain this current tuple as the first certified previous rollback."
      }
      manifest
    end

    def fetch_consumer!(manifest, consumer)
      unless manifest.is_a?(Hash) && manifest["schema_version"] == SCHEMA_VERSION && manifest["consumers"].is_a?(Hash)
        raise PromotionError, "runtime tuple manifest must use schema_version #{SCHEMA_VERSION} and contain consumers"
      end

      manifest.fetch("consumers").fetch(consumer) do
        raise PromotionError, "unknown consumer #{consumer.inspect}"
      end
    end

    def prepare_candidate!(consumer_entry, consumer_commit, for_promotion:)
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
      validate_candidate_consumer_ref!(prepared, consumer_commit)
      validate_candidate_client_sources!(prepared)
      if for_promotion
        validate_promotion_provenance!(prepared, consumer_commit)
        validate_promotion_product_artifacts!(prepared.fetch("runtime"))
      end
      prepared
    end

    def validate_candidate_consumer_ref!(candidate, consumer_commit)
      reference = candidate["consumer_ref"]
      unless reference.is_a?(Hash)
        raise PromotionError, "candidate must record its exact consumer ref"
      end

      kind = reference["kind"]
      unless %w[pull-request-head main-commit].include?(kind)
        raise PromotionError, "candidate consumer ref must be a pull-request-head or main-commit"
      end
      validate_full_commit!(reference["commit"], "candidate consumer ref commit")
      validate_full_commit!(reference["tree"], "candidate consumer ref tree")
      unless reference["commit"] == consumer_commit
        raise PromotionError, "candidate consumer ref does not match the tuple consumer commit"
      end
      unless reference["repository"].is_a?(String) && !reference["repository"].empty?
        raise PromotionError, "candidate consumer ref must name its repository"
      end

      return unless kind == "pull-request-head"

      validate_full_commit!(reference["base_commit"], "candidate pull request base commit")
      unless reference["review_url"].is_a?(String) && reference["review_url"].start_with?("https://")
        raise PromotionError, "candidate pull request ref must include its HTTPS review URL"
      end
    end

    def validate_candidate_client_sources!(candidate)
      %w[opencode_ruby opencode_rails].each do |client_name|
        client = candidate[client_name]
        next unless client

        validate_client_source!(client, "candidate #{client_name}", required: true)
      end
    end

    def validate_promotion_provenance!(candidate, consumer_commit)
      unless candidate["certification_scope"] == "promotion-deployed" && candidate["promotion_eligible"] == true
        raise PromotionError,
              "pre-merge pull-request evidence is candidate-only; promotion requires deployed certification scope"
      end

      provenance = candidate["promotion_provenance"]
      unless provenance.is_a?(Hash)
        raise PromotionError, "promotion requires main-commit provenance or an identical-tree attestation"
      end

      case provenance["kind"]
      when "main-commit"
        unless candidate.dig("consumer_ref", "kind") == "main-commit" &&
            provenance["main_commit"] == consumer_commit
          raise PromotionError, "main-commit promotion provenance must match the tuple consumer commit"
        end
        validate_post_merge_canary!(
          provenance["post_merge_canary"],
          consumer_commit: provenance["main_commit"]
        )
      when "identical-tree-attestation"
        validate_identical_tree_attestation!(candidate, provenance, consumer_commit)
      else
        raise PromotionError, "unknown promotion provenance kind #{provenance['kind'].inspect}"
      end
    end

    def validate_identical_tree_attestation!(candidate, provenance, consumer_commit)
      validate_full_commit!(provenance["pull_request_commit"], "attested pull request commit")
      validate_full_commit!(provenance["pull_request_tree"], "attested pull request tree")
      validate_full_commit!(provenance["main_commit"], "attested main commit")
      validate_full_commit!(provenance["main_tree"], "attested main tree")
      validate_timestamp!(provenance["attested_at"], "identical-tree attestation timestamp")

      unless provenance["pull_request_commit"] == consumer_commit &&
          provenance["pull_request_tree"] == candidate.dig("consumer_ref", "tree") &&
          provenance["main_tree"] == provenance["pull_request_tree"]
        raise PromotionError, "identical-tree attestation does not match the candidate and main trees"
      end

      validate_post_merge_canary!(
        provenance["post_merge_canary"],
        consumer_commit: provenance["main_commit"]
      )
    end

    def validate_post_merge_canary!(canary, consumer_commit:)
      unless canary.is_a?(Hash) && canary["status"] == "pass"
        raise PromotionError, "promotion requires a passing post-merge canary"
      end
      validate_timestamp!(canary["checked_at"], "post-merge canary timestamp")
      evidence = Array(canary["evidence"])
      if evidence.empty? || evidence.any? { |path| !path.is_a?(String) || !path.start_with?("evidence/") }
        raise PromotionError, "post-merge canary must reference evidence under evidence/"
      end
      evidence.each do |reference|
        validate_post_merge_canary_evidence!(
          reference,
          checked_at: canary.fetch("checked_at"),
          consumer_commit: consumer_commit
        )
      end
    end

    def validate_post_merge_canary_evidence!(reference, checked_at:, consumer_commit:)
      relative = Pathname.new(reference).cleanpath
      if relative.absolute? || relative.each_filename.first != "evidence"
        raise PromotionError, "post-merge canary evidence must stay under evidence/"
      end

      evidence_root = File.realpath(File.join(@root, "evidence"))
      real_path = File.realpath(File.join(@root, relative.to_s))
      unless real_path.start_with?("#{evidence_root}#{File::SEPARATOR}")
        raise PromotionError, "post-merge canary evidence resolves outside evidence/"
      end

      document = parse_json(File.read(real_path), relative.to_s)
      unless document.is_a?(Hash) && document["schema_version"] == 1 &&
          document["status"] == "pass" && document["checked_at"] == checked_at &&
          document["consumer_commit"] == consumer_commit
        raise PromotionError,
              "post-merge canary evidence must match its passing timestamp and main consumer commit"
      end
    rescue Errno::ENOENT
      raise PromotionError, "post-merge canary evidence does not exist: #{reference}"
    end

    def validate_promotion_product_artifacts!(runtime)
      selection = runtime["product_selection"]
      return unless selection

      selected_products = selection.fetch("references").keys.sort
      artifact_products = runtime.fetch("product_images", {}).keys.sort
      return if selected_products == artifact_products

      raise PromotionError,
            "promotion requires exact content IDs or digests for every selected product image"
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
      raise PromotionError, "#{label} certification evidence files must be unique" unless evidence.uniq == evidence

      consumer_commit = tuple.fetch("consumer_commit")
      normalized_evidence = evidence.map do |reference|
        validate_evidence!(
          reference,
          consumer: consumer,
          profile: profile,
          consumer_commit: consumer_commit,
          status: status,
          certified_at: certified_at,
          tuple_fingerprint: expected_fingerprint,
          label: label
        )
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

      validate_supplied_certification!(
        certification,
        consumer: consumer,
        profile: profile,
        tuple: tuple,
        expected_fingerprint: expected_fingerprint,
        label: label
      )
    end

    def validate_evidence!(
      reference,
      consumer:,
      profile:,
      consumer_commit:,
      status:,
      certified_at:,
      tuple_fingerprint:,
      label:
    )
      unless reference.is_a?(String) && !reference.empty?
        raise PromotionError, "#{label} evidence references must be non-empty strings"
      end

      relative = Pathname.new(reference).cleanpath
      if relative.absolute? || relative.each_filename.first != "evidence"
        raise PromotionError, "#{label} evidence must be a repository-relative path under evidence/"
      end

      full_path = File.join(@root, relative.to_s)
      evidence_root = File.realpath(File.join(@root, "evidence"))
      real_path = File.realpath(full_path)
      unless real_path.start_with?("#{evidence_root}#{File::SEPARATOR}")
        raise PromotionError, "#{label} evidence resolves outside evidence/"
      end

      document = parse_json(File.read(real_path), relative.to_s)
      unless document.is_a?(Hash) && document["schema_version"] == 1
        raise PromotionError, "#{label} evidence #{relative} must use schema_version 1"
      end
      expected = {
        "consumer" => consumer,
        "profile" => profile,
        "consumer_commit" => consumer_commit,
        "status" => status,
        "certified_at" => certified_at,
        "tuple_sha256" => tuple_fingerprint
      }
      expected.each do |key, value|
        next if document[key] == value

        raise PromotionError,
              "#{label} evidence #{relative} has #{key}=#{document[key].inspect}; expected #{value.inspect}"
      end

      relative.to_s
    rescue Errno::ENOENT
      raise PromotionError, "#{label} evidence does not exist: #{reference}"
    end

    def validate_tuple!(tuple, label)
      raise PromotionError, "#{label} tuple must be an object" unless tuple.is_a?(Hash)

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
      validate_client_source!(client, label, required: false)
    end

    def validate_client_source!(client, label, required:)
      source = client["source"]
      if source.nil?
        raise PromotionError, "#{label} must include loaded exact-ref source proof" if required

        return
      end
      unless source.is_a?(Hash) && source["type"] == "git" && source["uri"].is_a?(String) && !source["uri"].empty?
        raise PromotionError, "#{label} source must identify its Git URI"
      end

      commit = client.fetch("git_commit")
      %w[requested_ref locked_revision].each do |key|
        unless source[key] == commit
          raise PromotionError, "#{label} source #{key} must equal the peeled client commit"
        end
      end

      proof = source["loaded_source_proof"]
      unless proof.is_a?(Hash) && proof["status"] == "pass" && proof["source_class"] == "Bundler::Source::Git"
        raise PromotionError, "#{label} must include passing Bundler Git loaded-source proof"
      end
      expected = {
        "loaded_version" => client.fetch("version"),
        "observed_revision" => commit
      }
      expected.each do |key, value|
        unless proof[key] == value
          raise PromotionError, "#{label} loaded-source proof #{key} must equal #{value.inspect}"
        end
      end
      if proof.key?("observed_ref") && proof["observed_ref"] != commit
        raise PromotionError, "#{label} loaded-source proof observed_ref must equal #{commit.inspect}"
      end
      unless proof["test"].is_a?(String) && !proof["test"].empty?
        raise PromotionError, "#{label} loaded-source proof must name the consumer test"
      end
    end

    def validate_runtime!(runtime, label)
      raise PromotionError, "#{label} must be an object" unless runtime.is_a?(Hash)
      unless runtime["reported_version"].is_a?(String) && !runtime["reported_version"].empty?
        raise PromotionError, "#{label} must include the reported OpenCode server version"
      end

      exact_execution_coordinate = false
      product_selection = runtime["product_selection"]
      if product_selection
        unless product_selection.is_a?(Hash) && product_selection["strategy"] == "full-consumer-commit-tag"
          raise PromotionError, "#{label} product_selection must use the full-consumer-commit-tag strategy"
        end
        validate_full_commit!(product_selection["source_commit"], "#{label} product selection source commit")
        references = product_selection["references"]
        unless references.is_a?(Hash) && !references.empty?
          raise PromotionError, "#{label} product selection references must be a non-empty object"
        end
        references.each do |product, reference|
          unless product.match?(/\A[a-z0-9][a-z0-9-]*\z/) &&
              reference.is_a?(String) && reference.end_with?(":#{product_selection['source_commit']}")
            raise PromotionError,
                  "#{label} #{product} selection must end in the full consumer commit tag"
          end
        end
        exact_execution_coordinate = true
      end

      product_images = runtime["product_images"]
      if product_images
        unless product_images.is_a?(Hash) && !product_images.empty?
          raise PromotionError, "#{label} product_images must be a non-empty object"
        end
        product_images.each do |product, coordinate|
          unless product.match?(/\A[a-z0-9][a-z0-9-]*\z/) && coordinate.is_a?(Hash)
            raise PromotionError, "#{label} product image entries must use named coordinate objects"
          end
          image_id = coordinate["docker_image_id"]
          image = coordinate["image"]
          unless (image_id.is_a?(String) && image_id.match?(DIGEST)) ||
              (image.is_a?(String) && image.match?(IMMUTABLE_IMAGE))
            raise PromotionError,
                  "#{label} #{product} product image must include an exact sha256 image ID or OCI digest"
          end
          validate_full_commit!(coordinate["source_commit"], "#{label} #{product} source commit")
          exact_execution_coordinate = true
        end
      end

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
        elsif key == "source_commit"
          validate_full_commit!(value, "#{label} source commit")
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

    def migration_state_for(manifest)
      return "certified" if all_consumers_certified?(manifest)

      degraded = manifest.fetch("consumers").any? do |_consumer, entry|
        entry.dig("rollback_state", "status") == "degraded-no-certified-previous"
      end
      degraded ? "bootstrap-current-only" : "candidate"
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
