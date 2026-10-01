<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# GitHub relay

A Cloudflare Worker that carries GitHub webhook events from **point A**, an
organization or a single repository, to **point B**, Discord channels and
Telegram chats.

```text
GitHub org / repo webhook ──► github-relay ──┬──► Discord channel (webhook)
                                             └──► Telegram chat or topic (bot)
```

| GitHub event                                    | Message                                 |
| ----------------------------------------------- | --------------------------------------- |
| `issues.opened`                                 | New task, assigned to @login            |
| `issues.assigned` / `unassigned`                | Assigned to @login / Unassigned @login  |
| `issues.closed` / `reopened`                    | Closed as completed / not planned, etc. |
| `projects_v2_item.edited` on the `Status` field | Status: Todo → In Progress              |

Project status events are sent only to organization webhooks (repository
webhooks don't get them), and GitHub Actions can't trigger on them, which is
why this is a Worker rather than a workflow.

- Deliveries are verified with the shared webhook secret (`X-Hub-Signature-256`).
- Sources not listed in `RELAY_ROUTES` are dropped.
- Issues from private repositories are skipped, so a public server never sees
  them.
- Nothing pings anyone. Discord gets empty `allowed_mentions`, so `@everyone`
  in an issue title stays text. Telegram gets a word joiner after `@`, so a
  GitHub login never turns into a Telegram mention of a stranger.
- If any destination fails, the Worker answers `502`, and GitHub lets you
  redeliver from _Recent Deliveries_. The redelivery goes to every destination
  of that source again.

## Routes

`RELAY_ROUTES` is JSON. Each key is a source: an organization or user login
(`nilx-one`) or one repository (`nilx-one/web`).

```json
{
  "nilx-one": {
    "token": "github_pat_…",
    "to": [{ "discord": "https://discord.com/api/webhooks/…" }]
  },
  "nilx-one/web": {
    "to": [{ "telegram": { "chat": "-1001234567890", "topic": 7 } }]
  },
  "0x0sky/notes": {
    "to": [{ "telegram": { "chat": "@nilx_tasks" } }]
  }
}
```

An event collects the destinations of its owner and of its repository. Above,
`nilx-one/web` goes to Discord _and_ Telegram, the rest of `nilx-one` only to
Discord. A destination listed under both is sent to once. Project status events
carry no repository, so they follow the owner's route.

- `discord`: a channel webhook (_Edit Channel → Integrations → Webhooks → New
  Webhook → Copy Webhook URL_).
- `telegram.chat`: a chat ID (`-100…` for groups and channels) or `@channel`.
  `topic` is the forum topic (`message_thread_id`) and is optional. Add the
  relay's bot to the chat; in a channel it must be an admin that can post.
- `token` (optional): a fine-grained token whose resource owner is that
  organization, read-only on _Issues_, _Pull requests_ and organization
  _Projects_. Status messages use it for the task title and link; without it
  they read "Project item". A repository's own token wins over its owner's.

## Deploy

1. In `aiaiaiai-org/infra` create the Environment `github-relay` with these
   secrets:
   - `CLOUDFLARE_API_TOKEN`: token from the _Edit Cloudflare Workers_ template
   - `CLOUDFLARE_ACCOUNT_ID`
   - `RELAY_WEBHOOK_SECRET`: any long random string (`openssl rand -hex 32`)
   - `RELAY_ROUTES`: the JSON above
   - `TELEGRAM_BOT_TOKEN`: from [@BotFather](https://t.me/BotFather); needed
     only if a route sends to Telegram. A dedicated bot keeps this Worker
     apart from `prism-hubot`.
2. Run **Deploy GitHub relay**. It checks `RELAY_ROUTES` with the Worker's own
   parser, runs the tests, deploys, and uploads the Worker secrets. The log
   prints the Worker URL, `https://github-relay.<account>.workers.dev`.
3. Add a webhook at each source. For an organization, that's
   `github.com/organizations/<org>/settings/hooks`. For a single repository
   outside a routed organization, it's the repository's _Settings → Webhooks_.
   - Payload URL: the Worker URL
   - Content type: `application/json`
   - Secret: `RELAY_WEBHOOK_SECRET`
   - Events: _Let me select individual events_ → **Issues**, plus **Projects
     v2 items** on an organization

   Don't add a repository webhook inside an organization that already has one:
   GitHub would send every event twice. Route the repository by its
   `owner/repo` key instead.

GitHub's `ping` gets `204` from a routed source and `202 source not routed`
otherwise. The status field defaults to `Status`; change `STATUS_FIELD` in
`wrangler.toml` if a board uses another name.

## Code

- `src/github.ts`: point A. Verifies the signature and turns an event into a
  `Notice`.
- `src/routes.ts`: parses `RELAY_ROUTES` and resolves a delivery's
  destinations.
- `src/destinations.ts`: point B. Renders a `Notice` for Discord or Telegram
  and sends it.
- `src/worker.ts`: wires them together.
- `src/check-routes.ts`: the deploy-time check.

Adding a destination (Slack, Matrix, email) means one more `Target` variant in
`routes.ts` and one more renderer in `destinations.ts`.

```sh
node --test deploy/github-relay/src/*.test.ts
```

Node 22.18+ runs the TypeScript directly; nothing needs installing.
