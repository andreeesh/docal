import type { DocalAdapter } from "./docal-adapter";
import type { RuntimeInfo } from "../domain/runtime";
import type { SiteSummary } from "../domain/site";

const DEMO_SITES: readonly SiteSummary[] = [
  {
    slug: "demo-wordpress",
    status: "running",
    url: "https://demo-wordpress.localhost",
    phpVersion: "8.3",
    mysqlVersion: "8.4",
  },
  {
    slug: "test-shop",
    status: "stopped",
    url: "https://test-shop.localhost",
    phpVersion: "8.2",
    mysqlVersion: "8.0",
  },
  {
    slug: "local-blog",
    status: "running",
    url: "https://local-blog.localhost",
    phpVersion: "8.3",
    mysqlVersion: "8.4",
  },
];

const DEMO_RUNTIME: RuntimeInfo = {
  hostOs: "unknown",
  backendStatus: "not_connected",
  dataSource: "mock",
};

export class MockDocalAdapter implements DocalAdapter {
  async getRuntimeInfo(): Promise<RuntimeInfo> {
    return { ...DEMO_RUNTIME };
  }

  async listSites(): Promise<SiteSummary[]> {
    return DEMO_SITES.map((site) => ({ ...site }));
  }
}
