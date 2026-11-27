import { requireOptionalNativeModule } from "expo";
import type { AgentsWidgetLoader, AgentsWidgetNative } from "./agents-widget.types";

let native: AgentsWidgetNative | undefined;

export const agentsWidget: AgentsWidgetLoader = () => {
  if (native) return native;
  if (!requireOptionalNativeModule("ExpoWidgets")) return null;
  const module: typeof import("./agents-widget-native.ios") = require("./agents-widget-native.ios");
  native = module.agentsWidgetNative();
  return native;
};
