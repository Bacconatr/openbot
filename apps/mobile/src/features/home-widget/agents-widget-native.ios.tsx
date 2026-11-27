import { HStack, Image, Link, Spacer, Text, VStack, ZStack } from "@expo/ui/swift-ui";
import {
  accessibilityElement,
  clipShape,
  containerBackground,
  font,
  foregroundStyle,
  frame,
  layoutPriority,
  lineLimit,
  privacySensitive,
  resizable,
  widgetAccentedRenderingMode,
  widgetURL,
} from "@expo/ui/swift-ui/modifiers";
import type { AvatarMood } from "@openbot/brand/bloub-avatar-motion";
import type { AvatarColor, AvatarHue } from "@openbot/contracts/ipc";
import { Directory, File } from "expo-file-system";
import { createWidget, type WidgetEnvironment, widgetsDirectory } from "expo-widgets";
import { renderPlushPicture } from "@/features/agents/model/plush/plush-picture";
import type { AgentsWidgetNative, AgentsWidgetPlaceholder } from "./agents-widget.types";
import type { AgentsWidgetProps, AgentsWidgetRow } from "./model/agents-widget-props";

const AGENTS_WIDGET_NAME = "OpenBotAgents";
const AVATAR_PREFIX = "agents-widget-";
const AVATAR_PIXELS = 96;

function agentsWidgetLayout(published: Partial<AgentsWidgetProps> | undefined, environment: WidgetEnvironment) {
  "widget";
  const props = published ?? {};
  const family = environment.widgetFamily;
  const circular = family === "accessoryCircular";
  const inline = family === "accessoryInline";
  const rectangular = family === "accessoryRectangular";
  const accessory = circular || inline || rectangular;
  const small = family === "systemSmall";
  const large = family === "systemLarge" || family === "systemExtraLarge";
  const light = environment.colorScheme === "light";
  const mono =
    environment.widgetRenderingMode === "accented" ||
    environment.widgetRenderingMode === "vibrant" ||
    environment.isLuminanceReduced === true;
  const primary = { type: "hierarchical", style: "primary" } as const;
  const secondary = { type: "hierarchical", style: "secondary" } as const;
  const stale = props.stale === true;
  const tint = (state: AgentsWidgetRow["state"]) => {
    if (mono || (stale && state !== "idle")) return state === "idle" ? secondary : primary;
    if (state === "waiting") return light ? "#C93400" : "#FF9F0A";
    if (state === "working") return light ? "#0A6CDB" : "#64B5FF";
    return secondary;
  };
  const rows = props.rows ?? [];
  const loaded = props.rows !== undefined;
  const first = rows[0];
  const summaryState = (props.waiting ?? 0) > 0 ? "waiting" : (props.working ?? 0) > 0 ? "working" : "idle";
  const summary = loaded && stale ? (props.updated ?? "") : (props.summary ?? "");
  const empty = props.empty ?? "";
  const tapUrl = first && first.state === "waiting" ? first.url : (props.listUrl ?? "openbot://live-activity?list=1");
  const status = (row: AgentsWidgetRow) => (stale && row.state !== "idle" ? (props.updated ?? "") : row.status);

  const avatar = (row: AgentsWidgetRow, size: number) =>
    row.avatar ? (
      <Image
        uiImage={(props.dir ?? "") + row.avatar}
        modifiers={[resizable(), widgetAccentedRenderingMode("desaturated"), frame({ width: size, height: size })]}
      />
    ) : (
      <Image
        systemName="person.crop.circle.fill"
        size={size * 0.9}
        modifiers={[frame({ width: size, height: size }), foregroundStyle(secondary), clipShape("circle")]}
      />
    );

  if (inline) {
    return <Text modifiers={[lineLimit(1), widgetURL(tapUrl)]}>{summary}</Text>;
  }

  if (circular) {
    const count = summaryState === "waiting" ? (props.waiting ?? 0) : (props.working ?? 0);
    return (
      <ZStack modifiers={[containerBackground("clear", "widget"), widgetURL(tapUrl)]}>
        <VStack spacing={1}>
          <Image
            systemName={
              summaryState === "waiting" ? "hand.raised.fill" : summaryState === "working" ? "sparkles" : "checkmark"
            }
            size={13}
          />
          <Text modifiers={[font({ size: 18, weight: "bold" }), lineLimit(1)]}>{String(count)}</Text>
        </VStack>
      </ZStack>
    );
  }

  const header = (
    <HStack spacing={6}>
      <Text
        modifiers={[
          font({ size: accessory ? 13 : 12, weight: "semibold" }),
          foregroundStyle(accessory || !loaded ? primary : tint(summaryState)),
          lineLimit(1),
        ]}
      >
        {summary}
      </Text>
      <Spacer minLength={0} />
      {!accessory && !small && loaded && !stale ? (
        <Text modifiers={[font({ size: 11 }), foregroundStyle(secondary), lineLimit(1)]}>{props.updated ?? ""}</Text>
      ) : null}
    </HStack>
  );

  const lockRow = (row: AgentsWidgetRow) => (
    <HStack key={row.key} spacing={6} modifiers={[accessibilityElement("combine")]}>
      <Text modifiers={[font({ size: 13, weight: "semibold" }), lineLimit(1)]}>{row.name}</Text>
      <Spacer minLength={4} />
      <Text modifiers={[font({ size: 12 }), foregroundStyle(secondary), lineLimit(1), layoutPriority(1)]}>
        {status(row)}
      </Text>
    </HStack>
  );

  const compactRow = (row: AgentsWidgetRow) => (
    <HStack key={row.key} spacing={7} modifiers={[accessibilityElement("combine")]}>
      {avatar(row, 22)}
      <VStack alignment="leading" spacing={0}>
        <Text modifiers={[font({ size: 13, weight: "semibold" }), foregroundStyle(primary), lineLimit(1)]}>
          {row.name}
        </Text>
        <Text modifiers={[font({ size: 11, weight: "medium" }), foregroundStyle(tint(row.state)), lineLimit(1)]}>
          {status(row)}
        </Text>
      </VStack>
      <Spacer minLength={0} />
    </HStack>
  );

  const fullRow = (row: AgentsWidgetRow) => (
    <Link key={row.key} destination={row.url}>
      <HStack spacing={10} modifiers={[accessibilityElement("combine")]}>
        {avatar(row, large ? 32 : 28)}
        <VStack alignment="leading" spacing={1}>
          <Text modifiers={[font({ size: 14, weight: "semibold" }), foregroundStyle(primary), lineLimit(1)]}>
            {row.name}
          </Text>
          {row.detail ? (
            <Text modifiers={[font({ size: 12 }), foregroundStyle(secondary), lineLimit(1), privacySensitive()]}>
              {row.detail}
            </Text>
          ) : null}
        </VStack>
        <Spacer minLength={6} />
        <Text
          modifiers={[
            font({ size: 12, weight: "semibold" }),
            foregroundStyle(tint(row.state)),
            lineLimit(1),
            layoutPriority(1),
          ]}
        >
          {status(row)}
        </Text>
      </HStack>
    </Link>
  );

  const shown = rows.slice(0, rectangular ? 2 : small ? 3 : large ? 6 : 3);
  const background = accessory ? "clear" : light ? "#FFFFFF" : "#1C1C1E";
  return (
    <VStack
      alignment="leading"
      spacing={accessory ? 2 : small ? 7 : 8}
      modifiers={[containerBackground(background, "widget"), widgetURL(tapUrl)]}
    >
      {header}
      {shown.length > 0 ? (
        <VStack alignment="leading" spacing={accessory ? 1 : small ? 6 : large ? 10 : 7}>
          {shown.map((row) => (rectangular ? lockRow(row) : small ? compactRow(row) : fullRow(row)))}
        </VStack>
      ) : (
        <Text modifiers={[font({ size: 12 }), foregroundStyle(secondary), lineLimit(3)]}>{empty}</Text>
      )}
      {accessory ? null : <Spacer minLength={0} />}
    </VStack>
  );
}

function removeAvatars(dir: string, keep: ReadonlySet<string>): void {
  if (!widgetsDirectory) return;
  for (const entry of new Directory(dir).list()) {
    if (entry instanceof File && entry.name.startsWith(AVATAR_PREFIX) && !keep.has(entry.name)) entry.delete();
  }
}

export function agentsWidgetNative(placeholder: AgentsWidgetPlaceholder): AgentsWidgetNative {
  const dir = widgetsDirectory ?? "";
  const widget = createWidget<Partial<AgentsWidgetProps>>(AGENTS_WIDGET_NAME, agentsWidgetLayout, placeholder);
  return {
    dir,
    clear(next) {
      removeAvatars(dir, new Set());
      widget.updateTimeline([{ date: new Date(), props: next }]);
    },
    publish(now, later) {
      widget.updateTimeline([
        { date: new Date(now.at), props: now.props },
        { date: new Date(later.at), props: later.props },
      ]);
    },
    avatarFile(seed: string, hue: AvatarHue | null, mood: AvatarMood, color: AvatarColor | null) {
      return `${AVATAR_PREFIX}${[seed, hue ?? "", mood, color ?? ""].join("-").replace(/[^A-Za-z0-9-]/gu, "_")}.png`;
    },
    hasAvatar: (name) => Boolean(widgetsDirectory) && new File(dir, name).exists,
    async drawAvatar(name, seed, hue, mood, color) {
      if (!widgetsDirectory) return false;
      const data = await renderPlushPicture({ seed, hue, color, mood, pixels: AVATAR_PIXELS, saturation: 1 });
      new File(dir, name).writeSync(data, { encoding: "base64" });
      return true;
    },
    removeAvatars: (keep) => removeAvatars(dir, keep),
  };
}
