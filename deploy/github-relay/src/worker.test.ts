// © 2026 aiaiaiai · aiaiaiai.org

import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { afterEach, describe, it, mock } from "node:test";
import worker, { type Env } from "./worker.ts";

const discord = "https://discord.com/api/webhooks/1/x";
const env: Env = {
  GITHUB_WEBHOOK_SECRET: "s3cret",
  TELEGRAM_BOT_TOKEN: "42:bot",
  RELAY_ROUTES: JSON.stringify({
    "nilx-one": { to: [{ discord }] },
    "nilx-one/web": { to: [{ telegram: { chat: "-100123" } }] },
  }),
};

function delivery(payload: unknown, event = "issues", secret = "s3cret") {
  const body = JSON.stringify(payload);
  return new Request("https://relay.example/", {
    method: "POST",
    headers: {
      "x-github-event": event,
      "x-hub-signature-256": `sha256=${createHmac("sha256", secret).update(body).digest("hex")}`,
    },
    body,
  });
}

const opened = {
  action: "opened",
  issue: {
    number: 1,
    title: "Pins",
    html_url: "https://github.com/nilx-one/web/issues/1",
  },
  repository: { full_name: "nilx-one/web" },
  organization: { login: "nilx-one" },
  sender: { login: "0x0sky" },
};

function stubFetch(status = 200) {
  return mock.method(
    globalThis,
    "fetch",
    async () => new Response(null, { status }),
  );
}

afterEach(() => mock.restoreAll());

describe("worker", () => {
  it("fans one verified event out to every routed destination", async () => {
    const fetch = stubFetch();
    const response = await worker.fetch(delivery(opened), env);
    assert.equal(response.status, 204);
    const urls = fetch.mock.calls.map((call) => call.arguments[0]);
    assert.deepEqual(urls.sort(), [
      "https://api.telegram.org/bot42:bot/sendMessage",
      discord,
    ]);
  });

  it("refuses unsigned deliveries and ignores unrouted sources", async () => {
    const fetch = stubFetch();
    assert.equal(
      (await worker.fetch(delivery(opened, "issues", "wrong"), env)).status,
      401,
    );
    const elsewhere = {
      ...opened,
      organization: { login: "elsewhere" },
      repository: { full_name: "elsewhere/x" },
    };
    assert.equal((await worker.fetch(delivery(elsewhere), env)).status, 202);
    assert.equal(
      (
        await worker.fetch(
          delivery({ zen: "hi", organization: { login: "nilx-one" } }, "ping"),
          env,
        )
      ).status,
      204,
    );
    assert.equal(fetch.mock.callCount(), 0);
  });

  it("answers 502 when a destination fails, so GitHub can redeliver", async () => {
    stubFetch(500);
    const response = await worker.fetch(delivery(opened), env);
    assert.equal(response.status, 502);
    assert.doesNotMatch(await response.text(), /42:bot|webhooks/);
  });

  it("answers 500 with the reason when RELAY_ROUTES is broken", async () => {
    const response = await worker.fetch(delivery(opened), {
      ...env,
      RELAY_ROUTES: "{}",
    });
    assert.equal(response.status, 500);
    assert.match(await response.text(), /non-empty/);
  });
});
