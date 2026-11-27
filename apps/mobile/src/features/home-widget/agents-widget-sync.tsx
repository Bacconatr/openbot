import type { AvatarMood } from "@openbot/brand/bloub-avatar-motion";
import type { WatchAgent } from "@openbot/contracts/watch-protocol";
import type { RemoteWorkspacePreferences } from "@openbot/team-client";
import { type ReactNode, useEffect, useMemo, useRef } from "react";
import { useCSSVariable } from "uniwind";
import { buildWatchSnapshot } from "@/features/watch/model/watch-snapshot";
import { useMobileWorkspaceActions, useMobileWorkspaceSelector } from "@/features/workspace/context/workspace-store";
import { phoneSidebarPins } from "@/features/workspace/model/agent-pins";
import { showsOnline } from "@/features/workspace/model/server-status";
import type { MobileAgent, MobileServer } from "@/features/workspace/model/workspace-types";
import { currentText, type MobileText, useText } from "@/shared/lib/text";
import { agentsWidget } from "./agents-widget";
import type { AgentsWidgetNative, AgentsWidgetPlaceholder } from "./agents-widget.types";
import { agentsWidgetProps } from "./model/agents-widget-props";

interface AgentsWidgetSyncProps {
  servers: readonly MobileServer[];
  serversReady: boolean;
  agents: readonly MobileAgent[];
  preferences: Readonly<Record<string, RemoteWorkspacePreferences>>;
}

const PUBLISH_DELAY_MS = 1000;
const STALE_AFTER_MS = 20 * 60 * 1000;
const REFRESH_CHECK_MS = 60 * 1000;
const MOODS: readonly AvatarMood[] = ["waiting", "working", "idle"];

function placeholderOf({ t }: Pick<MobileText, "t">): AgentsWidgetPlaceholder {
  return { summary: t("mobile.liveActivity.appName"), empty: t("mobile.liveActivity.stale.detail") };
}

export function resetAgentsWidget(): void {
  const placeholder = placeholderOf(currentText());
  agentsWidget(placeholder)?.clear(placeholder);
}

export function AgentsWidgetSync(props: AgentsWidgetSyncProps): ReactNode {
  const { t } = useText();
  const placeholder = useMemo(() => placeholderOf({ t }), [t]);
  const native = useMemo(() => agentsWidget(placeholder), [placeholder]);
  return native ? <AgentsWidgetPublisher {...props} native={native} placeholder={placeholder} /> : null;
}

function AgentsWidgetPublisher({
  servers,
  serversReady,
  agents,
  preferences,
  native,
  placeholder,
}: AgentsWidgetSyncProps & { native: AgentsWidgetNative; placeholder: AgentsWidgetPlaceholder }): null {
  const text = useText();
  const accent = String(useCSSVariable("--openbot-accent"));
  const actions = useMobileWorkspaceActions();
  const liveState = actions.liveState;
  const sidebarByServer = useMobileWorkspaceSelector((current) => current.sidebarByServer);
  const last = useRef({ key: "", at: 0 });
  const drawing = useRef(new Set<string>());
  const failed = useRef(new Set<string>());
  const rerun = useRef<() => void>(() => undefined);

  const placeholderRef = useRef(placeholder);
  placeholderRef.current = placeholder;
  useEffect(() => () => native.clear(placeholderRef.current), [native]);

  useEffect(() => {
    if (!serversReady) return;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let stopped = false;
    const byKey = new Map(agents.map((agent) => [`${agent.serverId}:${agent.id}`, agent]));
    let keep = new Set<string>();
    const avatar = (shown: WatchAgent): string => {
      const agent = byKey.get(`${shown.serverId}:${shown.id}`);
      if (!agent) return "";
      const fileOf = (mood: AvatarMood) =>
        native.avatarFile(agent.avatarSeed, agent.avatarHue, mood, agent.avatarColor);
      for (const mood of MOODS) keep.add(fileOf(mood));
      const mood: AvatarMood = shown.state;
      const file = fileOf(mood);
      if (native.hasAvatar(file)) return file;
      if (!drawing.current.has(file) && !failed.current.has(file)) {
        drawing.current.add(file);
        void native
          .drawAvatar(file, agent.avatarSeed, agent.avatarHue, mood, agent.avatarColor)
          .catch(() => false)
          .then((drawn) => {
            drawing.current.delete(file);
            if (drawn) rerun.current();
            else failed.current.add(file);
          });
      }
      return MOODS.map(fileOf).find((other) => native.hasAvatar(other)) ?? "";
    };
    const publish = () => {
      const snapshot = buildWatchSnapshot({
        servers,
        agents,
        hidden: (serverId) => preferences[serverId]?.hidden ?? [],
        hiddenChannels: (serverId) => preferences[serverId]?.hiddenChannels ?? [],
        pins: (serverId) => {
          const current = preferences[serverId];
          return current ? phoneSidebarPins(current) : [];
        },
        layout: (serverId) => sidebarByServer[serverId]?.layout ?? null,
        paused: false,
        live: liveState.get(),
        conversation: (agentId) => actions.conversationStore.get(agentId),
        avatar: () => undefined,
        faces: () => undefined,
        channels: () => [],
        online: showsOnline,
        watchKey: () => undefined,
        account: undefined,
        text,
        accent,
      });
      keep = new Set();
      const now = Date.now();
      const time = new Date(now).toLocaleTimeString(text.locale, { hour: "numeric", minute: "2-digit" });
      const props = agentsWidgetProps(snapshot, avatar, native.dir, time);
      if (!props) return;
      const key = JSON.stringify({ ...props, updated: "" });
      if (key === last.current.key && now - last.current.at < STALE_AFTER_MS / 2) return;
      last.current = { key, at: now };
      native.removeAvatars(keep);
      native.publish({ at: now, props }, { at: now + STALE_AFTER_MS, props: { ...props, stale: true } });
    };
    const schedule = () => {
      if (timer || stopped) return;
      timer = setTimeout(() => {
        timer = null;
        if (!stopped) publish();
      }, PUBLISH_DELAY_MS);
    };
    rerun.current = schedule;
    schedule();
    const unsubscribe = liveState.subscribe(schedule);
    const refresh = setInterval(schedule, REFRESH_CHECK_MS);
    return () => {
      stopped = true;
      unsubscribe();
      clearInterval(refresh);
      if (timer) clearTimeout(timer);
    };
  }, [serversReady, servers, agents, preferences, sidebarByServer, liveState, actions, text, accent, native]);

  return null;
}
