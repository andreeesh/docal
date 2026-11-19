import { isTauri } from "@tauri-apps/api/core";
import type { DocalAdapter } from "./docal-adapter";
import { MockDocalAdapter } from "./mock-docal-adapter";
import { TauriDocalAdapter } from "./tauri-docal-adapter";
import { UnavailableDocalAdapter } from "./unavailable-docal-adapter";

export function createDocalAdapter(): DocalAdapter {
  if (import.meta.env.MODE === "mock") {
    return new MockDocalAdapter();
  }

  if (isTauri()) {
    return new TauriDocalAdapter();
  }

  return new UnavailableDocalAdapter();
}
