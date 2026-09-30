// © 2026 aiaiaiai · aiaiaiai.org

import {
  buildMessage,
  githubProjectLookup,
  routeFor,
  verifySignature,
} from "./relay.ts";

export interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  RELAY_ROUTES: string;
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
    const route = routeFor(env.RELAY_ROUTES, payload);
    if (!route) return new Response("organization not routed", { status: 202 });

    const event = request.headers.get("x-github-event") ?? "";
    const options: Parameters<typeof buildMessage>[2] = {
      statusField: env.STATUS_FIELD || "Status",
    };
    if (route.token) options.lookup = githubProjectLookup(route.token);
    const message = await buildMessage(event, payload, options);
    if (!message) return new Response(null, { status: 204 });

    const discord = await fetch(route.discord, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(message),
    });
    // A non-2xx makes GitHub mark the delivery failed, so it can be redelivered.
    if (!discord.ok) {
      return new Response(`discord responded ${discord.status}`, {
        status: 502,
      });
    }
    return new Response(null, { status: 204 });
  },
};
