import type { RuntimeInfo } from "../domain/runtime";
import type { SiteSummary } from "../domain/site";

export interface DocalAdapter {
  getRuntimeInfo(): Promise<RuntimeInfo>;
  listSites(): Promise<SiteSummary[]>;
}
