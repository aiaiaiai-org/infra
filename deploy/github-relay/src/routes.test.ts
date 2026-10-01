// © 2026 aiaiaiai · aiaiaiai.org

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseRoutes, resolveRoute } from "./routes.ts";

const discord = "https://discord.com/api/webhooks/123/abc-DEF_1";
const table = parseRoutes(
  JSON.stringify({
    "nilx-one": { token: "org-token", to: [{ discord }] },
    "nilx-one/Web": {
      token: "repo-token",
      to: [{ discord }, { telegram: { chat: -1001234567890, topic: 7 } }],
    },
    "0x0sky/notes": { to: [{ telegram: { chat: "@nilx_tasks" } }] },
  }),
);

describe("resolveRoute", () => {
  it("merges owner and repository destinations without duplicates", () => {
    assert.deepEqual(
      resolveRoute(table, {
        organization: { login: "nilx-one" },
        repository: { full_name: "nilx-one/web" },
      }),
      {
        targets: [
          { discord },
          { telegram: { chat: "-1001234567890", topic: 7 } },
        ],
        token: "repo-token",
      },
    );
  });

  it("routes the rest of an organization, and project events, by owner", () => {
    const expected = { targets: [{ discord }], token: "org-token" };
    assert.deepEqual(
      resolveRoute(table, {
        organization: { login: "NILX-ONE" },
        repository: { full_name: "nilx-one/core" },
      }),
      expected,
    );
    assert.deepEqual(
      resolveRoute(table, { organization: { login: "nilx-one" } }),
      expected,
    );
  });

  it("routes a single repository outside any organization", () => {
    assert.deepEqual(
      resolveRoute(table, {
        repository: { full_name: "0x0sky/notes", owner: { login: "0x0sky" } },
      }),
      { targets: [{ telegram: { chat: "@nilx_tasks" } }] },
    );
  });

  it("drops sources nobody routed", () => {
    assert.equal(
      resolveRoute(table, { organization: { login: "elsewhere" } }),
      null,
    );
    assert.equal(resolveRoute(table, {}), null);
    assert.equal(resolveRoute(table, null), null);
  });
});

describe("parseRoutes", () => {
  it("rejects anything it would not know how to deliver", () => {
    const bad: [unknown, RegExp][] = [
      ["not json", /not valid JSON/],
      [{}, /non-empty object/],
      [{ "a/b/c": { to: [{ discord }] } }, /owner\/repo/],
      [{ org: { to: [] } }, /at least one destination/],
      [{ org: { to: [{ discord: "https://example.com/x" }] } }, /webhook URL/],
      [{ org: { to: [{ telegram: { chat: "chat" } }] } }, /chat ID/],
      [{ org: { to: [{ telegram: { chat: 1, topic: 0 } }] } }, /topic/],
      [{ org: { to: [{ slack: "x" }] } }, /expected/],
      [{ org: { token: "", to: [{ discord }] } }, /token/],
    ];
    for (const [input, message] of bad) {
      const json = typeof input === "string" ? input : JSON.stringify(input);
      assert.throws(() => parseRoutes(json), message);
    }
  });
});
