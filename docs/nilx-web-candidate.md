<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# First-stage 0x1 Web deployment (candidate)

The new Contabo host is still named edge-dev-1 and has passed pinned-SSH
preflight. This manually invoked workflow deploys internally accessible Web,
Telegram Mini App and Discord Activity candidates from a signed client image,
**not the production public nilx.one origin**.

Run **Stage 0x1 browser clients on edge-dev-1** on Infra master.
The workflow resolves the current nilx-one/web master SHA, verifies its
GHCR image digest attestation (package-web.yml) and checks that the new
host has no existing production-named 0x1 containers. It stages the image
on the isolated nilx-candidate Docker network with no published ports.
The Web candidate tests /health and browser paths. Two dedicated client
containers also test /health and / using CLIENT_ROOT=/srv/telegram-mini-app
and CLIENT_ROOT=/srv/discord-activity. Each uses the exact same verified
immutable image digest on the private network, with no published ports.

The Infra GITHUB_TOKEN must have GitHub Package read access to
ghcr.io/nilx-one/web. Configure **Manage Actions access** in the package
settings if absent. Do not add a personal access token. The temporary
Docker credential on the VPS is removed after pulling the image.

The staging map-data volume is separate and initially empty. Do not
infer PMTiles readiness from a successful /health response.

Before switching DNS to 158.220.74.54, migrate the production Identity
SQLite database with consistent backup/restore and preserved server-owned
keys, bring up correct production Caddy routes (nilx.one, Bond wildcard,
Market page), preserve Render-backed Core and Bot APIs, and validate TLS,
login, callbacks and maps against the new origin.

Do not rename edge-dev-1 until the server hostname, GitHub Environment
and SSH workflow checks can be changed together. No automatic or public
deploy trigger is introduced by this stage.
