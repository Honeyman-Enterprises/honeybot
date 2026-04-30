# Upstream Hermes bugs that bite Honeybot

Living list of bugs in the upstream `hermes-agent` source tree (installed at
`/opt/hermes` in the honeybot container) that we've hit while running honeybot.
Each entry: symptom → repro → root cause → fix path.

**Policy: we do NOT open PRs against upstream.** Every fix lives in this repo.
That means each entry below resolves either as a Dockerfile workaround
(preferred — survives image rebuilds, no risk of vendor drift) or as an
in-tree patch applied to `/opt/hermes/...` during the image build (used when
a workaround in our config surface isn't expressive enough). Never as
"opened upstream PR #...". When the upstream code naturally evolves past the
bug and we bump our pinned version, delete the entry.

When you discover a new bug, add it here BEFORE you forget the diagnostic
chain — these are expensive to re-derive from logs alone.

---

## Gateway model resolver ignores `model.name` (the canonical key)

**Status as of 2026-04-30:** confirmed in upstream commit corresponding to
`hermes-agent-0.11.0` (file: `gateway/run.py`, function:
`_resolve_gateway_model`). Workaround applied via Dockerfile.

### Symptom

Open WebUI (or any OpenAI-compatible client) talking to Hermes' `api_server`
gateway gets back HTTP 500 / non-retryable errors. Honeybot logs show:

```
⚠️  API call failed (attempt 1/3): BadRequestError [HTTP 400]
   🔌 Provider: anthropic  Model:                    ← empty!
   🌐 Endpoint: https://api.anthropic.com
   📝 Error: HTTP 400: model: String should have at least 1 character
```

Slack chats keep working — only the api_server-spawned agent is affected.
The request_dump JSON in `~/.hermes/sessions/request_dump_*.json` shows
`"model": ""` AND `"Authorization": "Bearer None"` in the outbound request
body — the empty model is the primary fault, the bad auth is a knock-on
because the provider client never gets fully initialized after model
resolution returns junk.

### Root cause

`gateway/run.py:_resolve_gateway_model()` reads:

```python
elif isinstance(model_cfg, dict):
    return model_cfg.get("default") or model_cfg.get("model") or ""
```

It looks for `model.default` or `model.model`. But `hermes config set
model.name <X>` (which is what the Dockerfile uses, and what the docs
recommend) writes `model.name`. So the gateway resolves the model to `""`,
that empty string flows through `_resolve_runtime_agent_kwargs()` into the
spawned `AIAgent`, and out the door to the provider.

The CLI agent path (used by Slack) does NOT go through
`_resolve_gateway_model()` — it reads `model.name` directly via
`load_cli_config()`. That's why Slack works and Open WebUI doesn't.

### Reproduce

```bash
cat > ~/.hermes/config.yaml <<'EOF'
model:
  provider: anthropic
  name: claude-opus-4-6
EOF
hermes gateway run &   # with api_server platform enabled
curl -s http://localhost:8642/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"hi"}]}'
# → 500, logs show outbound model=""
```

### Workaround (Dockerfile, applied)

`Dockerfile` writes the chosen model to BOTH `model.name` and
`model.default`:

```dockerfile
RUN hermes config set model.provider anthropic \
 && hermes config set model.name claude-opus-4-6 \
 && hermes config set model.default claude-opus-4-6
```

Both keys then resolve. The `name` key remains the canonical one (CLI agent
reads it); `default` exists only to satisfy the gateway resolver. If a
future migration changes the canonical key name, update both lines —
they're load-bearing for two different code paths.

### In-tree fix path (when/if we vendor /opt/hermes)

If the workaround stops being enough — e.g. another resolver also hardcodes
`model.default` — patch `gateway/run.py` directly during the image build:

```python
return (model_cfg.get("name")
        or model_cfg.get("default")
        or model_cfg.get("model")
        or "")
```

Apply via a `RUN` step in the Dockerfile that runs `sed`/`patch` against
`/opt/hermes/gateway/run.py` after the install. Add a smoke test in
`scripts/` that loads a config with `model: { name: ... }` and calls the
resolver; fail the build if it returns empty.

We don't apply that patch yet — the Dockerfile workaround is sufficient and
keeps `/opt/hermes` pristine, which makes upstream version bumps cleaner.

### Why the cascade looks like an auth bug

`Bearer None` shows up in the request_dump and looks like a separate auth
problem. It isn't — when `_resolve_runtime_agent_kwargs()` builds the
provider client with an empty model, the provider's auth-injection path
(which keys off the resolved model in some adapters) gets a None key and
serializes it literally as `Bearer None`. Fixing the model resolution
clears it. Don't go chasing `API_SERVER_KEY` / `ANTHROPIC_API_KEY`
1Password items — the keys are fine, the resolver is broken.
