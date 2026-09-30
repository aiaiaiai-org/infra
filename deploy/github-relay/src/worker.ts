// © 2026 aiaiaiai · aiaiaiai.org

import { deliver } from "./destinations.ts";
import { buildNotice, githubProjectLookup, verifySignature } from "./github.ts";
import { parseRoutes, resolveRoute } from "./routes.ts";

export interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  RELAY_ROUTES: string;
  TELEGRAM_BOT_TOKEN?: string;
  STATUS_FIELD?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") {
      return new Response("method not allowed", { status: 405 });
    }
    const body = await request.text();
    const signature = request.headers.get("x-hub-signature-256");
    if (!(await verifySignature(env.GITHUB_WEBHOOK_SECRET, body, signature))) {
      return new Response("bad signature", { status: 401 });
    }

    const payload: unknown = JSON.parse(body);
    let routes: ReturnType<typeof parseRoutes>;
    try {
      routes = parseRoutes(env.RELAY_ROUTES);
    } catch (error) {
      return new Response((error as Error).message, { status: 500 });
    }
    const route = resolveRoute(routes, payload);
    if (!route) return new Response("source not routed", { status: 202 });

    const event = request.headers.get("x-github-event") ?? "";
    const options: Parameters<typeof buildNotice>[2] = {
      statusField: env.STATUS_FIELD || "Status",
    };
    if (route.token) options.lookup = githubProjectLookup(route.token);
    const notice = await buildNotice(event, payload, options);
    if (!notice) return new Response(null, { status: 204 });

    const results = await Promise.allSettled(
      route.targets.map((target) =>
        deliver(target, notice, { telegramToken: env.TELEGRAM_BOT_TOKEN }),
      ),
    );
    const failures = results
      .filter((r): r is PromiseRejectedResult => r.status === "rejected")
      .map((r) =>
        String(r.reason instanceof Error ? r.reason.message : r.reason),
      );
    // A non-2xx makes GitHub mark the delivery failed, so it can be redelivered.
    if (failures.length)
      return new Response(failures.join("\n"), { status: 502 });
    return new Response(null, { status: 204 });
  },
};
