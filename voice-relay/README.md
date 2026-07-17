# voice-relay (TypeScript)

The voice relay: Siri (HTTP) + Claude/ChatGPT (MCP) → honeybot. Behavior
contract — see [`docs/voice-relay.md`](../docs/voice-relay.md)
(fast-ack/async-DM), [`docs/voice-relay-oauth.md`](../docs/voice-relay-oauth.md)
(MCP OAuth).

**Why TypeScript** (replaced the original Python relay): Python-in-container
fragility (PEP 563 crashing FastMCP, pydantic version sensitivity,
`python:slim` missing `useradd`). Strict `tsc` + static types are the
compile-time gate that catches those classes of bug.

## Build / test

Docker-first (no host node/npm). The build stage runs `tsc --strict` **and**
the tests; either failing fails the image:

```bash
docker build -t voice-relay .
# or, in the stack:  docker compose build voice-relay
```

Scripts: `npm run build` (tsc → `dist/`), `npm test` (node:test via tsx),
`npm run typecheck`.

## Modules

**SDK-independent core:**

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

**MCP + OAuth (API verified against `@modelcontextprotocol/sdk@1.x`
`.d.ts`, not guessed):**

| Module | Role |
|---|---|
| `oauth/store.ts` | clients/tokens (persisted) + codes/pending (in-mem) |
| `oauth/google.ts` | Google auth URL + code→verified-email |
| `oauth/provider.ts` | `OAuthServerProvider` impl (Google upstream); `verifyAccessToken → AuthInfo{extra.slackUid}`; injectable Google exchange for tests |
| `ingress/mcp.ts` | `McpServer` + `StreamableHTTPServerTransport`; unified `requireBearerAuth` (OAuth verifier or bearer verifier); `mcpAuthRouter` + `/oauth/callback` in OAuth mode |
| `server.ts` / `index.ts` | Express app (routes + MCP/OAuth at root) + entry |
| `test/oauth.test.ts` | provider suite (happy path, one-time code, refresh rotation, domain/uid/state/wrong-client rejects) |

Key facts verified: SDK verifies PKCE (`challengeForAuthorizationCode`);
identity via `AuthInfo.extra`; OAuth routes at root come free with Express
`app.use(mcpAuthRouter(...))` (no mount hack).

**Remaining validation:**
- Live OAuth handshake against a real mobile connector (add
  `https://voice.honeybot.honeymanenterprises.com/mcp` in Claude/ChatGPT →
  Google sign-in → tool appears).
