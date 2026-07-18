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
