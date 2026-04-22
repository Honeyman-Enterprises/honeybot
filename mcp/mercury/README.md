# Mercury MCP (stub — Phase 5)

Custom MCP server wrapping the Mercury Bank API for read-only operations.

## Scope

Read-only v1:

- `list_accounts()` — return Mercury account list + IDs
- `get_balance(account_id)` — current balance
- `list_transactions(account_id, since, until)` — transaction history
- `get_transaction(transaction_id)` — single transaction detail
- `list_incoming_checks()` — checks deposited via mobile (read-only; deposits are manual)

Explicitly out of scope (v1): `create_payment`, `send_ach`, `send_wire`.
Mercury's payment-initiation API is gated to their enterprise Treasury
product — we're not on it, and per Eric's direction any payment flow
would require `/approve` gating anyway.

## Credentials

```
op://Honeybot/Mercury/api_token
```

Populated in 1Password when this phase starts. Empty = MCP not enabled.

## Implementation plan

- Python 3.12 + `mcp` SDK + `httpx`
- Stdio transport when launched directly; HTTP/SSE on port 8000 inside
  the honeynet network otherwise
- Rate limits: Mercury allows ~100 req/min; we cache `list_accounts`
  and `get_balance` results for 30s to stay well under

Not implemented yet. Phase 5.
