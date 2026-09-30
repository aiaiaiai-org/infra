// © 2026 aiaiaiai · aiaiaiai.org

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { deliver, toDiscord, toTelegram } from "./destinations.ts";
import type { Notice } from "./github.ts";

const notice: Notice = {
  kind: "assigned",
  title: "nilx-one/web#42 <Map> pins @everyone",
  url: "https://github.com/nilx-one/web/issues/42",
  summary: "Assigned to @dasha",
  actor: { login: "0x0sky", html_url: "https://github.com/0x0sky" },
  context: "0x1 roadmap",
};

function recorder(status = 200) {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const fetcher = (async (url: string, init: RequestInit) => {
    calls.push({ url, body: JSON.parse(String(init.body)) });
    return new Response(null, { status });
  }) as typeof fetch;
  return { calls, fetcher };
}

describe("toDiscord", () => {
  it("builds an embed that can never ping", () => {
    assert.deepEqual(toDiscord(notice), {
      embeds: [
        {
          title: "nilx-one/web#42 <Map> pins @everyone",
          url: "https://github.com/nilx-one/web/issues/42",
          description: "Assigned to @dasha",
          color: 0x58a6ff,
          author: { name: "0x0sky", url: "https://github.com/0x0sky" },
          footer: { text: "0x1 roadmap" },
        },
      ],
      allowed_mentions: { parse: [] },
    });
  });
});

describe("toTelegram", () => {
  it("escapes HTML and keeps GitHub logins from becoming mentions", () => {
    const text = toTelegram(notice);
    assert.equal(
      text,
      [
        '<a href="https://github.com/nilx-one/web/issues/42"><b>nilx-one/web#42 &lt;Map&gt; pins @⁠everyone</b></a>',
        "Assigned to @⁠dasha",
        "<i>0x0sky · 0x1 roadmap</i>",
      ].join("\n"),
    );
    assert.doesNotMatch(text, /@\w/);
  });
});

describe("deliver", () => {
  it("posts to a Discord webhook", async () => {
    const { calls, fetcher } = recorder();
    const hook = "https://discord.com/api/webhooks/1/x";
    await deliver({ discord: hook }, notice, {}, fetcher);
    assert.equal(calls[0]?.url, hook);
    assert.deepEqual(calls[0]?.body, toDiscord(notice));
  });

  it("sends a Telegram message into the topic", async () => {
    const { calls, fetcher } = recorder();
    await deliver(
      { telegram: { chat: "-100123", topic: 7 } },
      notice,
      { telegramToken: "42:bot" },
      fetcher,
    );
    assert.equal(
      calls[0]?.url,
      "https://api.telegram.org/bot42:bot/sendMessage",
    );
    assert.deepEqual(calls[0]?.body, {
      chat_id: "-100123",
      message_thread_id: 7,
      text: toTelegram(notice),
      parse_mode: "HTML",
      link_preview_options: { is_disabled: true },
    });
  });

  it("reports failures without leaking the secret URL", async () => {
    await assert.rejects(
      deliver(
        { discord: "https://discord.com/api/webhooks/1/x" },
        notice,
        {},
        recorder(429).fetcher,
      ),
      /^Error: discord responded 429$/,
    );
    await assert.rejects(
      deliver(
        { telegram: { chat: "-100123" } },
        notice,
        {},
        recorder().fetcher,
      ),
      /TELEGRAM_BOT_TOKEN is not set/,
    );
    const broken = (async () => {
      throw new TypeError(
        "fetch failed: https://api.telegram.org/bot42:secret/sendMessage",
      );
    }) as typeof fetch;
    await assert.rejects(
      deliver(
        { telegram: { chat: "-100123" } },
        notice,
        { telegramToken: "42:secret" },
        broken,
      ),
      (error: Error) => !error.message.includes("secret"),
    );
  });
});
