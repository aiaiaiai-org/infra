// © 2026 aiaiaiai · aiaiaiai.org

// Deploy-time check of RELAY_ROUTES with the Worker's own parser. Prints each
// source and the kind of its destinations, never a URL or token.

import { parseRoutes } from "./routes.ts";

const routes = parseRoutes(process.env.RELAY_ROUTES ?? "");
let telegram = false;
for (const [source, route] of routes) {
  const kinds = route.targets.map((t) =>
    "discord" in t ? "discord" : "telegram",
  );
  telegram ||= kinds.includes("telegram");
  console.log(
    `${source} → ${kinds.join(", ")}${route.token ? " (token)" : ""}`,
  );
}
if (telegram && !process.env.TELEGRAM_BOT_TOKEN) {
  console.error("a route sends to Telegram, but TELEGRAM_BOT_TOKEN is not set");
  process.exit(1);
}
