# Certification and promotion

## Candidate gate

A candidate tuple is the complete set of client version or commit, Rails gem
version or commit where applicable, exact OpenCode image, profile, and consumer
commit. Changing any member invalidates the certification.

There are two distinct scopes:

- `pre-merge-pr-head-candidate-only` proves that one reviewed PR head is
  compatible. It is never a deployment or promotion authorization.
- `promotion-deployed` is recorded only after a passing post-merge canary and
  the consumer coordinate is the actual main/merge commit. If policy
  deliberately retains the PR-head commit, the evidence must additionally
  record both Git trees as identical and name the actual main/merge commit.
  Comparing diffs is not an identical-tree attestation.

The gate requires:

1. repository validation and the shared fixture corpus;
2. the public exact-image matrix against the deterministic model stub;
3. an isolated custom-image canary for Ajent Rails and Mushu;
4. the consumer's own focused and full required tests in its devcontainer;
5. a user-visible canary turn for stream consumers;
6. captured evidence including image ID/digest, server version, source commit,
   gem commits, timestamps, and probe outcome.

For a Git-sourced gem, “gem commit” means the peeled 40-character commit in
both the Gemfile `ref` and lockfile `revision`, plus runtime loaded-source proof:
the loaded version, `Bundler::Source::Git`, observed revision (and observed ref
when the consumer test exposes it), and the consumer test that made those
assertions. Annotated tag objects remain useful release provenance, but they
are not an execution coordinate.

Ajent's runtime is a three-product selection. The ledger records AIGL,
Blackline, and Raven under one source commit. Candidate evidence may say that a
product artifact has not been built; promotion may not. At promotion time the
set of content-addressed product artifacts must exactly equal the selected
product set.

Health-only probes do not certify a tuple.

The shared live probe is intentionally strict: `full_text` must equal the
expected text byte-for-byte and the deterministic model must receive exactly
one request. A response that merely contains the expected text, including a
duplicated `compat-ok\n\ncompat-ok`, fails.

## Promotion

Promotion is a reviewed manifest change that moves the old `current` tuple to
`previous` and the passing candidate to `current`. The consumer change must
already have a main/merge identity (or the equal-tree exception below) before
that manifest change. Production rollout remains a separate consumer-owned
operation; workflows in this repository have no deploy credentials or deploy
steps.

Before invoking the promoter, replace PR-head-only metadata with either the
actual main/merge consumer ref and `main-commit` promotion provenance, or an
explicit identical-tree attestation containing the main commit/tree. Both
forms require a post-merge canary evidence path. Set `promotion_eligible` only
after that evidence exists. The promoter rejects the current PR-head candidates
even when their compatibility probes pass.

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

Likewise, the public image job executes only `ruby-rest-sse`; it does not
silently certify Rails persistence, plugin hooks, voice streaming, strict route
gates, or provider hooks. Every other profile is labeled
`executable-consumer-attestation` with `shared_ruby_probe_sufficient: false`.
Those profiles appear as `required_consumer_profiles` in the image matrix and
need executable evidence from their owning consumer before a full tuple can
pass. A prose review or a successful shared Ruby probe is not that evidence.

The command clears `candidate` after promotion. It sets the repository-wide
`migration_state` to `certified` only after every consumer has certified
`current` and `previous` tuples and no pending candidate.

## Bootstrap with a failing baseline

If the observed production baseline fails the current contract, keep its full
coordinates for emergency recovery but mark it failed. Do not create passing
evidence for it and do not promote it into `previous`. The promoter rejects
known-failed baselines even if a document claims `pass`.

Do not manufacture a no-op second commit merely to fill `previous`. Once the
candidate has been merged, deployed, and canaried under promotion-grade
provenance, a reviewer may use `bootstrap-current` with this exact
acknowledgement:

```text
accept-degraded-rollback-with-failed-emergency-provenance
```

That operation certifies only `current`, moves the failed baseline to
`emergency_provenance` without relabeling it, leaves `previous` null, and sets
`migration_state` to `bootstrap-current-only`. This is an intentionally
degraded rollback state, not full certification. The next meaningful passing
release uses normal promotion; the already-certified current tuple then becomes
the first honest certified `previous` tuple.

Until main/deploy evidence exists, `promotion_readiness` remains blocked and a
candidate PR must not be treated as deploy authorization.

After reviewing the degraded rollback consequence, preview the explicit
bootstrap before writing it:

```sh
ruby scripts/promote_runtime_tuple.rb bootstrap-current \
  --consumer travelwolf \
  --consumer-commit FULL_MAIN_OR_ATTESTED_PR_COMMIT \
  --status pass \
  --certified-at 2026-07-18T12:00:00Z \
  --evidence evidence/travelwolf-post-merge.json \
  --acknowledge-degraded-rollback \
    accept-degraded-rollback-with-failed-emergency-provenance \
  --dry-run
```

## Rollback

Rollback restores the whole `previous` tuple. Do not roll back only the gem or
only the runtime image: the wire contract is the unit of compatibility.

For a custom image, retain its immutable registry digest or Docker image ID and
the source commit used to build it. A source tag alone is insufficient.

## Custom-image canary

Run the shared live contract on a host that can pull the exact image:

```sh
OPENCODE_RUBY_PATH=/path/to/opencode-ruby \
OPENCODE_IMAGE='registry.example/image@sha256:...' \
scripts/run_image_contract.sh
```

If an older private registry cannot expose an OCI repository digest, set
`ALLOW_EXACT_IMAGE_ID=1` and pass the locally present `sha256:...` image ID.
Record the registry tag, image ID, source commit, and reason a repository
digest was unavailable in the evidence.
