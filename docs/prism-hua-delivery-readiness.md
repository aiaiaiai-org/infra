# Prism Hub ↔ h-ua-bot readiness (no Telegram sends)

This is a **manual, non-delivering** check for the four-source air-threat
notification pipeline. It does not deploy any service or modify subscriptions.

## The first operational check

After a separately authorised activation of both workloads on `edge-prod-2`,
open **infra → Actions → Verify h-ua delivery connection → Run workflow**.

The workflow runs in the existing `edge-prod-2` GitHub Environment and reads
**only** the environment's `PRISM_BOT_DELIVERY_SECRET`, as used by the Hub
workload. It does not need the bot's encrypted `HUA_DELIVERY_SECRET`, Telegram
token, bot-scoped `HUA_HUB_TOKEN`, SSH keys or database passwords.

It checks:
1. `https://api.aiaiaiai.org/prism-hub/healthz` returns JSON `status=ok`.
2. `https://api.aiaiaiai.org/hua-bot/health` returns JSON `status=ok`.
3. A deliberately invalid `{}` authenticated request to
   `https://api.aiaiaiai.org/hua-bot/api/v1/delivery` receives HTTP 400
   `invalid_request`, proving the *Hub-owned* secret is accepted by the
   **running** bot after the public edge strips the prefix.

The request has **no chat ID, message text, idempotency key or topic**.
A successful run **cannot** send a Telegram message. The secret is carried
in an environment variable and a private, temporary curl header file,
never printed in logs or embedded in the command-line arguments.

If the third check returns HTTP 401, compare the *effective runtime* values
of the Hub's `PRISM_BOT_DELIVERY_SECRET` and bot producer's
`HUA_DELIVERY_SECRET` without printing either. Updating a GitHub secret
does not change running containers; both services must be separately
redeployed after a coordinated secret rotation.

## Next: controlled end-to-end verification

A green handshake proves only routing and authentication between the Hub
delivery gateway and the bot. Before declaring the feature live, verify:

- `HUA_HUB_ORIGIN=https://api.aiaiaiai.org/prism-hub`,
  `HUA_HUB_PROVIDER_SCOPE=h-ua-bot` and `HUA_ALERT_CHANNEL=alerts`;
- the bot's `HUA_HUB_TOKEN` is a current, nonrevoked Prism Hub service
  principal credential scoped to `actors:onboard`, `actors:resolve`,
  `bot_instances:read`, `bot_instances:manage`,
  `alert_subscriptions:read`, `alert_subscriptions:manage`;
- the four collector source cursors `vanek_nikolaev`, `kpszsu`,
  `war_monitor`, `monitorwarr` advance and failures are visible in Hub
  scheduler logs (not merely in HTTP health);
- a consenting **private test chat** can issue `/start`, send its
  location, receive a saved-subscription confirmation and read `/status`;
- an independently sourced **real** threat report whose published
  coverage includes the test chat's cell is eventually rendered by
  Porter, queued by Hub and delivered by Telegram exactly once.

Do **not** forge a threat or a source clear in public channels, send
unsolicited production alerts, or interpret no messages as safety.
`/stop` must remove the test subscription. Never expose exact
coordinates, chat IDs or secrets in issues and Actions logs.

## Independent blocker: recoverability

The [Prism PostgreSQL backup issue #60](https://github.com/aiaiaiai-org/infra/issues/60)
must be resolved before production rollout is treated as recoverable.
Scheduled encrypted offsite dumps were failing on October 26 because
`BACKUP_S3_ENDPOINT` was absent from the `edge-prod-2` Environment.
A successful upload and an isolated restore test are separate gates.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
