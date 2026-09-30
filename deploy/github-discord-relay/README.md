<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# GitHub → Discord task relay

A Cloudflare Worker that receives **organization** webhooks and posts task
updates to that organization's Discord channel:

| GitHub event                                    | Discord message                         |
| ----------------------------------------------- | --------------------------------------- |
| `issues.opened`                                 | New task, assigned to @login            |
| `issues.assigned` / `unassigned`                | Assigned to @login / Unassigned @login  |
| `issues.closed` / `reopened`                    | Closed as completed / not planned, etc. |
| `projects_v2_item.edited` on the `Status` field | Status: Todo → In Progress              |

Project status events are sent only to organization webhooks (repository
webhooks don't get them), and GitHub Actions can't trigger on them. That is why
this runs as a small relay instead of a workflow.

- One Worker serves every organization. `RELAY_ROUTES` maps an organization
  login to its Discord channel; deliveries from organizations not listed there
  are dropped.
- Deliveries are verified with the shared webhook secret (`X-Hub-Signature-256`).
- Issues from private repositories are skipped, so a public server never sees
  them.
- Messages never ping anyone: `allowed_mentions` is empty, so `@everyone` in an
  issue title stays text.

## Routes

`RELAY_ROUTES` is JSON:

```json
{
  "nilx-one": {
    "discord": "https://discord.com/api/webhooks/…",
    "token": "github_pat_…"
  }
}
```

- `discord`: the channel webhook (_Edit Channel → Integrations → Webhooks →
  New Webhook → Copy Webhook URL_).
- `token` (optional): a fine-grained token whose resource owner is that
  organization, with read-only _Issues_, _Pull requests_ and organization
  _Projects_ access. Status messages use it to show the task title and link;
  without it they read "Project item".

Adding an organization is one more key plus one more organization webhook.

## Deploy

1. In `aiaiaiai-org/infra` create the Environment `github-discord-relay` with
   these secrets:
   - `CLOUDFLARE_API_TOKEN`: token from the _Edit Cloudflare Workers_ template
   - `CLOUDFLARE_ACCOUNT_ID`
   - `RELAY_WEBHOOK_SECRET`: any long random string (`openssl rand -hex 32`)
   - `RELAY_ROUTES`: the JSON above
2. Run **Deploy GitHub Discord relay**. It checks the secrets, runs the tests,
   deploys, and uploads the Worker secrets. The log prints the Worker URL,
   `https://github-discord-relay.<account>.workers.dev`.
3. For each organization in `RELAY_ROUTES`:
   `github.com/organizations/<org>/settings/hooks` → _Add webhook_:
   - Payload URL: the Worker URL
   - Content type: `application/json`
   - Secret: `RELAY_WEBHOOK_SECRET`
   - Events: _Let me select individual events_ → **Issues** and
     **Projects v2 items**

GitHub's `ping` gets `204` from a routed organization and `202 organization
not routed` otherwise. _Recent Deliveries_ on the webhook shows the relay's reply to each
delivery, and failed Discord posts can be redelivered from there.

The status field defaults to `Status`; change `STATUS_FIELD` in
`wrangler.toml` if a board uses another name.

## Test

```sh
node --test deploy/github-discord-relay/src/*.test.ts
```

Node 22.18+ runs the TypeScript directly; nothing needs installing.
