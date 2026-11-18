import type { DocalAdapter } from "./docal-adapter";
import type { RuntimeInfo } from "../domain/runtime";
import type { SiteSummary } from "../domain/site";
import { AdapterError } from "./adapter-error";

export class UnavailableDocalAdapter implements DocalAdapter {
  async getRuntimeInfo(): Promise<RuntimeInfo> {
    return {
      hostOs: "unknown",
      backendStatus: "not_connected",
      dataSource: "native",
    };
  }

  async listSites(): Promise<SiteSummary[]> {
    throw new AdapterError("BACKEND_UNAVAILABLE", "El backend nativo de Docal no está disponible.");
  }
}
