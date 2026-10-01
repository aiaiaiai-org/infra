// © 2026 aiaiaiai · aiaiaiai.org

// Point A: GitHub webhook deliveries, verified and reduced to a Notice that
// any destination can render. Covers new issues, assignee changes,
// close/reopen, and GitHub Projects status moves.

export type NoticeKind =
  "opened" | "assigned" | "unassigned" | "closed" | "reopened" | "status";

export interface Actor {
  login: string;
  html_url?: string;
  avatar_url?: string;
}

export interface Notice {
  kind: NoticeKind;
  title: string;
  url?: string;
  summary: string;
  actor: Actor;
  context?: string;
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

const TITLE_LIMIT = 256;

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

export async function buildNotice(
  event: string,
  payload: unknown,
  options: { statusField: string; lookup?: ProjectItemLookup },
): Promise<Notice | null> {
  if (event === "issues") return issueNotice(payload as IssuesPayload);
  if (event === "projects_v2_item") {
    return projectStatusNotice(payload as ProjectItemPayload, options);
  }
  return null;
}

function issueNotice(payload: IssuesPayload): Notice | null {
  const { issue, repository } = payload;
  if (repository.private) return null;
  const who = payload.assignee ? `@${payload.assignee.login}` : "";
  let summary: string;
  switch (payload.action) {
    case "opened": {
      const assignees = (issue.assignees ?? []).map((a) => `@${a.login}`);
      summary = assignees.length
        ? `New task, assigned to ${assignees.join(", ")}`
        : "New task, unassigned";
      break;
    }
    case "assigned":
      summary = `Assigned to ${who}`;
      break;
    case "unassigned":
      summary = `Unassigned ${who}`;
      break;
    case "closed":
      summary =
        issue.state_reason === "not_planned"
          ? "Closed as not planned"
          : "Closed as completed";
      break;
    case "reopened":
      summary = "Reopened";
      break;
    default:
      return null;
  }
  return {
    kind: payload.action as NoticeKind,
    title: clip(`${repository.full_name}#${issue.number} ${issue.title}`),
    url: issue.html_url,
    summary,
    actor: payload.sender,
  };
}

async function projectStatusNotice(
  payload: ProjectItemPayload,
  options: { statusField: string; lookup?: ProjectItemLookup },
): Promise<Notice | null> {
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
  const notice: Notice = {
    kind: "status",
    title: clip(
      item
        ? [item.reference, item.title].filter(Boolean).join(" ")
        : "Project item",
    ),
    summary: `Status: ${from} → ${to}`,
    actor: payload.sender,
  };
  if (item?.url) notice.url = item.url;
  if (item?.projectTitle) notice.context = item.projectTitle;
  return notice;
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
        "user-agent": "aiaiaiai-github-relay",
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

function clip(text: string): string {
  return text.length > TITLE_LIMIT
    ? `${text.slice(0, TITLE_LIMIT - 1)}…`
    : text;
}
