// © 2026 aiaiaiai · aiaiaiai.org

// Turns GitHub organization webhook deliveries into Discord task messages:
// new issues, assignee changes, close/reopen, and GitHub Projects status moves.

export interface DiscordEmbed {
  title: string;
  url?: string;
  description: string;
  color: number;
  author?: { name: string; url?: string; icon_url?: string };
  footer?: { text: string };
}

export interface DiscordMessage {
  embeds: DiscordEmbed[];
  // Issue titles are user-written; never let them ping @everyone or roles.
  allowed_mentions: { parse: [] };
}

export interface ProjectItem {
  title: string;
  url?: string;
  reference?: string;
  projectTitle?: string;
  fieldName?: string;
  private?: boolean;
}

export type ProjectItemLookup = (ids: {
  content: string;
  project: string;
  field: string;
}) => Promise<ProjectItem | null>;

interface Actor {
  login: string;
  html_url?: string;
  avatar_url?: string;
}

interface IssuesPayload {
  action: string;
  issue: {
    number: number;
    title: string;
    html_url: string;
    state_reason?: string | null;
    assignees?: Actor[];
  };
  assignee?: Actor | null;
  repository: { full_name: string; private?: boolean };
  sender: Actor;
}

interface ProjectItemPayload {
  action: string;
  projects_v2_item: {
    content_node_id: string;
    project_node_id: string;
  };
  changes?: {
    field_value?: {
      field_node_id: string;
      field_type: string;
      field_name?: string;
      from?: { name?: string } | null;
      to?: { name?: string } | null;
    };
  };
  sender: Actor;
}

const COLORS = {
  opened: 0x3fb950,
  assigned: 0x58a6ff,
  unassigned: 0x8b949e,
  closed: 0xa371f7,
  reopened: 0xd29922,
  status: 0xf0883e,
} as const;

const TITLE_LIMIT = 256;

export interface Route {
  discord: string;
  token?: string;
}

// `routes` is the RELAY_ROUTES secret: organization login → Discord webhook
// URL and an optional read-only GitHub token for that organization, e.g.
// {"nilx-one": {"discord": "https://discord.com/api/webhooks/…", "token": "github_pat_…"}}.
export function routeFor(routes: string, payload: unknown): Route | null {
  const org = (payload as { organization?: { login?: string } } | null)
    ?.organization?.login;
  if (!org) return null;
  let table: unknown;
  try {
    table = JSON.parse(routes);
  } catch {
    return null;
  }
  if (!table || typeof table !== "object") return null;
  const entry = Object.entries(table).find(
    ([login]) => login.toLowerCase() === org.toLowerCase(),
  )?.[1] as { discord?: unknown; token?: unknown } | undefined;
  if (
    typeof entry?.discord !== "string" ||
    !entry.discord.startsWith("https://discord.com/api/webhooks/")
  ) {
    return null;
  }
  const route: Route = { discord: entry.discord };
  if (typeof entry.token === "string" && entry.token) route.token = entry.token;
  return route;
}

export async function verifySignature(
  secret: string,
  body: string,
  header: string | null,
): Promise<boolean> {
  const { subtle } = crypto;
  if (!secret || !header?.startsWith("sha256=")) return false;
  const encoder = new TextEncoder();
  const key = await subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await subtle.sign("HMAC", key, encoder.encode(body)),
  );
  const expected = `sha256=${[...digest].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
  if (expected.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ header.charCodeAt(i);
  }
  return diff === 0;
}

export async function buildMessage(
  event: string,
  payload: unknown,
  options: { statusField: string; lookup?: ProjectItemLookup },
): Promise<DiscordMessage | null> {
  if (event === "issues") return issueMessage(payload as IssuesPayload);
  if (event === "projects_v2_item") {
    return projectStatusMessage(payload as ProjectItemPayload, options);
  }
  return null;
}

function issueMessage(payload: IssuesPayload): DiscordMessage | null {
  const { issue, repository } = payload;
  if (repository.private) return null;
  const who = payload.assignee ? `@${payload.assignee.login}` : "";
  let description: string;
  let color: number;
  switch (payload.action) {
    case "opened": {
      const assignees = (issue.assignees ?? []).map((a) => `@${a.login}`);
      description = assignees.length
        ? `New task, assigned to ${assignees.join(", ")}`
        : "New task, unassigned";
      color = COLORS.opened;
      break;
    }
    case "assigned":
      description = `Assigned to ${who}`;
      color = COLORS.assigned;
      break;
    case "unassigned":
      description = `Unassigned ${who}`;
      color = COLORS.unassigned;
      break;
    case "closed":
      description =
        issue.state_reason === "not_planned"
          ? "Closed as not planned"
          : "Closed as completed";
      color = COLORS.closed;
      break;
    case "reopened":
      description = "Reopened";
      color = COLORS.reopened;
      break;
    default:
      return null;
  }
  return message({
    title: clip(`${repository.full_name}#${issue.number} ${issue.title}`),
    url: issue.html_url,
    description,
    color,
    author: author(payload.sender),
  });
}

async function projectStatusMessage(
  payload: ProjectItemPayload,
  options: { statusField: string; lookup?: ProjectItemLookup },
): Promise<DiscordMessage | null> {
  const change = payload.changes?.field_value;
  if (payload.action !== "edited" || change?.field_type !== "single_select") {
    return null;
  }
  const item = options.lookup
    ? await options.lookup({
        content: payload.projects_v2_item.content_node_id,
        project: payload.projects_v2_item.project_node_id,
        field: change.field_node_id,
      })
    : null;
  if (item?.private) return null;
  const fieldName = change.field_name ?? item?.fieldName;
  if (fieldName?.toLowerCase() !== options.statusField.toLowerCase()) {
    return null;
  }
  const from = change.from?.name ?? "No status";
  const to = change.to?.name ?? "No status";
  if (from === to) return null;
  const embed: DiscordEmbed = {
    title: clip(
      item
        ? [item.reference, item.title].filter(Boolean).join(" ")
        : "Project item",
    ),
    description: `Status: ${from} → ${to}`,
    color: COLORS.status,
    author: author(payload.sender),
  };
  if (item?.url) embed.url = item.url;
  if (item?.projectTitle) embed.footer = { text: item.projectTitle };
  return message(embed);
}

export function githubProjectLookup(
  token: string,
  fetcher: typeof fetch = fetch,
): ProjectItemLookup {
  const query = `query($content: ID!, $project: ID!, $field: ID!) {
    content: node(id: $content) {
      ... on Issue { title url number repository { nameWithOwner isPrivate } }
      ... on PullRequest { title url number repository { nameWithOwner isPrivate } }
      ... on DraftIssue { title }
    }
    project: node(id: $project) { ... on ProjectV2 { title url } }
    field: node(id: $field) { ... on ProjectV2FieldCommon { name } }
  }`;
  return async (variables) => {
    const response = await fetcher("https://api.github.com/graphql", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "user-agent": "nilxone-github-discord-relay",
      },
      body: JSON.stringify({ query, variables }),
    });
    if (!response.ok) return null;
    const { data } = (await response.json()) as {
      data?: {
        content?: {
          title?: string;
          url?: string;
          number?: number;
          repository?: { nameWithOwner: string; isPrivate?: boolean };
        } | null;
        project?: { title?: string; url?: string } | null;
        field?: { name?: string } | null;
      };
    };
    const content = data?.content;
    const title = content?.title;
    if (!content || !title) return null;
    const project = data?.project;
    const field = data?.field;
    const item: ProjectItem = { title };
    const url = content.url ?? project?.url;
    if (url) item.url = url;
    if (content.repository && content.number !== undefined) {
      item.reference = `${content.repository.nameWithOwner}#${content.number}`;
    }
    if (content.repository?.isPrivate) item.private = true;
    if (project?.title) item.projectTitle = project.title;
    if (field?.name) item.fieldName = field.name;
    return item;
  };
}

function message(embed: DiscordEmbed): DiscordMessage {
  return { embeds: [embed], allowed_mentions: { parse: [] } };
}

function author(actor: Actor): NonNullable<DiscordEmbed["author"]> {
  const result: NonNullable<DiscordEmbed["author"]> = { name: actor.login };
  if (actor.html_url) result.url = actor.html_url;
  if (actor.avatar_url) result.icon_url = actor.avatar_url;
  return result;
}

function clip(text: string): string {
  return text.length > TITLE_LIMIT
    ? `${text.slice(0, TITLE_LIMIT - 1)}…`
    : text;
}
