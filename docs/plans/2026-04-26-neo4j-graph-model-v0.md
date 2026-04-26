# Neo4j Graph Model v0 — Slack + Google Workspace

> **Scope:** Graph schema only. No ingestion, no Cypher loaders, no sync
> daemon yet. This is the contract every future loader writes against.

**Goal:** Define a minimal, opinionated property-graph schema in Neo4j that
unifies Slack and Google Workspace activity around a single `Person` node,
so we can answer cross-tool questions ("what did Eric send Jen this week?")
without joining four APIs at query time.

**Architecture:** One graph, one shared `Person` identity, per-source
content nodes, lightweight relationships. Slack and Google are peers — no
master/replica. Everything timestamped, everything sourced.

**Tech stack:** Neo4j 5 community (already in compose), Cypher, future
loaders in Python (neo4j driver). No APOC required for v0.

---

## Design principles

1. **One Person, many handles.** A human is one node. Slack user IDs and
   Google email addresses attach as `Identity` nodes, not properties, so
   we can add GitHub / HubSpot / Linear later without schema churn.
2. **Source-of-truth fields stay on source nodes.** A Slack message keeps
   its `ts`, `channel_id`, `thread_ts`. A Gmail message keeps its
   `message_id`, `thread_id`. Don't normalize away provenance.
3. **Relationships carry timestamps.** Every edge that represents an
   action (`SENT`, `RECEIVED`, `MENTIONED`, `ATTENDED`) has an `at`
   datetime property. Enables time-window queries without scanning nodes.
4. **No soft-deletes in v0.** If a message is deleted upstream, the loader
   removes the node. Audit history is out of scope.
5. **Idempotent MERGE keys.** Every node has a deterministic natural key
   (Slack ts + channel, Gmail message_id, etc.) so re-running a loader
   never creates duplicates.

---

## Node labels

### `:Person`
The human. Created once, referenced everywhere.

| Property      | Type     | Notes                                   |
|---------------|----------|-----------------------------------------|
| `id`          | string   | UUID, generated on first sight          |
| `display_name`| string   | Best-known human name                   |
| `created_at`  | datetime | First-sight timestamp                   |

**Constraint:** `CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;`

### `:Identity`
A handle on a specific platform that resolves to a `Person`.

| Property    | Type   | Notes                                                |
|-------------|--------|------------------------------------------------------|
| `platform`  | string | `slack` \| `google` \| `github` (future) \| ...      |
| `handle`    | string | Slack user ID (`U…`) or email address                |
| `verified`  | bool   | True only if proven via OAuth or admin assertion     |

**Constraint:** `CREATE CONSTRAINT identity_unique IF NOT EXISTS FOR (i:Identity) REQUIRE (i.platform, i.handle) IS UNIQUE;`

### `:SlackChannel`
| Property     | Type   | Notes                              |
|--------------|--------|------------------------------------|
| `id`         | string | `C…` channel ID                    |
| `name`       | string | Current channel name               |
| `is_private` | bool   |                                    |

**Constraint:** `CREATE CONSTRAINT slack_channel_id IF NOT EXISTS FOR (c:SlackChannel) REQUIRE c.id IS UNIQUE;`

### `:SlackMessage`
| Property    | Type     | Notes                                              |
|-------------|----------|----------------------------------------------------|
| `ts`        | string   | Slack timestamp, e.g. `1714067123.001200`          |
| `channel_id`| string   | Composite key with `ts`                            |
| `thread_ts` | string   | Null if top-level                                  |
| `text`      | string   | Raw text (no markdown rendering in v0)             |
| `at`        | datetime | Parsed from `ts`                                   |

**Constraint:** `CREATE CONSTRAINT slack_message_key IF NOT EXISTS FOR (m:SlackMessage) REQUIRE (m.channel_id, m.ts) IS UNIQUE;`

### `:GmailMessage`
| Property    | Type     | Notes                                              |
|-------------|----------|----------------------------------------------------|
| `message_id`| string   | RFC 5322 Message-ID, primary key                   |
| `thread_id` | string   | Gmail thread                                       |
| `subject`   | string   |                                                    |
| `at`        | datetime | Internal date                                      |

**Constraint:** `CREATE CONSTRAINT gmail_message_id IF NOT EXISTS FOR (m:GmailMessage) REQUIRE m.message_id IS UNIQUE;`

### `:CalendarEvent`
| Property    | Type     | Notes                                              |
|-------------|----------|----------------------------------------------------|
| `event_id`  | string   | Google Calendar event ID                           |
| `calendar_id`| string  | Owning calendar                                    |
| `summary`   | string   |                                                    |
| `start`     | datetime |                                                    |
| `end`       | datetime |                                                    |

**Constraint:** `CREATE CONSTRAINT calendar_event_key IF NOT EXISTS FOR (e:CalendarEvent) REQUIRE (e.calendar_id, e.event_id) IS UNIQUE;`

### `:DriveFile`
| Property    | Type     | Notes                                              |
|-------------|----------|----------------------------------------------------|
| `file_id`   | string   | Google Drive file ID                               |
| `name`      | string   |                                                    |
| `mime_type` | string   |                                                    |
| `modified_at`| datetime|                                                    |

**Constraint:** `CREATE CONSTRAINT drive_file_id IF NOT EXISTS FOR (f:DriveFile) REQUIRE f.file_id IS UNIQUE;`

---

## Relationship types

All edges with an action carry `at: datetime`. Counts/aggregates are query-
time concerns, not stored.

| Edge                                                | From → To                       | Properties     | Notes                                  |
|-----------------------------------------------------|---------------------------------|----------------|----------------------------------------|
| `(:Person)-[:HAS_IDENTITY]->(:Identity)`            | Person → Identity               |                | Many per person                        |
| `(:Identity)-[:SENT]->(:SlackMessage)`              | Identity → SlackMessage         | `at`           | Author of message                      |
| `(:SlackMessage)-[:IN_CHANNEL]->(:SlackChannel)`    | Message → Channel               |                |                                        |
| `(:SlackMessage)-[:REPLY_TO]->(:SlackMessage)`      | Message → parent                |                | Thread parent only                     |
| `(:SlackMessage)-[:MENTIONS]->(:Identity)`          | Message → Identity              |                | Resolved `<@U…>` mentions              |
| `(:Identity)-[:SENT]->(:GmailMessage)`              | Identity → Gmail                | `at`           | From: header                           |
| `(:GmailMessage)-[:TO]->(:Identity)`                | Gmail → Identity                |                | Each To: recipient                     |
| `(:GmailMessage)-[:CC]->(:Identity)`                | Gmail → Identity                |                |                                        |
| `(:GmailMessage)-[:REPLY_TO]->(:GmailMessage)`      | Gmail → parent                  |                | Resolved via `In-Reply-To`             |
| `(:Identity)-[:ATTENDED]->(:CalendarEvent)`         | Identity → Event                | `response`     | `accepted` \| `tentative` \| `declined`|
| `(:Identity)-[:ORGANIZED]->(:CalendarEvent)`        | Identity → Event                |                |                                        |
| `(:Identity)-[:OWNS]->(:DriveFile)`                 | Identity → File                 |                | Drive owner                            |
| `(:Identity)-[:SHARED_WITH]->(:DriveFile)`          | Identity → File                 | `role`         | `reader` \| `writer` \| `commenter`    |

---

## Identity resolution rules (the only "hard" part)

When a loader sees a new `(platform, handle)` it must decide: attach to an
existing `Person`, or create a new one?

**v0 rules, in order:**

1. **Exact match on existing Identity** → use that Person.
2. **Email match across platforms.** If a Slack user's profile email
   equals a known Google Identity's handle, link to the same Person.
3. **No match** → create a new `Person` with `display_name` = best
   available (Slack `real_name`, else Gmail `From` display name, else
   handle), then attach the Identity.

**Out of scope for v0:** fuzzy name matching, manual merges, splits.
These need a UI and an audit trail. Punt to v1.

---

## Initial Cypher (run once on empty DB)

```cypher
CREATE CONSTRAINT person_id IF NOT EXISTS
  FOR (p:Person) REQUIRE p.id IS UNIQUE;

CREATE CONSTRAINT identity_unique IF NOT EXISTS
  FOR (i:Identity) REQUIRE (i.platform, i.handle) IS UNIQUE;

CREATE CONSTRAINT slack_channel_id IF NOT EXISTS
  FOR (c:SlackChannel) REQUIRE c.id IS UNIQUE;

CREATE CONSTRAINT slack_message_key IF NOT EXISTS
  FOR (m:SlackMessage) REQUIRE (m.channel_id, m.ts) IS UNIQUE;

CREATE CONSTRAINT gmail_message_id IF NOT EXISTS
  FOR (m:GmailMessage) REQUIRE m.message_id IS UNIQUE;

CREATE CONSTRAINT calendar_event_key IF NOT EXISTS
  FOR (e:CalendarEvent) REQUIRE (e.calendar_id, e.event_id) IS UNIQUE;

CREATE CONSTRAINT drive_file_id IF NOT EXISTS
  FOR (f:DriveFile) REQUIRE f.file_id IS UNIQUE;

CREATE INDEX slack_message_at IF NOT EXISTS
  FOR (m:SlackMessage) ON (m.at);

CREATE INDEX gmail_message_at IF NOT EXISTS
  FOR (m:GmailMessage) ON (m.at);

CREATE INDEX calendar_event_start IF NOT EXISTS
  FOR (e:CalendarEvent) ON (e.start);
```

---

## Sample queries this enables

```cypher
// Everything Eric sent (Slack + Gmail) in the last 7 days
MATCH (p:Person {display_name: "Eric Hodonsky"})-[:HAS_IDENTITY]->(i:Identity)-[:SENT]->(m)
WHERE m.at > datetime() - duration({days: 7})
RETURN labels(m)[0] AS source, m.at AS at, coalesce(m.subject, m.text) AS preview
ORDER BY at DESC;

// People Eric talks to most across all channels (last 30d)
MATCH (eric:Person {display_name: "Eric Hodonsky"})-[:HAS_IDENTITY]->(:Identity)-[:SENT]->(m)
WHERE m.at > datetime() - duration({days: 30})
MATCH (m)-[:MENTIONS|TO|CC]->(other:Identity)<-[:HAS_IDENTITY]-(p:Person)
WHERE p <> eric
RETURN p.display_name, count(*) AS interactions
ORDER BY interactions DESC LIMIT 10;

// Calendar events that produced no follow-up email or Slack thread
MATCH (e:CalendarEvent)
WHERE e.start > datetime() - duration({days: 14})
  AND NOT EXISTS {
    MATCH (i:Identity)-[:ATTENDED]->(e)
    MATCH (i)-[:SENT]->(m) WHERE m.at > e.end AND m.at < e.end + duration({hours: 24})
  }
RETURN e.summary, e.start ORDER BY e.start DESC;
```

---

## Open questions (block v1 ingestion, not v0 schema)

1. **Reactions on Slack messages** — model as a relationship
   `(:Identity)-[:REACTED {emoji, at}]->(:SlackMessage)` or skip in v0?
2. **Email body** — store on `:GmailMessage` (lets us full-text search in
   Neo4j), keep only in Elasticsearch (already in compose), or both?
3. **Drive file content** — out of scope for v0 (graph is about *who
   touched what*, not *what's inside*). Confirm.
4. **Retention** — do we drop nodes older than N days, or keep forever?
   Affects volume estimates.

---

## Next steps (not part of v0)

- v1: Slack backfill loader (idempotent, resumable, batched).
- v1: Gmail backfill loader (last 90 days).
- v1: Calendar + Drive loaders.
- v2: Real-time updates via Slack Events API + Gmail push notifications.
- v2: Identity merge/split UI.
