# Multi-App Federation — v1 Plan

**Status:** Draft, not yet implemented. Holding for later.
**Date:** 2026-04-26

## Goal
One canonical user identity behind every ingress channel (Slack, iMessage,
iPhone push, Gmail, GitHub, Linear, etc.) so:
- Tokens and data never bleed across users (no token pollution).
- A user logged in on one channel can be recognized on a new channel via
  explicit linking, not implicit guesswork.
- An RBAC layer can be bolted on top later without a re-architecture.

## Non-goals (v1)
- Graph-based RBAC (deferred — Neo4j when relationships actually warrant it).
- Cross-tenant sharing / delegation chains.
- Replacing 1Password for token storage.

## Storage Decisions

| Concern              | Where                       | Why |
|----------------------|-----------------------------|-----|
| Tokens (refresh/secrets) | **1Password**           | Already there, audited, encrypted. Keep it. |
| Identity map / index | **Redis (AOF, everysec)**   | Fast KV, persistent (`appendonly yes`, `appendfsync everysec`). |
| Token-health metrics | Redis                       | Index-y, non-secret, cheap. |
| RBAC v1              | Boolean / set in Redis      | YAGNI Neo4j until relationships are graphy. |
| RBAC v3 (later)      | Neo4j                       | Delegation chains, cross-org perms when needed. |

App-level **AES-GCM encryption** for any sensitive Redis values; key in
`op://Honeybot/RedisAppKey/key`. Even a Redis dump must be opaque.

## Schema

```
canonical_user:{uuid}
  → JSON {created_at, display_name, primary_email, is_admin, status}

# Forward: any-channel → canonical
channel:slack:U09NS7DSK8U      → uuid
channel:apple:<icloud_id>      → uuid
channel:imessage:+15551234567  → uuid
channel:google:eric@…          → uuid
channel:github:rektbuildr      → uuid
channel:linear:user_xxx        → uuid

# Reverse: canonical → all known channels
canonical_channels:{uuid}      → SET of "<platform>:<external_id>"

# Token pointer (NOT the token itself — points at 1Password)
token_ref:{uuid}:gmail         → "op://Honeybot/Gmail-…"
token_ref:{uuid}:github        → "op://Honeybot/GitHub-…"

# Health
token_health:{uuid}:gmail      → JSON {last_verified, last_error, scopes}
```

## Resolution flow at runtime
1. Inbound message → adapter extracts `(platform, external_id)`.
2. Resolver: `uuid = redis.get("channel:{platform}:{external_id}")`.
3. If miss → linking flow (below) or new-user creation.
4. Skill operations look up `token_ref:{uuid}:{service}` → fetch from
   1Password → mint access token → use → discard.

**No codepath maps an external_id to a uuid that wasn't explicitly linked
to it.** That's the hard guarantee against pollution.

## Linking flow (anti-pollution)
- High-confidence auto-link only when an OAuth grant's verified email
  matches an existing `primary_email`.
- Otherwise: ask for proof on a previously-linked channel.
  > "Hi, are you Eric? Reply YES from a channel you've already linked."
- Two-channel proof = required for any merge.

## Token health monitoring
One hourly cron walks `canonical_channels:*`, mints an access token per
service, hits a no-op endpoint (e.g. `gmail.users.profile`), records
result. Two consecutive failures → Slack alert. This is the answer to
"is there a cron per token" — one cron, all tokens, results in Redis.

## RBAC progression
- **v1:** `is_admin` boolean on `canonical_user`. Skills check it before
  destructive ops.
- **v2:** `role:{uuid}` → SET {admin|dev|reader} in Redis.
- **v3:** Migrate role tables to Neo4j when delegation/cross-org graph
  queries actually appear. Not before.

## Migration phases
1. **Phase 1** (~30-line PR): add Redis service to docker-compose
   (`appendonly yes`, named volume `redis-data`), add `_lib/redis.sh`
   helper, add `RedisAppKey` to seed-vault.sh. **No behavior change.**
2. **Phase 2:** resolver + dual-read mode (Slack-UID legacy lookup OR
   canonical-UUID lookup). Tests + `creds.sh` updated.
3. **Phase 3:** backfill — for every existing `op://Honeybot/Gmail-{UID}`,
   `HubSpot-{UID}`, etc., generate a canonical UUID and write the
   channel/token_ref keys to Redis.
4. **Phase 4:** flip `creds.sh` to UUID-first, fall back to legacy. When
   fallback hits go to zero for a week, drop legacy path.
5. **Phase 5:** light up new ingress channels (BlueBubbles iMessage,
   iPhone push) — they route through the resolver and Just Work.

## Open questions
- Where does the canonical_user row get created on first contact —
  resolver auto-creates with status="unverified", or always require
  proof first? Lean: auto-create, mark unverified, gate sensitive ops
  on verified.
- Do we hash/salt external_ids before using them as Redis keys? Probably
  not v1 (Redis is internal-only, on `honeynet`); revisit if Redis is
  ever exposed.
- Slack home channel + threading: does federation need to remember
  "preferred channel" per uuid? Yes, store on `canonical_user`.

## Out of scope but related: config.yaml persistence
`~/.hermes/config.yaml` is wiped on every container rebuild because only
`~/.hermes/data` is volume-mounted. Current workaround: bake UX flags
into the Dockerfile via `RUN hermes config set …`. At ~5 baked flags
this should be reconsidered (separate volume mount, or a hermes plugin
reading from `data/`). Tracked separately.
