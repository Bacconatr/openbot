// Lab-only: fills the Agents widget with sample agents so a simulator with no server shows it.
// Lives only on lab/* branches of the fork; never part of the upstream change.
import { agentsWidget } from "./agents-widget";
import type { AgentsWidgetProps } from "./model/agents-widget-props";

const AGENTS = [
  {
    name: "Engineering lead",
    seed: "lab-eng",
    state: "waiting",
    status: "Approval",
    detail: "Run bun test in apps/mobile?",
  },
  {
    name: "Finance bot",
    seed: "lab-fin",
    state: "working",
    status: "Working",
    detail: "Reconciling November card charges",
  },
  { name: "Researcher", seed: "lab-res", state: "working", status: "Working", detail: "Comparing three widget kits" },
  {
    name: "Personal assistant",
    seed: "lab-pa",
    state: "idle",
    status: "2h ago",
    detail: "Booked the dentist for Tuesday",
  },
  { name: "Homelab", seed: "lab-home", state: "idle", status: "Yesterday", detail: "Backups verified, all green" },
] as const;

export async function publishWidgetLabFixture(): Promise<void> {
  if (process.env.EXPO_PUBLIC_WIDGET_LAB !== "1") return;
  const native = agentsWidget();
  if (!native) return;
  const rows = [];
  for (const agent of AGENTS) {
    const file = native.avatarFile(agent.seed, null, agent.state, null);
    if (!native.hasAvatar(file)) await native.drawAvatar(file, agent.seed, null, agent.state, null).catch(() => false);
    rows.push({
      key: `lab:${agent.seed}`,
      name: agent.name,
      state: agent.state,
      status: agent.status,
      detail: agent.detail,
      avatar: native.hasAvatar(file) ? file : "",
      url: `openbot://live-activity?server=lab&agent=${agent.seed}`,
    });
  }
  const props: AgentsWidgetProps = {
    dir: native.dir,
    rows,
    waiting: 1,
    working: 2,
    summary: "1 waiting",
    empty: "No agents yet.",
    updated: "Updated 9:41",
    stale: false,
    listUrl: "openbot://live-activity?list=1",
  };
  const now = Date.now();
  native.publish({ at: now, props }, { at: now + 20 * 60 * 1000, props: { ...props, stale: true } });
}
