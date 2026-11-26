// Lab-only: fills the Agents widget with sample agents so a simulator with no server shows it.
// Lives only on lab/* branches of the fork; never part of the upstream change.
//
// The lab's shell steers it through files in the app's Documents folder:
// - it writes `widget-lab-scene.txt` = `live` before a launch to film the widget re-sorting:
//   the app publishes scene "before" now and scene "after" LIVE_DELAY_MS later, as one timeline.
// - the app appends every link it is opened with to `widget-lab-links.txt`, and writes
//   `widget-lab-published.txt` when it has published, so the shell can wait for it.
import type { WatchAgent, WatchSnapshot } from "@openbot/contracts/watch-protocol";
import { File, Paths } from "expo-file-system";
import { Linking } from "react-native";
import { agentsWidget } from "./agents-widget";
import { agentsWidgetProps } from "./model/agents-widget-props";

const LIVE_DELAY_MS = 20_000;

const TEXT = {
  "mobile.watch.complication.clear": "All clear",
  "mobile.watch.state.working": "Working",
  "mobile.watch.state.idle": "Idle",
  "mobile.watch.state.approval": "Approval",
  "mobile.watch.state.takeover": "Browser",
  "mobile.watch.state.question": "Question",
  "mobile.watch.empty": "No agents yet. Add an agent in OpenBot on iPhone.",
  "mobile.watch.updated": "Updated {time}",
};

type Sample = Pick<WatchAgent, "id" | "name" | "state" | "detail" | "updated" | "wait">;

const approval = { kind: "phone", reason: "approval", text: null } as const;

const SCENES: Record<"still" | "before" | "after", Sample[]> = {
  still: [
    {
      id: "lab-eng",
      name: "Engineering lead",
      state: "waiting",
      wait: approval,
      updated: null,
      detail: "Run bun test in apps/mobile?",
    },
    {
      id: "lab-fin",
      name: "Finance bot",
      state: "working",
      wait: null,
      updated: null,
      detail: "Reconciling November card charges",
    },
    {
      id: "lab-res",
      name: "Researcher",
      state: "working",
      wait: null,
      updated: null,
      detail: "Comparing three widget kits",
    },
    {
      id: "lab-pa",
      name: "Personal assistant",
      state: "idle",
      wait: null,
      updated: "2h ago",
      detail: "Booked the dentist for Tuesday",
    },
    {
      id: "lab-home",
      name: "Homelab",
      state: "idle",
      wait: null,
      updated: "Yesterday",
      detail: "Backups verified, all green",
    },
  ],
  before: [
    {
      id: "lab-fin",
      name: "Finance bot",
      state: "working",
      wait: null,
      updated: null,
      detail: "Reconciling November card charges",
    },
    {
      id: "lab-eng",
      name: "Engineering lead",
      state: "working",
      wait: null,
      updated: null,
      detail: "Running bun test in apps/mobile",
    },
    {
      id: "lab-res",
      name: "Researcher",
      state: "working",
      wait: null,
      updated: null,
      detail: "Comparing three widget kits",
    },
    {
      id: "lab-pa",
      name: "Personal assistant",
      state: "idle",
      wait: null,
      updated: "2h ago",
      detail: "Booked the dentist for Tuesday",
    },
    {
      id: "lab-home",
      name: "Homelab",
      state: "idle",
      wait: null,
      updated: "Yesterday",
      detail: "Backups verified, all green",
    },
  ],
  after: [
    {
      id: "lab-fin",
      name: "Finance bot",
      state: "working",
      wait: null,
      updated: null,
      detail: "Reconciling November card charges",
    },
    {
      id: "lab-eng",
      name: "Engineering lead",
      state: "working",
      wait: null,
      updated: null,
      detail: "Running bun test in apps/mobile",
    },
    {
      id: "lab-res",
      name: "Researcher",
      state: "waiting",
      wait: approval,
      updated: null,
      detail: "Buy the Pro plan of the third kit?",
    },
    {
      id: "lab-pa",
      name: "Personal assistant",
      state: "idle",
      wait: null,
      updated: "2h ago",
      detail: "Booked the dentist for Tuesday",
    },
    {
      id: "lab-home",
      name: "Homelab",
      state: "idle",
      wait: null,
      updated: "Yesterday",
      detail: "Backups verified, all green",
    },
  ],
};

function labFile(name: string): File {
  return new File(Paths.document, name);
}

function writeLabFile(name: string, text: string, append = false): void {
  const file = labFile(name);
  const before = append && file.exists ? file.textSync() : "";
  if (!file.exists) file.create();
  file.writeSync(before + text);
}

function readLabFile(name: string): string {
  const file = labFile(name);
  return file.exists ? file.textSync().trim() : "";
}

function snapshot(samples: Sample[]): WatchSnapshot {
  const waiting = samples.filter((sample) => sample.state === "waiting").length;
  return {
    version: 1,
    state: "ready",
    generatedAt: Date.now(),
    live: true,
    paused: false,
    accent: "#7C5CFF",
    language: "en",
    text: { ...TEXT, "mobile.watch.complication.waiting": `${waiting} waiting` },
    servers: [{ id: "lab", name: "Lab", online: true }],
    agents: samples.map((sample) => ({
      ...sample,
      serverId: "lab",
      server: "Lab",
      color: "#7C5CFF",
      pinned: false,
      unread: 0,
      turnId: null,
      reply: null,
    })),
  };
}

function recordLinks(): void {
  const record = (url: string | null | undefined) => {
    if (url) writeLabFile("widget-lab-links.txt", `${new Date().toISOString()} ${url}\n`, true);
  };
  void Linking.getInitialURL().then(record);
  Linking.addEventListener("url", (event) => record(event.url));
}

export async function publishWidgetLabFixture(): Promise<void> {
  if (process.env.EXPO_PUBLIC_WIDGET_LAB !== "1") return;
  recordLinks();
  const native = agentsWidget();
  if (!native) return;
  const avatars = new Map<string, string>();
  for (const sample of Object.values(SCENES).flat()) {
    const file = native.avatarFile(sample.id, null, sample.state, null);
    if (!native.hasAvatar(file)) await native.drawAvatar(file, sample.id, null, sample.state, null).catch(() => false);
    avatars.set(`${sample.id}:${sample.state}`, native.hasAvatar(file) ? file : "");
  }
  const props = (samples: Sample[]) => {
    const built = agentsWidgetProps(
      snapshot(samples),
      (agent) => avatars.get(`${agent.id}:${agent.state}`) ?? "",
      native.dir,
      "9:41",
    );
    if (!built) throw new Error("the lab snapshot is not ready");
    return built;
  };
  const scene = readLabFile("widget-lab-scene.txt");
  const now = Date.now();
  if (scene === "live") {
    native.publish({ at: now, props: props(SCENES.before) }, { at: now + LIVE_DELAY_MS, props: props(SCENES.after) });
  } else {
    const still = props(SCENES.still);
    native.publish({ at: now, props: still }, { at: now + 20 * 60 * 1000, props: { ...still, stale: true } });
  }
  writeLabFile("widget-lab-published.txt", `${scene || "still"} ${now} ${now + LIVE_DELAY_MS}\n`);
}
