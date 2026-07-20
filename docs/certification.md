# Certification and promotion

## Candidate gate

A candidate tuple is the complete set of client version or commit, Rails gem
version or commit where applicable, exact OpenCode image, profile, and consumer
commit. Changing any member invalidates the certification.

The gate requires:

1. repository validation and the shared fixture corpus;
2. exact `opencode-ruby` and `opencode-rails` candidate checkouts, all Rails
   candidate tests on Ruby 3.2 through 4.0, an exact Rails-to-Ruby runtime
   dependency, and loaded Bundler provenance for the Ruby commit;
3. the public exact-image matrix against the deterministic model stub;
4. an isolated custom-image canary for Ajent Rails and Mushu;
5. the consumer's own focused and full required tests in its devcontainer;
6. a user-visible canary turn for stream consumers;
7. captured evidence including image ID/digest, server version, source commit,
   gem commits, timestamps, and probe outcome.

Health-only probes do not certify a tuple.

### Client source provenance

Before publication, `manifests/client-candidate.json` must use
`publication_state: unpublished` and `kind: commit` for both clients. Each
provenance commit must equal its full 40-character checkout ref, and the Rails
Gemfile/runtime dependency must resolve the same exact Ruby commit and version.
Commit-only evidence is candidate evidence; it is not proof of a gem release.
The lockstep checkout fetches tags and fails unpublished mode if the matching
`vVERSION` tag appears, forcing the manifest through the published gate.

After publication, change the state to `published` and replace both commit
provenance objects with `kind: annotated-tag`, the exact tag, annotated tag
object ID, and peeled commit. The repository validator rejects a published
commit-only candidate. The lockstep job additionally verifies that each local
tag ref resolves to the declared annotated tag object and that both the object
and ref peel to the tested checkout. This transition is a reviewed manifest
change; CI does not create or publish tags.

The image matrix's active candidate coordinates must equal the client manifest.
Changing either commit resets the active matrix to `pending`. A
`previous_certification` preserves historical evidence but does not certify the
new candidate.

The shared live probe is intentionally strict: `full_text` must equal the
expected text byte-for-byte and the deterministic model must receive exactly
one request. A response that merely contains the expected text, including a
duplicated `compat-ok\n\ncompat-ok`, fails.

## Promotion

Promotion is a reviewed manifest change that moves the old `current` tuple to
`previous` and the passing candidate to `current`. The consumer change is then
merged and deployed separately. Workflows in this repository have no deploy
credentials or deploy steps.

Use the repository promotion command; do not hand-edit the three tuple slots.
It binds evidence to a canonical SHA-256 of the complete tuple, requires full
consumer and gem commits, rejects mutable runtime image coordinates, and writes
the manifest with a same-filesystem atomic rename. The command only changes
`manifests/runtime-tuples.json`; it cannot deploy a consumer.

First inspect the fingerprints for both the candidate and rollback tuple:

```sh
ruby scripts/promote_runtime_tuple.rb fingerprint \
  --consumer travelwolf \
  --consumer-commit FULL_40_CHARACTER_CONSUMER_COMMIT
```

Commit one or more JSON evidence documents under `evidence/`. Each document
must explicitly contain values matching the promotion:

```json
{
  "schema_version": 1,
  "consumer": "travelwolf",
  "profile": "rails-persisted-turn",
  "consumer_commit": "FULL_40_CHARACTER_CONSUMER_COMMIT",
  "status": "pass",
  "certified_at": "2026-07-18T12:00:00Z",
  "tuple_sha256": "sha256:FULL_64_CHARACTER_FINGERPRINT"
}
```

Preview the exact manifest transition with `--dry-run`, then repeat without it
to write the manifest:

```sh
ruby scripts/promote_runtime_tuple.rb promote \
  --consumer travelwolf \
  --consumer-commit FULL_40_CHARACTER_CONSUMER_COMMIT \
  --status pass \
  --certified-at 2026-07-18T12:00:00Z \
  --evidence evidence/travelwolf-candidate.json \
  --previous-status pass \
  --previous-certified-at 2026-07-17T12:00:00Z \
  --previous-evidence evidence/travelwolf-rollback.json \
  --dry-run
```

The `--previous-*` arguments are required while the old `current` tuple lacks a
valid certification record. Later promotions reuse and revalidate that record.
Both candidate and previous evidence must match the printed tuple fingerprint,
consumer, full consumer commit, timestamp, and `pass` status. A tag may be kept
only in a `tag_provenance` field; `image`, `registry_ref`, and base image fields
must use `image@sha256:...`, while a private local artifact may use an exact
`docker_image_id`.

An application canary and the shared deterministic contract prove different
layers. For example, a consumer may instrument one application prompt without
being able to observe the underlying model request. Record that distinction
explicitly; do not infer a model request count from an application prompt
count. The exact-image shared contract supplies the model-request proof.

Likewise, the public image job executes `ruby-rest-sse`; it does not silently
certify Rails persistence, plugin hooks, voice streaming, strict route gates,
or provider hooks. Those appear as `required_consumer_profiles` in the image
matrix and need their own consumer evidence before a full tuple can pass.

The companion lockstep job proves that the exact Rails candidate loads and
tests against the exact Ruby candidate on every supported Ruby version. That
still does not certify a consumer's ActiveRecord schema, persistence callbacks,
container adapter, or application canary; those remain consumer-owned profile
evidence.

GitHub CI writes canonical JSON artifacts for the shared fixture, lockstep
client, and each exact-image target. Artifact retention is 30 days and supplies
reviewable workflow provenance; it is not the long-term ledger. Gitea executes
the same contracts, with its exact-image targets run sequentially from the full
generated manifest, but its installed artifact service cannot accept the
reviewed GitHub upload action. Gitea therefore keeps generated JSON transient
and makes no artifact-evidence claim. After reviewing a GitHub artifact, copy
the relevant facts into a repository evidence document bound to the complete
tuple fingerprint. Automated workflows never update certified evidence or
promote a tuple.

The command clears `candidate` after promotion. It sets the repository-wide
`migration_state` to `certified` only after every consumer has certified
`current` and `previous` tuples and no pending candidate.

## Bootstrap with a failing baseline

If the observed production baseline fails the current contract, keep its full
coordinates for emergency recovery but mark it failed. Do not create passing
evidence for it and do not promote it into `previous`. The promoter rejects
known-failed baselines even if a document claims `pass`.

The safe bootstrap is two-stage: certify and roll out the new candidate, then
create and canary a distinct consumer rollback commit that preserves the same
known-good client and exact runtime. Only after both immutable consumer commits
have real passing evidence can the manifest honestly contain certified
`current` and `previous` tuples. Until then, `promotion_readiness` remains
blocked and the candidate PR must not be treated as a deploy authorization.

The schema-v1 promotion command deliberately cannot perform the first degraded
bootstrap transition when `current` is a known-failing baseline. Do not bypass
that guard by hand-editing the manifest or relabeling alpha2 evidence. A
separate reviewed state-machine change must first add an explicit
`bootstrap-current-only` state that preserves the failed baseline as
uncertified emergency provenance and leaves `previous` null. Itemized rollback
certification is complete only after a later, materially distinct passing tuple
can move the first certified current into `previous`.

## Rollback

Rollback restores the whole `previous` tuple. Do not roll back only the gem or
only the runtime image: the wire contract is the unit of compatibility.

For a custom image, retain its immutable registry digest or Docker image ID and
the source commit used to build it. A source tag alone is insufficient.

## Custom-image canary

Run the shared live contract on a host that can pull the exact image:

```sh
BUNDLE_GEMFILE=/path/to/opencode-ruby/Gemfile \
OPENCODE_RUBY_PATH=/path/to/opencode-ruby \
OPENCODE_RUBY_COMMIT=FULL_40_HEX_COMMIT \
OPENCODE_IMAGE='registry.example/image@sha256:...' \
bundle exec scripts/run_image_contract.sh
```

The Ruby checkout must be clean and its `HEAD` must equal
`OPENCODE_RUBY_COMMIT`. Install Bundler dependencies outside that checkout when
the normal cache path would create untracked files.

If an older private registry cannot expose an OCI repository digest, set
`ALLOW_EXACT_IMAGE_ID=1` and pass the locally present `sha256:...` image ID.
Record the registry tag, image ID, source commit, and reason a repository
digest was unavailable in the evidence.
