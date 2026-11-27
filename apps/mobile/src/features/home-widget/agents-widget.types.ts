import type { AvatarMood } from "@openbot/brand/bloub-avatar-motion";
import type { AvatarColor, AvatarHue } from "@openbot/contracts/ipc";
import type { AgentsWidgetProps } from "./model/agents-widget-props";

interface AgentsWidgetEntry {
  at: number;
  props: AgentsWidgetProps;
}

export interface AgentsWidgetNative {
  dir: string;
  /** Shows `now`, then `later` at its time, so an app that stops running does not leave "Working" up for hours. */
  publish(now: AgentsWidgetEntry, later: AgentsWidgetEntry): void;
  /** Back to "Open OpenBot", so no agent names stay on the Lock Screen after sign-out. */
  clear(): void;
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

export type AgentsWidgetLoader = () => AgentsWidgetNative | null;
