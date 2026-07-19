# OpenCode compatibility corpus

This repository is the compatibility boundary between the fast-moving
[OpenCode](https://github.com/anomalyco/opencode) server and the clients and
host applications that depend on its HTTP, SSE, plugin, and runtime behavior.
It contains only synthetic fixtures and public image coordinates; no production
prompts, credentials, sessions, or user data belong here.

## Policy

- A gem release is a candidate until the fixture suite and every required image
  profile pass.
- `opencode-ruby` and `opencode-rails` are one candidate release train. The
  manifest records both peeled commits, and CI rejects a Rails candidate whose
  exact runtime dependency resolves to a different Ruby version or commit.
- Image references are immutable OCI index digests. A tag may be recorded as
  human-readable provenance, but it is never an execution coordinate.
- Custom consumer images are certified with an isolated canary on the host that
  can pull them. Public CI certifies their upstream base plus the same profile.
- Promotion is explicit. CI may certify a tuple and the watcher may open a PR;
  neither workflow deploys or changes a consumer.
- Each consumer retains both `current` and `previous` certified tuples so a
  rollback restores the gem and server together.
- A failing bootstrap baseline is never relabeled as a certified `previous`
  tuple. Promotion stays blocked until a distinct rollback consumer commit is
  pinned to a passing client/runtime tuple and canaried.

## What is covered

The corpus exercises both historical and current terminal events, delta-before-
part ordering, authoritative final text, reasoning text, aggregate multi-step
usage, interactive question and permission waits, unknown-event tolerance, the
subscribe-before-prompt ordering contract, and reconnect without prompt replay.

Profiles keep the ownership boundaries explicit:

- `ruby-rest-sse`: the `opencode-ruby` HTTP/SSE adapter.
- `rails-persisted-turn`: Rails lifecycle, persistence, and recovery semantics.
- `voice-stream`: Greenroom's voice/LiveKit stream semantics.
- `strict-v2`: Leela's strict version and route-ownership gate.
- `plugin-ledger`: Ajent/plugin hook and ledger behavior.
- `provider-hooks`: inference provider configuration and hook behavior.

## Run locally

Prerequisites are Ruby 3.2+, Python 3, `jq`, and Docker.

```sh
ruby test/repository_test.rb
ruby test/runtime_tuple_promoter_test.rb
ruby test/exact_live_contract_test.rb
ruby test/watcher_test.rb
OPENCODE_RUBY_PATH=/path/to/opencode-ruby-at-78b6f9c9e9c7d58b699af1c3c17764acd33de798 \
  ruby ruby/opencode_ruby_fixture_contract.rb
BUNDLE_GEMFILE=/path/to/opencode-rails/Gemfile \
OPENCODE_RUBY_PATH=/path/to/opencode-ruby \
OPENCODE_RAILS_PATH=/path/to/opencode-rails \
OPENCODE_RUBY_COMMIT=FULL_40_HEX_COMMIT \
OPENCODE_RUBY_TAG=v0.0.1.alpha7 \
OPENCODE_RUBY_TAG_OBJECT=FULL_40_HEX_ANNOTATED_TAG_OBJECT \
OPENCODE_RAILS_COMMIT=FULL_40_HEX_COMMIT \
OPENCODE_RAILS_TAG=v0.0.1.alpha7 \
OPENCODE_RAILS_TAG_OBJECT=FULL_40_HEX_ANNOTATED_TAG_OBJECT \
OPENCODE_RUBY_VERSION=0.0.1.alpha7 \
OPENCODE_RAILS_VERSION=0.0.1.alpha7 \
  bundle exec ruby ruby/lockstep_client_contract.rb
BUNDLE_GEMFILE=/path/to/opencode-ruby-at-78b6f9c9e9c7d58b699af1c3c17764acd33de798/Gemfile \
OPENCODE_RUBY_PATH=/path/to/opencode-ruby-at-78b6f9c9e9c7d58b699af1c3c17764acd33de798 \
OPENCODE_RUBY_COMMIT=78b6f9c9e9c7d58b699af1c3c17764acd33de798 \
OPENCODE_IMAGE='ghcr.io/anomalyco/opencode@sha256:e975a0647576016dfdf77d54b979ca30d32b4750472c10263e9894aad6628c2a' \
  bundle exec scripts/run_image_contract.sh
```

The live contract starts a deterministic local OpenAI-compatible model stub and
an isolated OpenCode container. It creates a session, subscribes, submits an
async prompt, observes terminal SSE, fetches the authoritative exchange, and
deletes the session. Passing requires the authoritative final text to equal the
expected text byte-for-byte and the deterministic model stub to observe exactly
one request and exactly one authoritative assistant message. It never calls an
external model provider.

Candidate CI uploads machine-readable fixture, lockstep-client, and exact-image
evidence for 30 days. These artifacts are review inputs, not certification by
themselves. A person must review a passing artifact and commit the durable
certification document under `evidence/`; no workflow commits or promotes its
own result.

## Adding an upstream release

The scheduled watcher compares both the latest upstream GitHub release tag and
its resolved OCI digest with the manifest. A new release or a changed digest
behind an existing tag gets a digest-specific branch and compatibility PR. The
PR adds a pending image-matrix entry, which runs the candidate suite after the
normal GitHub workflow approval boundary. A person still decides whether to
promote it and update consumers. The watcher never merges, dispatches consumer
workflows, deploys, or force-pushes.

`public_ci` is the active compatibility set, not an append-only release log.
Keep images still referenced by a consumer's current, candidate, or previous
runtime tuple plus the newest pending upstream candidate. When a watcher PR
supersedes an unreferenced pending target, remove that older row during review;
durable certification documents and Git history are the archive. This keeps a
fast-moving upstream from making every future run retest every old release.

See [docs/certification.md](docs/certification.md) for promotion, canary, and
rollback evidence requirements.

## License

MIT. See [LICENSE](LICENSE).
