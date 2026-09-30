// © 2026 aiaiaiai · aiaiaiai.org

// Which point B each delivery goes to. RELAY_ROUTES maps a source (an
// organization or user login, or one repository as "owner/repo") to
// destinations and an optional read-only GitHub token:
//
// {
//   "nilx-one":     { "token": "github_pat_…", "to": [{ "discord": "https://discord.com/api/webhooks/…" }] },
//   "nilx-one/web": { "to": [{ "telegram": { "chat": "-1001234567890", "topic": 7 } }] }
// }
//
// A delivery collects the destinations of its owner and of its repository;
// the same destination listed under both is sent to once.

export type Target =
  { discord: string } | { telegram: { chat: string; topic?: number } };

export interface Route {
  targets: Target[];
  token?: string;
}

export type RouteTable = Map<string, Route>;

const SOURCE = /^[a-z0-9][a-z0-9-]*(\/[a-z0-9._-]+)?$/;
const DISCORD_WEBHOOK =
  /^https:\/\/(discord|discordapp)\.com\/api\/webhooks\/\d+\/[\w-]+$/;
const TELEGRAM_CHAT = /^(-?\d+|@[A-Za-z0-9_]{5,32})$/;

export function parseRoutes(json: string): RouteTable {
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    throw new Error("RELAY_ROUTES is not valid JSON");
  }
  if (!isObject(raw) || Object.keys(raw).length === 0) {
    throw new Error("RELAY_ROUTES must be a non-empty object");
  }
  const table: RouteTable = new Map();
  for (const [key, entry] of Object.entries(raw)) {
    const source = key.toLowerCase();
    if (!SOURCE.test(source)) {
      throw new Error(`route "${key}": expected "owner" or "owner/repo"`);
    }
    if (!isObject(entry) || !Array.isArray(entry.to) || !entry.to.length) {
      throw new Error(
        `route "${key}": "to" must list at least one destination`,
      );
    }
    const route: Route = {
      targets: entry.to.map((target, i) =>
        parseTarget(target, `${key}.to[${i}]`),
      ),
    };
    if (entry.token !== undefined) {
      if (typeof entry.token !== "string" || !entry.token) {
        throw new Error(`route "${key}": "token" must be a non-empty string`);
      }
      route.token = entry.token;
    }
    table.set(source, route);
  }
  return table;
}

function parseTarget(raw: unknown, where: string): Target {
  if (isObject(raw) && typeof raw.discord === "string") {
    if (!DISCORD_WEBHOOK.test(raw.discord)) {
      throw new Error(`${where}: "discord" must be a Discord webhook URL`);
    }
    return { discord: raw.discord };
  }
  if (isObject(raw) && isObject(raw.telegram)) {
    const { chat, topic } = raw.telegram;
    const id = typeof chat === "number" ? String(chat) : chat;
    if (typeof id !== "string" || !TELEGRAM_CHAT.test(id)) {
      throw new Error(
        `${where}: "telegram.chat" must be a chat ID or @channel`,
      );
    }
    if (topic === undefined) return { telegram: { chat: id } };
    if (!Number.isInteger(topic) || (topic as number) < 1) {
      throw new Error(`${where}: "telegram.topic" must be a positive integer`);
    }
    return { telegram: { chat: id, topic: topic as number } };
  }
  throw new Error(`${where}: expected {"discord": …} or {"telegram": {…}}`);
}

export function resolveRoute(
  table: RouteTable,
  payload: unknown,
): Route | null {
  const p = (isObject(payload) ? payload : {}) as {
    organization?: { login?: string };
    repository?: { full_name?: string; owner?: { login?: string } };
  };
  const owner = (
    p.organization?.login ?? p.repository?.owner?.login
  )?.toLowerCase();
  const repo = p.repository?.full_name?.toLowerCase();
  const matched = [repo, owner]
    .map((source) => (source ? table.get(source) : undefined))
    .filter((route): route is Route => route !== undefined);
  if (!matched.length) return null;

  const seen = new Set<string>();
  const route: Route = { targets: [] };
  for (const { targets, token } of matched) {
    for (const target of targets) {
      const id = JSON.stringify(target);
      if (seen.has(id)) continue;
      seen.add(id);
      route.targets.push(target);
    }
    // The repository's own token wins; it is listed first.
    if (token && !route.token) route.token = token;
  }
  return route;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
