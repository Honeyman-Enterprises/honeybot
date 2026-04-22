# Proxy-Memory MCP (stub — Phase 8)

Fan-out shim over Mem0 + Honcho. Exposes Hermes' memory interface but
writes to both backends and merges reads.

## Why

- **Mem0** = vector-indexed fact store. Strong at "what has the user told
  me about X?" Weak at structured user modeling.
- **Honcho** = session-aware user profile store from Plastic Labs. Strong
  at "who is this user, how do they communicate, what are they working
  on?" Weak at raw fact recall.

Running both gives complementary memory. A proxy layer keeps Hermes'
memory tool API unchanged.

## Reads

Query both backends in parallel. Merge with a rank function:

```
final_rank = (
    mem0_score     * w_mem0(query_type) +
    honcho_score   * w_honcho(query_type)
) - dedup_penalty(result)
```

`query_type` detection: "factual recall" (who, what, when) weights Mem0
higher; "user modeling" (how do they prefer, what are their goals)
weights Honcho higher.

## Writes

Fan out async to both. Fail-tolerant: if Honcho write fails, Mem0 write
still commits and the failure is logged. No retries inside the proxy —
retries are the caller's concern.

## Exposure

- Registered in Hermes as a custom memory provider via a tiny adapter.
- Or, if Hermes' memory subsystem doesn't accept plugins, run as an MCP
  server and have the agent call its tools directly.
- Determination happens in Phase 8.

## Credentials

```
op://Honeybot/Mem0/key           (existing)
op://Honeybot/Honcho/api_key     (Phase 8)
op://Honeybot/Honcho/base_url    (Phase 8 — could be self-hosted or Plastic's SaaS)
```

Not implemented yet. Phase 8.
