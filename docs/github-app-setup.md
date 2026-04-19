# GitHub App setup — "Honeybot" self-edit identity

This is the one-time runbook to create the GitHub App that the honeybot
container uses to push branches and open pull requests against its own repo.
After this is done, the container mints short-lived installation tokens from
1Password; no long-lived PAT is ever stored.

Audience: a human with org admin rights on `Honeyman-Enterprises` and access
to the `Honeybot` 1Password vault.

---

## Why an App, not a PAT

- **Scope** — the App is installed on exactly one repo
  (`Honeyman-Enterprises/honeybot`). Even if the private key leaked, an
  attacker could only touch that one repo.
- **Token lifetime** — installation tokens expire in ~60 minutes. There is
  no long-lived secret with `contents:write` sitting in 1Password.
- **Revocation** — uninstall the App from the repo in the GitHub UI and
  every future token mint fails. No coordination with downstream consumers.
- **Audit** — every API call attributes to the App name in the audit log,
  distinguishable from human pushes.

---

## 1. Create the App

1. Go to **Settings → Developer settings → GitHub Apps → New GitHub App**
   on the `Honeyman-Enterprises` org (not your personal account).
2. Fill out:
   - **GitHub App name**: `Honeybot Self-Edit`
   - **Homepage URL**: `https://github.com/Honeyman-Enterprises/honeybot`
   - **Webhook**: **uncheck "Active"**. We do not receive webhooks — the
     container polls via `gh` when it wants state.
   - **Callback / Setup URLs**: leave blank.
3. **Repository permissions**:
   - **Contents**: `Read and write` — needed to push branches.
   - **Pull requests**: `Read and write` — needed to open/update PRs.
   - **Metadata**: `Read-only` (auto-selected, required).
   - Leave every other permission at `No access`.
4. **Organization permissions**: leave everything at `No access`.
5. **User permissions**: leave everything at `No access`.
6. **Where can this app be installed?** → **Only on this account**.
7. Click **Create GitHub App**.

Record the **App ID** shown at the top of the settings page — a number
like `123456`. This is not secret but it's paired with the private key.

## 2. Generate the private key

1. Still on the App's settings page, scroll to **Private keys**.
2. Click **Generate a private key**. A `.pem` file downloads.
3. Treat this like a password. Do not commit it, do not Slack it.

You should now have a file like
`honeybot-self-edit.2025-04-18.private-key.pem`.

## 3. Install the App on the repo

1. In the App settings sidebar, click **Install App**.
2. Select the `Honeyman-Enterprises` org → **Only select repositories** →
   pick `honeybot`.
3. Click **Install**.
4. After install, the browser URL looks like
   `https://github.com/settings/installations/12345678`. That number is the
   **Installation ID** — record it.

## 4. Store the three values in 1Password

In the `Honeybot` vault, edit the existing `GitHub Bot` item (or create it
if it doesn't exist yet — the service account needs `write_items` on this
vault). Add three fields:

| Field               | Type     | Value                                         |
|---------------------|----------|-----------------------------------------------|
| `app_id`            | text     | The numeric App ID from step 1                |
| `installation_id`   | text     | The numeric Installation ID from step 3       |
| `private_key`       | password | Paste the **entire** PEM including `BEGIN`/`END` lines |

The PEM must include line breaks. 1Password password fields preserve them
correctly; if you paste into a plain "text" field the newlines may be
stripped and the token mint will fail with "PEM key likely malformed".

Verify with:

```bash
op read 'op://Honeybot/GitHub Bot/private_key' | head -1
# expected: -----BEGIN RSA PRIVATE KEY-----
# (or "-----BEGIN PRIVATE KEY-----" for PKCS#8)
```

## 5. Delete the `.pem` from disk

Once it's in 1Password, shred the downloaded file:

```bash
# macOS
rm -P ~/Downloads/honeybot-self-edit.*.private-key.pem
# Linux
shred -u ~/Downloads/honeybot-self-edit.*.private-key.pem
```

If the key ever leaks: go back to the App settings, click **Delete** on the
old key, generate a new one, update `op://Honeybot/GitHub Bot/private_key`.
Existing installation tokens stay valid until their TTL expires (~60 min
max).

## 6. Set the dev allow-list

In the same 1Password item, add a `dev_slack_users` field — comma-separated
Slack user IDs who are allowed to invoke `honeybot-dev`:

```
U01ABCDEFGH,U09ZYXWVUTS
```

`init-workspace.sh` refuses if the requesting user's Slack ID isn't in this
list. Adding/removing people is a vault edit, not a redeploy.

## 7. Verify from inside the container

```bash
docker compose exec hermes bash -lc '
  export HONEYBOT_SLACK_USER=U01ABCDEFGH   # must be in dev_slack_users
  export HONEYBOT_REPO_SLUG=Honeyman-Enterprises/honeybot
  ./skills/honeybot-dev/bin/init-workspace.sh
'
```

Expected final line:

```
init-workspace: ready at /home/honeybot/workspace/honeybot on main @ <sha>
```

If you see `could not mint GitHub App installation token`, the three vault
fields are wrong or the App isn't installed on the target repo. The error
message from the helper (one line above) tells you which one.

---

## What lives where — quick reference

| Thing                    | Location                                     |
|--------------------------|----------------------------------------------|
| App definition           | GitHub org → Developer settings              |
| App private key          | `op://Honeybot/GitHub Bot/private_key`       |
| App ID                   | `op://Honeybot/GitHub Bot/app_id`            |
| Installation ID          | `op://Honeybot/GitHub Bot/installation_id`   |
| Dev allow-list           | `op://Honeybot/GitHub Bot/dev_slack_users`   |
| Token-minting helper     | `skills/_lib/gh-app-token.sh` (in image)     |
| Service account token    | `/etc/honeybot/op.env` on EC2, `./op.env` dev |

The service account token is the root of trust: it can read the App
credentials from 1Password. Guard it accordingly (the EC2 bootstrap places
it at `chmod 600` owned by `ec2-user`).
