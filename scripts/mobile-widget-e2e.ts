import { execFile } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { isDynamicRecord } from "@openbot/contracts/runtime-values";
import { createOpenBotLogger } from "@openbot/logging";
import { bootedSimulatorIds } from "./dev-mobile";

const BUNDLE_ID = "run.openbot.mobile";
const APP_GROUP = "group.run.openbot.mobile";
const TIMELINE_KEY = "__expo_widgets_OpenBotAgents_timeline";
const OUT = resolve(import.meta.dirname, "../.openbot-build/mobile-widget-e2e");
const STALE_AFTER_MS = 20 * 60_000;
const STALE_TOLERANCE_MS = 5_000;
const MAX_ROWS = 6;
const PUBLISH_TIMEOUT_MS = 2 * 60_000;
const POLL_INTERVAL_MS = 500;
const STATE_ORDER = { waiting: 0, working: 1, idle: 2 } as const;
const OPEN_LINK = /^openbot:\/\/live-activity\?server=[^&]+&agent=[^&]+$/u;

const logger = createOpenBotLogger("mobile-widget-e2e");
const run = promisify(execFile);

type RowState = keyof typeof STATE_ORDER;

interface WidgetRow {
  key: string;
  name: string;
  state: RowState;
  status: string;
  detail: string;
  avatar: string;
  url: string;
}

interface WidgetProps {
  dir: string;
  rows: WidgetRow[];
  waiting: number;
  working: number;
  summary: string;
  empty: string;
  updated: string;
  stale: boolean;
  listUrl: string;
}

interface TimelineEntry {
  timestamp: number;
  props: WidgetProps;
}

interface Check {
  name: string;
  passed: boolean;
  detail: string;
}

function option(name: string): string | null {
  const prefix = `--${name}=`;
  return process.argv.find((arg) => arg.startsWith(prefix))?.slice(prefix.length) || null;
}

async function waitFor<T>(label: string, timeoutMs: number, probe: () => Promise<T | null>): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value !== null) return value;
    await new Promise((done) => setTimeout(done, POLL_INTERVAL_MS));
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

async function selectSimulator(): Promise<string> {
  const requested = option("simulator");
  if (requested) return requested;
  const { stdout } = await run("xcrun", ["simctl", "list", "devices", "booted", "--json"]);
  const withApp: string[] = [];
  for (const udid of bootedSimulatorIds(JSON.parse(stdout))) {
    try {
      await run("xcrun", ["simctl", "get_app_container", udid, BUNDLE_ID]);
      withApp.push(udid);
    } catch {}
  }
  const [udid, ...extra] = withApp;
  if (!udid) throw new Error("No booted simulator has OpenBot installed. Run `bun run dev:mobile` first.");
  if (extra.length > 0) throw new Error("Several booted simulators have OpenBot. Pass --simulator=<udid>.");
  return udid;
}

function isTimeline(value: unknown): value is TimelineEntry[] {
  return (
    Array.isArray(value) &&
    value.every(
      (entry) =>
        isDynamicRecord(entry) &&
        typeof entry.timestamp === "number" &&
        isDynamicRecord(entry.props) &&
        Array.isArray(entry.props.rows),
    )
  );
}

function timelineOf(value: unknown): TimelineEntry[] | null {
  return isTimeline(value) ? value : null;
}

async function readTimeline(preferences: string): Promise<TimelineEntry[] | null> {
  if (!existsSync(preferences)) return null;
  try {
    const { stdout } = await run("plutil", ["-extract", TIMELINE_KEY, "json", "-o", "-", preferences]);
    return timelineOf(JSON.parse(stdout));
  } catch {
    return null;
  }
}

function check(name: string, passed: boolean, detail: string): Check {
  return { name, passed, detail };
}

function timelineChecks(entries: TimelineEntry[], minRows: number): Check[] {
  const [now, later] = entries;
  if (!now || !later) return [check("two timeline entries", false, `found ${entries.length}`)];
  const rows = now.props.rows;
  const gap = later.timestamp - now.timestamp;
  const order = rows.map((row) => STATE_ORDER[row.state]);
  const countOf = (state: RowState) => rows.filter((row) => row.state === state).length;
  const missingAvatars = rows.filter((row) => row.avatar && !existsSync(join(now.props.dir, row.avatar)));
  const badLinks = rows.filter((row) => !OPEN_LINK.test(row.url));
  return [
    check("two timeline entries", entries.length === 2, `found ${entries.length}`),
    check("the second entry is 20 minutes later", Math.abs(gap - STALE_AFTER_MS) <= STALE_TOLERANCE_MS, `${gap} ms`),
    check(
      "only the second entry is stale",
      now.props.stale === false && later.props.stale === true,
      `${now.props.stale}, ${later.props.stale}`,
    ),
    check(
      "the stale entry keeps the same rows",
      JSON.stringify(later.props.rows) === JSON.stringify(rows),
      `${later.props.rows.length} rows`,
    ),
    check(
      `between ${minRows} and ${MAX_ROWS} rows`,
      rows.length >= minRows && rows.length <= MAX_ROWS,
      `${rows.length} rows`,
    ),
    check(
      "waiting agents first, then working, then idle",
      order.every((value, index) => index === 0 || (order[index - 1] ?? 0) <= value),
      rows.map((row) => row.state).join(", "),
    ),
    check(
      "the counts cover the rows",
      now.props.waiting >= countOf("waiting") && now.props.working >= countOf("working"),
      `waiting ${now.props.waiting}, working ${now.props.working}`,
    ),
    check("a summary is set", now.props.summary.length > 0, now.props.summary),
    check("every row opens its agent", badLinks.length === 0, badLinks.map((row) => row.url).join(", ") || "all"),
    check(
      "every agent picture exists",
      missingAvatars.length === 0,
      missingAvatars.map((row) => row.avatar).join(", ") || "all",
    ),
  ];
}

async function main(): Promise<void> {
  const minRows = Number(option("min-rows") ?? 1);
  const udid = await selectSimulator();
  const group = (await run("xcrun", ["simctl", "get_app_container", udid, BUNDLE_ID, APP_GROUP])).stdout.trim();
  const preferences = join(group, "Library", "Preferences", `${APP_GROUP}.plist`);
  mkdirSync(OUT, { recursive: true });

  const launchedAt = Date.now();
  await run("xcrun", ["simctl", "terminate", udid, BUNDLE_ID]).catch(() => undefined);
  await run("xcrun", ["simctl", "launch", udid, BUNDLE_ID]);
  logger.info("Launched OpenBot. Waiting for it to publish the Agents widget.");
  const entries = await waitFor(
    "the app to publish the Agents widget (is the app signed in with at least one agent?)",
    PUBLISH_TIMEOUT_MS,
    async () => {
      const timeline = await readTimeline(preferences);
      return timeline && (timeline[0]?.timestamp ?? 0) >= launchedAt - STALE_TOLERANCE_MS ? timeline : null;
    },
  );

  const screenshot = join(OUT, "app.png");
  await run("xcrun", ["simctl", "io", udid, "screenshot", screenshot]);
  const checks = timelineChecks(entries, minRows);
  writeFileSync(
    join(OUT, "report.json"),
    `${JSON.stringify({ simulator: udid, checks, timeline: entries, screenshot }, null, 2)}\n`,
  );
  const failed = checks.filter((item) => !item.passed);
  for (const item of checks) logger.info(`${item.passed ? "pass" : "FAIL"}  ${item.name}: ${item.detail}`);
  if (failed.length > 0) throw new Error(`${failed.length} of ${checks.length} widget checks failed.`);
  logger.info(`Passed ${checks.length} widget checks. Wrote ${join(OUT, "report.json")}.`);
}

main().catch((error: unknown) => {
  logger.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
