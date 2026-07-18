# OpenCode compatibility corpus

This repository is the compatibility boundary between the fast-moving
[OpenCode](https://github.com/anomalyco/opencode) server and the clients and
host applications that depend on its HTTP, SSE, plugin, and runtime behavior.
It contains only synthetic fixtures and public image coordinates; no production
prompts, credentials, sessions, or user data belong here.

## Policy

- A gem release is a candidate until the fixture suite and every required image
  profile pass.
- Image references are immutable OCI index digests. A tag may be recorded as
  human-readable provenance, but it is never an execution coordinate.
- Custom consumer images are certified with an isolated canary on the host that
  can pull them. Public CI certifies their upstream base plus the same profile.
- Promotion is explicit. CI may certify a tuple and the watcher may open a PR;
  neither workflow deploys or changes a consumer.
- Each consumer retains both `current` and `previous` certified tuples so a
  rollback restores the gem and server together.

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
OPENCODE_RUBY_PATH=/data/projects/opencode-ruby-alpha6 \
  ruby ruby/opencode_ruby_fixture_contract.rb
OPENCODE_RUBY_PATH=/data/projects/opencode-ruby-alpha6 \
OPENCODE_IMAGE='ghcr.io/anomalyco/opencode@sha256:e975a0647576016dfdf77d54b979ca30d32b4750472c10263e9894aad6628c2a' \
  scripts/run_image_contract.sh
```

The live contract starts a deterministic local OpenAI-compatible model stub and
an isolated OpenCode container. It creates a session, subscribes, submits an
async prompt, observes terminal SSE, fetches the authoritative exchange, and
deletes the session. It never calls an external model provider.

## Adding an upstream release

The scheduled watcher compares the latest upstream GitHub release with the
manifest. When a new release appears, it resolves the tag to an OCI digest and
opens a compatibility PR. The PR adds a pending image-matrix entry, which runs
the candidate suite. A person still decides whether to promote it and update
consumers.

See [docs/certification.md](docs/certification.md) for promotion, canary, and
rollback evidence requirements.

## License

MIT. See [LICENSE](LICENSE).
