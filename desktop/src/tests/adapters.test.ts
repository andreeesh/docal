import { beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { AdapterError } from "../adapters/adapter-error";
import { MockDocalAdapter } from "../adapters/mock-docal-adapter";
import { TauriDocalAdapter } from "../adapters/tauri-docal-adapter";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(),
  isTauri: vi.fn(),
}));

describe("MockDocalAdapter", () => {
  it("returns deterministic demo runtime and three fictional sites", async () => {
    const adapter = new MockDocalAdapter();
    const runtime = await adapter.getRuntimeInfo();
    const sites = await adapter.listSites();

    expect(runtime).toEqual({ hostOs: "unknown", backendStatus: "not_connected", dataSource: "mock" });
    expect(sites).toHaveLength(3);
    expect(sites).toEqual([
      { slug: "demo-wordpress", status: "running", url: "https://demo-wordpress.localhost", phpVersion: "8.3", mysqlVersion: "8.4" },
      { slug: "test-shop", status: "stopped", url: "https://test-shop.localhost", phpVersion: "8.2", mysqlVersion: "8.0" },
      { slug: "local-blog", status: "running", url: "https://local-blog.localhost", phpVersion: "8.3", mysqlVersion: "8.4" },
    ]);
    expect(runtime.backendStatus).not.toBe("connected");
  });
});

describe("TauriDocalAdapter", () => {
  beforeEach(() => vi.mocked(invoke).mockReset());

  it("invokes only get_runtime_info and validates the returned structure", async () => {
    vi.mocked(invoke).mockResolvedValue({ hostOs: "linux", backendStatus: "not_connected", dataSource: "native" });
    const adapter = new TauriDocalAdapter();

    await expect(adapter.getRuntimeInfo()).resolves.toEqual({
      hostOs: "linux", backendStatus: "not_connected", dataSource: "native",
    });
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledWith("get_runtime_info");
  });

  it("rejects invalid backend responses with a controlled error", async () => {
    vi.mocked(invoke).mockResolvedValue({ hostOs: "plan9", backendStatus: "connected", dataSource: "native" });
    await expect(new TauriDocalAdapter().getRuntimeInfo()).rejects.toMatchObject({
      name: "AdapterError", code: "INVALID_RESPONSE",
    });
  });

  it("marks listSites as not implemented", async () => {
    await expect(new TauriDocalAdapter().listSites()).rejects.toBeInstanceOf(AdapterError);
    await expect(new TauriDocalAdapter().listSites()).rejects.toMatchObject({ code: "NOT_IMPLEMENTED" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
