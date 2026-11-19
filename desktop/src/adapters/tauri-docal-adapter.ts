import { invoke } from "@tauri-apps/api/core";
import type { RuntimeInfo, BackendStatus, DataSource, HostOs } from "../domain/runtime";
import type { SiteSummary } from "../domain/site";
import { AdapterError } from "./adapter-error";
import type { DocalAdapter } from "./docal-adapter";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHostOs(value: unknown): value is HostOs {
  return value === "windows" || value === "linux" || value === "macos" || value === "unknown";
}

function isBackendStatus(value: unknown): value is BackendStatus {
  return value === "connected" || value === "not_connected" || value === "error";
}

function isDataSource(value: unknown): value is DataSource {
  return value === "native" || value === "mock";
}

function parseRuntimeInfo(value: unknown): RuntimeInfo {
  if (
    !isRecord(value) ||
    !isHostOs(value.hostOs) ||
    !isBackendStatus(value.backendStatus) ||
    !isDataSource(value.dataSource)
  ) {
    throw new AdapterError("INVALID_RESPONSE", "El backend devolvió información de runtime inválida.");
  }

  return {
    hostOs: value.hostOs,
    backendStatus: value.backendStatus,
    dataSource: value.dataSource,
  };
}

export class TauriDocalAdapter implements DocalAdapter {
  async getRuntimeInfo(): Promise<RuntimeInfo> {
    const result: unknown = await invoke<unknown>("get_runtime_info");
    return parseRuntimeInfo(result);
  }

  async listSites(): Promise<SiteSummary[]> {
    throw new AdapterError("NOT_IMPLEMENTED", "La consulta de sitios todavía no está implementada.");
  }
}
