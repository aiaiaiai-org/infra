// © 2026 aiaiaiai · aiaiaiai.org

import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { describe, it } from "node:test";
import {
  buildMessage,
  githubProjectLookup,
  type ProjectItemLookup,
  routeFor,
  verifySignature,
} from "./relay.ts";

const sender = { login: "0x0sky", html_url: "https://github.com/0x0sky" };
const options = { statusField: "Status" };
const hook = "https://discord.com/api/webhooks/1/abc";

function issues(action: string, extra: Record<string, unknown> = {}) {
  return {
    action,
    issue: {
      number: 42,
      title: "Map pins @everyone",
      html_url: "https://github.com/nilx-one/web/issues/42",
      assignees: [{ login: "kai" }],
    },
    repository: { full_name: "nilx-one/web" },
    organization: { login: "nilx-one" },
    sender,
    ...extra,
  };
}

function statusChange(
  from: string | null,
  to: string | null,
  fieldType = "single_select",
) {
  return {
    action: "edited",
    projects_v2_item: { content_node_id: "I_1", project_node_id: "PVT_1" },
    changes: {
      field_value: {
        field_node_id: "PVTSSF_1",
        field_type: fieldType,
        from: from && { name: from },
        to: to && { name: to },
      },
    },
    organization: { login: "nilx-one" },
    sender,
  };
}

const item = {
  title: "Map pins",
  url: "https://github.com/nilx-one/web/issues/42",
  reference: "nilx-one/web#42",
  projectTitle: "0x1 roadmap",
  fieldName: "Status",
};
const lookup: ProjectItemLookup = async () => ({ ...item });

describe("routeFor", () => {
  const routes = JSON.stringify({
    "nilx-one": { discord: hook, token: "t0ken" },
    "0xda-market": { discord: hook },
    evil: { discord: "https://example.com/steal" },
  });

  it("picks the organization's channel and token, case-insensitively", () => {
    assert.deepEqual(routeFor(routes, issues("opened")), {
      discord: hook,
      token: "t0ken",
    });
    assert.deepEqual(
      routeFor(routes, { organization: { login: "0xDA-Market" } }),
      { discord: hook },
    );
  });

  it("drops unknown organizations, non-Discord targets and bad config", () => {
    assert.equal(routeFor(routes, { organization: { login: "other" } }), null);
    assert.equal(routeFor(routes, { organization: { login: "evil" } }), null);
    assert.equal(routeFor(routes, {}), null);
    assert.equal(routeFor("not json", issues("opened")), null);
  });
});

describe("verifySignature", () => {
  const body = '{"zen":"ok"}';
  const good = `sha256=${createHmac("sha256", "s3cret").update(body).digest("hex")}`;

  it("accepts the GitHub HMAC and rejects anything else", async () => {
    assert.equal(await verifySignature("s3cret", body, good), true);
    assert.equal(await verifySignature("other", body, good), false);
    assert.equal(await verifySignature("s3cret", `${body} `, good), false);
    assert.equal(await verifySignature("s3cret", body, null), false);
    assert.equal(await verifySignature("", body, good), false);
  });
});

describe("issue events", () => {
  it("announces a new task with its assignees and blocks mentions", async () => {
    const message = await buildMessage("issues", issues("opened"), options);
    assert.deepEqual(message?.allowed_mentions, { parse: [] });
    assert.deepEqual(message?.embeds[0], {
      title: "nilx-one/web#42 Map pins @everyone",
      url: "https://github.com/nilx-one/web/issues/42",
      description: "New task, assigned to @kai",
      color: 0x3fb950,
      author: { name: "0x0sky", url: "https://github.com/0x0sky" },
    });
  });

  it("reports assignment changes and closing reason", async () => {
    const assigned = await buildMessage(
      "issues",
      issues("assigned", { assignee: { login: "dasha" } }),
      options,
    );
    assert.equal(assigned?.embeds[0]?.description, "Assigned to @dasha");

    const closed = await buildMessage(
      "issues",
      issues("closed", {
        issue: { ...issues("x").issue, state_reason: "not_planned" },
      }),
      options,
    );
    assert.equal(closed?.embeds[0]?.description, "Closed as not planned");
  });

  it("stays quiet on unrelated actions, events and private repositories", async () => {
    assert.equal(
      await buildMessage("issues", issues("labeled"), options),
      null,
    );
    assert.equal(await buildMessage("push", {}, options), null);
    const secret = issues("opened", {
      repository: { full_name: "nilx-one/secret", private: true },
    });
    assert.equal(await buildMessage("issues", secret, options), null);
  });
});

describe("project status changes", () => {
  it("shows the move between status columns", async () => {
    const message = await buildMessage(
      "projects_v2_item",
      statusChange("Todo", "In Progress"),
      { ...options, lookup },
    );
    assert.deepEqual(message?.embeds[0], {
      title: "nilx-one/web#42 Map pins",
      url: "https://github.com/nilx-one/web/issues/42",
      description: "Status: Todo → In Progress",
      color: 0xf0883e,
      author: { name: "0x0sky", url: "https://github.com/0x0sky" },
      footer: { text: "0x1 roadmap" },
    });
  });

  it("ignores other fields, no-op edits and private repositories", async () => {
    const cases: [ReturnType<typeof statusChange>, ProjectItemLookup][] = [
      [statusChange("P1", "P0"), async () => ({ ...item, fieldName: "Prio" })],
      [statusChange("Todo", "Todo"), lookup],
      [statusChange(null, null, "text"), lookup],
      [statusChange("Todo", "Done"), async () => ({ ...item, private: true })],
    ];
    for (const [payload, look] of cases) {
      assert.equal(
        await buildMessage("projects_v2_item", payload, {
          ...options,
          lookup: look,
        }),
        null,
      );
    }
  });
});

describe("githubProjectLookup", () => {
  it("resolves issue, project and field names over GraphQL", async () => {
    let seen: RequestInit | undefined;
    const fetcher = (async (_url: string, init: RequestInit) => {
      seen = init;
      return new Response(
        JSON.stringify({
          data: {
            content: {
              title: "Map pins",
              url: "https://github.com/nilx-one/web/issues/42",
              number: 42,
              repository: { nameWithOwner: "nilx-one/web", isPrivate: false },
            },
            project: { title: "0x1 roadmap", url: "https://github.com/p/1" },
            field: { name: "Status" },
          },
        }),
      );
    }) as typeof fetch;
    const found = await githubProjectLookup(
      "t0ken",
      fetcher,
    )({
      content: "I_1",
      project: "PVT_1",
      field: "PVTSSF_1",
    });
    assert.deepEqual(found, item);
    assert.equal(
      (seen?.headers as Record<string, string>).authorization,
      "Bearer t0ken",
    );
  });
});
