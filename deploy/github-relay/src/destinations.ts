// © 2026 aiaiaiai · aiaiaiai.org

// Point B: renders a Notice for each destination and sends it. Nothing here
// ever pings: Discord gets empty allowed_mentions, and Telegram gets a word
// joiner after every "@" so GitHub logins never turn into Telegram mentions.

import type { Notice, NoticeKind } from "./github.ts";
import type { Target } from "./routes.ts";

const COLORS: Record<NoticeKind, number> = {
  opened: 0x3fb950,
  assigned: 0x58a6ff,
  unassigned: 0x8b949e,
  closed: 0xa371f7,
  reopened: 0xd29922,
  status: 0xf0883e,
};

export function toDiscord(notice: Notice): unknown {
  const embed: Record<string, unknown> = {
    title: notice.title,
    description: notice.summary,
    color: COLORS[notice.kind],
    author: {
      name: notice.actor.login,
      ...(notice.actor.html_url && { url: notice.actor.html_url }),
      ...(notice.actor.avatar_url && { icon_url: notice.actor.avatar_url }),
    },
  };
  if (notice.url) embed.url = notice.url;
  if (notice.context) embed.footer = { text: notice.context };
  return { embeds: [embed], allowed_mentions: { parse: [] } };
}

export function toTelegram(notice: Notice): string {
  const title = `<b>${html(notice.title)}</b>`;
  const byline = [notice.actor.login, notice.context].filter(Boolean);
  return [
    notice.url ? `<a href="${html(notice.url)}">${title}</a>` : title,
    html(notice.summary),
    `<i>${html(byline.join(" · "))}</i>`,
  ].join("\n");
}

function html(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("@", "@⁠");
}

export async function deliver(
  target: Target,
  notice: Notice,
  secrets: { telegramToken?: string | undefined },
  fetcher: typeof fetch = fetch,
): Promise<void> {
  // Both URLs carry a secret; a fetch error is reported without them.
  let response: Response;
  let name: string;
  if ("discord" in target) {
    name = "discord";
    response = await fetcher(target.discord, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(toDiscord(notice)),
    }).catch(() => {
      throw new Error(`${name}: request failed`);
    });
  } else {
    name = `telegram ${target.telegram.chat}`;
    if (!secrets.telegramToken)
      throw new Error(`${name}: TELEGRAM_BOT_TOKEN is not set`);
    response = await fetcher(
      `https://api.telegram.org/bot${secrets.telegramToken}/sendMessage`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: target.telegram.chat,
          ...(target.telegram.topic && {
            message_thread_id: target.telegram.topic,
          }),
          text: toTelegram(notice),
          parse_mode: "HTML",
          link_preview_options: { is_disabled: true },
        }),
      },
    ).catch(() => {
      throw new Error(`${name}: request failed`);
    });
  }
  if (!response.ok) throw new Error(`${name} responded ${response.status}`);
}
