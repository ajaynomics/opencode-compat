# Maintaining OpenCode consumers

OpenCode compatibility is an executable tuple, not a gem version. The tuple is
the exact client commit, Rails adapter commit where used, OpenCode image digest,
consumer commit, compatibility profile, and passing evidence. A change to any
coordinate creates a new candidate.

## Dependency ownership

The adjacent projects intentionally do not all use the same gems:

| Consumer | OpenCode boundary | Owned dependency |
| --- | --- | --- |
| Ajent Rails | Ruby REST/SSE plus persisted Rails turns | `opencode-ruby` and `opencode-rails` |
| Travelwolf | Ruby REST/SSE plus persisted Rails turns and Sprite lifecycle | `opencode-ruby` and `opencode-rails` |
| Mushu | Ruby REST/SSE with application-owned conversation, claim, recovery, Telegram scope, and idempotency | `opencode-ruby` only |
| Greenroom | Direct voice-stream worker | No Ruby adapter gem |
| Leela | Custom strict-v2 server, security, and toolchain lane | No Ruby adapter gem |
| opencode-ajent | Native CLI and plugin hook/event lane | No Ruby adapter gem |
| inference | Provider configuration, hooks, routing, and migration lane | No Ruby adapter gem |
| Context Kit | MCP and OpenCode configuration producer | No Ruby adapter gem |

Do not add `opencode-rails` to an application that owns different persistence
semantics, and do not route plugin, provider, voice, or strict-v2 behavior
through the Ruby REST/SSE adapter merely to make versions look uniform. Share
fixtures, provenance, and promotion policy across those lanes instead.

Generated release snapshots, detached operational copies, editor locks, caches,
and linked task worktrees are evidence or tooling. They are not additional
consumers and must not be bulk-upgraded.

Direct consumers still need immutable inputs even though they do not use the
Ruby gems. A system service must execute a clean certified checkout or image,
not whichever files happen to be in a mutable development worktree. Node and
Bun plugins must be pinned through their package lock and tested against the
same OpenCode digest; a globally cached, unversioned plugin is not release
provenance. Generated OpenCode or MCP configuration needs both schema validation
and a candidate-runtime smoke test. Keep OpenCode auto-update disabled in every
certified lane so a process restart cannot silently change the server half of a
previously passing tuple.

## Supported window

Support the exact current and previous certified runtime tuples. Do not claim
compatibility with arbitrary future OpenCode versions. Additive fields and
unknown events should remain tolerant, while terminal text, request count,
ownership, persistence, and cleanup invariants remain strict.

The Ruby/SSE profile covers the endpoints and events the client actually uses,
including session creation and deletion, asynchronous prompts, event
subscription, status, terminal idle/status events, part deltas and updates,
authoritative assistant messages, questions, and permissions. A passing shared
profile does not certify Rails persistence, voice streaming, plugin hooks,
provider migrations, or generated MCP configuration.

## Release and promotion order

1. The watcher records a new upstream release tag and resolved OCI digest in a
   PR. It never merges or deploys.
2. Update fixtures for any observed protocol change before changing the client.
3. Build `opencode-ruby` and `opencode-rails` as one release train. Rails must
   resolve the exact Ruby version and commit being tested.
4. Run the shared fixture corpus, Ruby 3.2 through 4.0 lockstep matrix, and every
   exact public image still used by a current, previous, or candidate tuple.
5. Run only the application-owned profiles for each consumer, in its own PR and
   isolated environment. Health checks alone do not certify a tuple.
6. Promote and deploy one consumer at a time. Record the exact production
   commit, image/base digest, loaded client commits, and live result.
7. Commit reviewed evidence and move the old passing current tuple to previous.
8. Publish annotated gem tags only after the exact commit candidate is green and
   the trusted publisher is configured. Publication never implies deployment.

Commit pins are valid for an unpublished candidate, but the durable published
state must record the annotated tag object and peeled commit. Tags or `latest`
may be kept as human-readable provenance only; execution coordinates use full
Git commits and `image@sha256:...` references.

## Rollback

Rollback restores the whole certified `previous` tuple. Do not roll back only
the gem, only the consumer, or only the runtime image: the wire contract is the
unit of compatibility.

The deployment platform's immediately preceding application image is not
automatically the certified OpenCode rollback. Keep it as emergency service
provenance, but if it contains a client/runtime tuple known to fail the contract
it must not occupy `previous`. In that case rollback means deploying the exact
consumer commit and runtime coordinates recorded in the certified `previous`
tuple, even if that is different from the platform's one-click rollback target.

## Custom images

Record each provenance layer separately:

- consumer commit;
- exact output registry digest or Docker image ID;
- exact base image digest;
- custom OpenCode source commit, when the base is a fork;
- build-source commit when it differs from the deployment commit.

The tuple fingerprint binds these values. On the next rebuild of an older
unlabelled private image, add OCI labels for the custom OpenCode source, reported
version, consumer build revision, and base digest, then make preflight compare
the labels. Do not relabel an already certified image: that changes its digest.

## Runner and forge contract

Runner upgrades are a separate compatibility surface from OpenCode upgrades.
Workflows must install their required Ruby/toolchain explicitly, declare Bash
for scripts that use Bash syntax, and avoid relying on ambient runner packages.
Browser suites must provision the reviewed Chrome/Selenium path explicitly;
an absent browser is a runner failure, not product evidence. Keep a system-test
suite serial when its harness shares an ephemeral server port instead of
mistaking parallel `EADDRINUSE` failures for OpenCode regressions.

GitHub and Gitea do not implement every Actions feature identically. Keep the
same tests on both forges, but use forge-specific execution where necessary:
GitHub retains review artifacts and parallel dynamic image jobs; Gitea runs the
same manifest image set sequentially and makes no artifact-retention claim.
Neither path may mutate a runner or deploy a consumer.

A runner-only workflow repair needs exact-head CI, not an application canary.
A client, runtime image, event, persistence, or toolchain change needs the
profile and consumer canaries described above.

For a frozen rollback snapshot that is no longer a merge candidate, provide a
default-branch audit workflow that accepts and checks out an explicit full SHA.
That lets current runner plumbing test the immutable old application tree
without adding a CI-only commit to the rollback coordinate or pretending a
known runner-workflow failure is an application incompatibility.

## Expected breakages

- Prompt submission before event subscription can miss a terminal event and
  hang a turn.
- An SSE parser that recognizes only `\n\n` can stall on CRLF, bare-CR,
  byte-order-mark, comment, or multiline-data framing that is valid on the
  wire.
- Changes to terminal or message-part events can duplicate or lose final text.
- Usage events can undercount multi-step requests if totals are overwritten.
- Reconnect logic can replay a prompt and create duplicate model requests.
- A Bun/Node server close can wait forever on idle keep-alive sockets unless
  idle connections are explicitly reaped after admissions stop; the resulting
  orphan can exhaust a service cgroup's PID budget and block a safe upgrade.
- Asset builds can fail when runtime configuration is evaluated without the
  image variables available only at deploy time.
- A workflow can pass locally but fail under `sh` when it uses Bash arrays or
  `mapfile`.
- Plugin hook names, provider schema, config/MCP schema, or CLI flags can break
  direct consumers even when the Ruby profile stays green.
- `Opencode::Turn` is still an alpha-stage Rails composition seam; constructor,
  observer, persistence, or finalization changes can break hosts even when the
  lower-level Ruby wire client remains compatible.
- A custom fork can silently lose its required ordering or permission patch if
  only an opaque output digest is retained.

When one of these changes, update the owning profile and consumer evidence. Do
not weaken a strict invariant to make a new upstream release pass.
