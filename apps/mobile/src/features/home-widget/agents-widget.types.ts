import type { AvatarMood } from "@openbot/brand/bloub-avatar-motion";
import type { AvatarColor, AvatarHue } from "@openbot/contracts/ipc";
import type { AgentsWidgetProps } from "./model/agents-widget-props";

export type AgentsWidgetPlaceholder = Pick<AgentsWidgetProps, "summary" | "empty">;

interface AgentsWidgetEntry {
  at: number;
  props: AgentsWidgetProps;
}

export interface AgentsWidgetNative {
  dir: string;
  publish(now: AgentsWidgetEntry, later: AgentsWidgetEntry): void;
  clear(placeholder: AgentsWidgetPlaceholder): void;
  avatarFile(seed: string, hue: AvatarHue | null, mood: AvatarMood, color: AvatarColor | null): string;
  hasAvatar(file: string): boolean;
  drawAvatar(
    file: string,
    seed: string,
    hue: AvatarHue | null,
    mood: AvatarMood,
    color: AvatarColor | null,
  ): Promise<boolean>;
  removeAvatars(keep: ReadonlySet<string>): void;
}

export type AgentsWidgetLoader = (placeholder: AgentsWidgetPlaceholder) => AgentsWidgetNative | null;
