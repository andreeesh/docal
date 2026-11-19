import { afterEach, describe, expect, it, vi } from "vitest";
import { isTauri } from "@tauri-apps/api/core";
import { MockDocalAdapter } from "../adapters/mock-docal-adapter";
import { TauriDocalAdapter } from "../adapters/tauri-docal-adapter";
import { UnavailableDocalAdapter } from "../adapters/unavailable-docal-adapter";
import { createDocalAdapter } from "../adapters/create-adapter";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(), isTauri: vi.fn() }));

describe("createDocalAdapter", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("selects the mock adapter in mock mode", () => {
    vi.stubEnv("MODE", "mock");
    vi.mocked(isTauri).mockReturnValue(false);
    expect(createDocalAdapter()).toBeInstanceOf(MockDocalAdapter);
  });

  it("selects Tauri when the native runtime is available", () => {
    vi.stubEnv("MODE", "production");
    vi.mocked(isTauri).mockReturnValue(true);
    expect(createDocalAdapter()).toBeInstanceOf(TauriDocalAdapter);
  });

  it("selects unavailable in a normal browser", () => {
    vi.stubEnv("MODE", "production");
    vi.mocked(isTauri).mockReturnValue(false);
    expect(createDocalAdapter()).toBeInstanceOf(UnavailableDocalAdapter);
  });
});
