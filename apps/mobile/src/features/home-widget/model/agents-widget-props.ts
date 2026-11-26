import type { WatchAgent, WatchSnapshot } from "@openbot/contracts/watch-protocol";
import { LIVE_ACTIVITY_LIST_URL, liveActivityOpenUrl } from "@openbot/team-client/live-activity-props";

type AgentsWidgetState = "waiting" | "working" | "idle";

export interface AgentsWidgetRow {
  key: string;
  name: string;
  state: AgentsWidgetState;
  status: string;
  detail: string;
  avatar: string;
  url: string;
}

/** What the home screen and Lock Screen widget shows. The extension renders it without the app's catalogs. */
export interface AgentsWidgetProps {
  dir: string;
  rows: AgentsWidgetRow[];
  waiting: number;
  working: number;
  summary: string;
  empty: string;
  updated: string;
  stale: boolean;
  listUrl: string;
}

const AGENTS_WIDGET_ROWS = 6;

const ORDER: Record<AgentsWidgetState, number> = { waiting: 0, working: 1, idle: 2 };

export function agentsWidgetProps(
  snapshot: WatchSnapshot,
  avatar: (agent: WatchAgent) => string,
  dir: string,
  updated: string,
): AgentsWidgetProps | null {
  if (snapshot.state !== "ready") return null;
  const text = snapshot.text;
  const agents = snapshot.agents
    .map((agent, index) => ({ agent, index }))
    .sort((a, b) => ORDER[a.agent.state] - ORDER[b.agent.state] || a.index - b.index)
    .slice(0, AGENTS_WIDGET_ROWS)
    .map(({ agent }) => agent);
  const waiting = snapshot.agents.filter((agent) => agent.state === "waiting").length;
  const working = snapshot.agents.filter((agent) => agent.state === "working").length;
  return {
    dir,
    rows: agents.map((agent) => ({
      key: `${agent.serverId}:${agent.id}`,
      name: agent.name,
      state: agent.state,
      status: statusOf(agent, text),
      detail: agent.detail ?? "",
      avatar: avatar(agent),
      url: liveActivityOpenUrl(agent.serverId, agent.id),
    })),
    waiting,
    working,
    summary:
      waiting > 0
        ? (text["mobile.watch.complication.waiting"] ?? "")
        : working > 0
          ? (text["mobile.watch.state.working"] ?? "")
          : (text["mobile.watch.complication.clear"] ?? ""),
    empty: text["mobile.watch.empty"] ?? "",
    updated: (text["mobile.watch.updated"] ?? "").replace("{time}", updated),
    stale: false,
    listUrl: LIVE_ACTIVITY_LIST_URL,
  };
}

function statusOf(agent: WatchAgent, text: Record<string, string>): string {
  if (agent.state === "working") return text["mobile.watch.state.working"] ?? "";
  if (agent.state === "idle") return agent.updated ?? text["mobile.watch.state.idle"] ?? "";
  const wait = agent.wait;
  const reason = wait?.kind === "phone" ? wait.reason : wait?.kind;
  if (reason === "approval") return text["mobile.watch.state.approval"] ?? "";
  if (reason === "takeover") return text["mobile.watch.state.takeover"] ?? "";
  return text["mobile.watch.state.question"] ?? "";
}
