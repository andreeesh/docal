export type HostOs = "windows" | "linux" | "macos" | "unknown";

export type BackendStatus = "connected" | "not_connected" | "error";

export type DataSource = "native" | "mock";

export interface RuntimeInfo {
  hostOs: HostOs;
  backendStatus: BackendStatus;
  dataSource: DataSource;
}
