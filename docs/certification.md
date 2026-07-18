# Certification and promotion

## Candidate gate

A candidate tuple is the complete set of client version or commit, Rails gem
version or commit where applicable, exact OpenCode image, profile, and consumer
commit. Changing any member invalidates the certification.

The gate requires:

1. repository validation and the shared fixture corpus;
2. the public exact-image matrix against the deterministic model stub;
3. an isolated custom-image canary for Ajent Rails and Mushu;
4. the consumer's own focused and full required tests in its devcontainer;
5. a user-visible canary turn for stream consumers;
6. captured evidence including image ID/digest, server version, source commit,
   gem commits, timestamps, and probe outcome.

Health-only probes do not certify a tuple.

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

The command clears `candidate` after promotion. It sets the repository-wide
`migration_state` to `certified` only after every consumer has certified
`current` and `previous` tuples and no pending candidate.

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
