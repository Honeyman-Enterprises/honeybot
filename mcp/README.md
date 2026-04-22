# MCP servers

Model Context Protocol servers for Honeybot — each a separate container
alongside the Hermes agent, registered with Hermes via
`~/.hermes/config.yaml` (or equivalent).

## Status

| Server        | Phase | State    | Notes |
|---------------|-------|----------|-------|
| `mercury/`    | 5     | stub     | Read-only wrapper around Mercury API. Payments blocked — Mercury's standard tier doesn't expose payment initiation. |
| `image-ingest/` | 5   | stub     | OCR + CLIP + captioning → Elasticsearch `images_v1` index. Internal-only traffic. |
| `proxy-memory/` | 8   | stub     | Fan-out + merge shim over Mem0 + Honcho. |

## Off-the-shelf MCPs (no custom code)

Configured via Hermes' MCP config, not built here. Added in Phase 4.

| Server        | Source |
|---------------|--------|
| `time`        | `@modelcontextprotocol/server-time` |
| `filesystem`  | `@modelcontextprotocol/server-filesystem` (scoped to /opt/honeybot/shared) |
| `playwright`  | `@executeautomation/playwright-mcp-server` |
| `exa`         | `exa-labs/exa-mcp-server` |
| `brave-search`| `@modelcontextprotocol/server-brave-search` |
| `tavily`      | `@tavily-ai/tavily-mcp` |
| `sentry`      | `@sentry/mcp-server` |
| `fal`         | (fal.ai's official MCP, when it lands; otherwise we wrap their REST API) |

## Conventions

- Each custom MCP server lives in its own subdirectory with a `Dockerfile`
  and `server.py` (or `server.ts`).
- Exposes MCP over stdio when launched directly, or over HTTP/SSE on
  `${SERVICE_NAME}:8000` for the Hermes container to connect to.
- Secrets come from varlock-resolved env vars — never read 1Password
  directly from an MCP container.
- No ports published to the host. Internal traffic only via honeynet.
