import type { WatchAgent, WatchSnapshot, WatchWait } from "@openbot/contracts/watch-protocol";
import { describe, expect, it } from "vitest";
import { agentsWidgetProps } from "./agents-widget-props";

const text = {
  "mobile.watch.complication.waiting": "waiting",
  "mobile.watch.complication.clear": "All clear",
  "mobile.watch.state.working": "Working",
  "mobile.watch.state.idle": "Idle",
  "mobile.watch.state.approval": "Approval",
  "mobile.watch.state.takeover": "Your turn",
  "mobile.watch.state.question": "Question",
  "mobile.watch.empty": "No agents",
  "mobile.watch.updated": "Updated {time}",
};

function agent(id: string, state: WatchAgent["state"], extra: Partial<WatchAgent> = {}): WatchAgent {
  return {
    serverId: "s1",
    id,
    name: id,
    server: "Home",
    color: "#000",
    pinned: false,
    unread: 0,
    state,
    detail: null,
    updated: null,
    turnId: null,
    reply: null,
    wait: null,
    ...extra,
  };
}

function snapshot(agents: WatchAgent[]): WatchSnapshot {
  return {
    version: 1,
    state: "ready",
    generatedAt: 0,
    live: true,
    paused: false,
    accent: "#000",
    language: "en",
    text,
    servers: [],
    agents,
  };
}

const props = (agents: WatchAgent[]) =>
  agentsWidgetProps(snapshot(agents), (shown) => `pic-${shown.id}`, "/dir", "9:41");

describe("agents widget", () => {
  it("lists agents waiting on the owner first, then working ones, then the rest in sidebar order", () => {
    const shown = props([
      agent("pinned", "idle"),
      agent("builder", "working"),
      agent("asks", "waiting", { wait: { kind: "phone", reason: "approval", text: null } }),
      agent("recent", "idle"),
      agent("tester", "working"),
    ]);
    expect(shown?.rows.map((row) => row.name)).toEqual(["asks", "builder", "tester", "pinned", "recent"]);
    expect(shown?.waiting).toBe(1);
    expect(shown?.working).toBe(2);
    expect(shown?.summary).toBe("waiting");
  });

  it("shows at most six rows but counts every agent", () => {
    const many = Array.from({ length: 9 }, (_, index) => agent(`a${index}`, "working"));
    const shown = props(many);
    expect(shown?.rows).toHaveLength(6);
    expect(shown?.working).toBe(9);
    expect(shown?.summary).toBe("Working");
  });

  it("names why an agent is waiting", () => {
    const approval: WatchWait = {
      kind: "approval",
      requestId: "r",
      title: "",
      body: "",
      where: null,
      why: null,
      whole: false,
    };
    const shown = props([
      agent("a", "waiting", { wait: approval }),
      agent("b", "waiting", { wait: { kind: "phone", reason: "takeover", text: null } }),
      agent("c", "waiting", { wait: { kind: "question", requestId: "q", questions: [] } }),
      agent("d", "idle", { updated: "2h ago" }),
      agent("e", "idle"),
    ]);
    expect(shown?.rows.map((row) => row.status)).toEqual(["Approval", "Your turn", "Question", "2h ago", "Idle"]);
  });

  it("says all clear when nothing is running, and links each row to its agent's chat", () => {
    const shown = props([agent("quiet", "idle", { detail: "Done" })]);
    expect(shown?.summary).toBe("All clear");
    expect(shown?.updated).toBe("Updated 9:41");
    expect(shown?.stale).toBe(false);
    expect(shown?.rows[0]).toMatchObject({ key: "s1:quiet", detail: "Done", avatar: "pic-quiet" });
    expect(shown?.rows[0]?.url).toContain("agent=quiet");
    expect(shown?.rows[0]?.url).toContain("server=s1");
  });

  it("shows nothing while the app is locked or signed out", () => {
    expect(
      agentsWidgetProps({ version: 1, state: "locked", generatedAt: 0, text }, () => "", "/dir", "9:41"),
    ).toBeNull();
    expect(agentsWidgetProps({ version: 1, state: "signedOut", generatedAt: 0 }, () => "", "/dir", "9:41")).toBeNull();
  });
});
