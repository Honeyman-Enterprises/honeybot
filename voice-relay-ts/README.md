# voice-relay (TypeScript)

TypeScript port of the Python `voice-relay/`. Behavior contract is unchanged
— see [`docs/voice-relay.md`](../docs/voice-relay.md) (fast-ack/async-DM),
[`docs/voice-relay-oauth.md`](../docs/voice-relay-oauth.md) (MCP OAuth).

**Why the port:** Python-in-container fragility (PEP 563 crashing FastMCP,
pydantic version sensitivity, `python:slim` missing `useradd`). Strict `tsc`
+ static types are the compile-time gate that catches those classes of bug.

## Build / test

Docker-first (no host node/npm). The build stage runs `tsc --strict` **and**
the tests; either failing fails the image:

```bash
docker build -t voice-relay-ts .
```

Scripts: `npm run build` (tsc → `dist/`), `npm test` (node:test via tsx),
`npm run typecheck`.

## Status

**Ported (this pass) — SDK-independent core, mirrors the tested Python:**

| Module | Role |
|---|---|
| `types.ts` | VoiceRequest / VoiceReply |
| `config.ts` | env → Config (+ `oauthEnabled`) |
| `registry.ts` | per-request state + atomic single-delivery claim |
| `core.ts` | the fast-ack / async-DM race (interfaces for testable deps) |
| `tokenStore.ts` | dynamic bearer token map (persisted) |
| `honeybotClient.ts` | → api_server `/v1/chat/completions` (native fetch) |
| `slackClient.ts` | DM + `users.lookupByEmail` resolver |
| `ingress/siri.ts` | `POST /v1/voice/ask` |
| `admin.ts` | `PUT/GET /admin/tokens` (constant-time key) |
| `test/core.test.ts` | race/registry tests (fast/slow/error/unknown-token/oauth-uid) |

**Next (needs the MCP SDK's OAuth API verified first — not guessed):**

- `ingress/mcp.ts` — `McpServer` + `StreamableHTTPServerTransport`; OAuth mode
  (`mcpAuthRouter` + an `OAuthServerProvider`, tool reads auth info) or
  static-bearer mode.
- `oauth/*` — the authorization-server provider (Google upstream), ported
  from the tested Python `voice_relay/oauth/`.
- `server.ts` + `index.ts` — Express app (routes + MCP mounted at root) + entry.
- Compose: add `voice-relay-ts` as a parallel service, verify, then cut over.
