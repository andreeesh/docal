import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import App from "../App";
import type { DocalAdapter } from "../adapters/docal-adapter";
import { AdapterError } from "../adapters/adapter-error";
import { MockDocalAdapter } from "../adapters/mock-docal-adapter";

function createAdapter(overrides: Partial<DocalAdapter> = {}): DocalAdapter {
  const base = new MockDocalAdapter();
  return {
    getRuntimeInfo: overrides.getRuntimeInfo ?? (() => base.getRuntimeInfo()),
    listSites: overrides.listSites ?? (() => base.listSites()),
  };
}

describe("App", () => {
  it("renders the three demo sites and a clear demo indicator", async () => {
    render(<App adapter={new MockDocalAdapter()} />);
    expect(await screen.findByText("demo-wordpress")).toBeInTheDocument();
    expect(screen.getByText("test-shop")).toBeInTheDocument();
    expect(screen.getByText("local-blog")).toBeInTheDocument();
    expect(screen.getByText(/Modo demostración · Datos ficticios/)).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
    expect(screen.getByText("3 en total")).toBeInTheDocument();
  });

  it("shows loading while requests are pending", () => {
    const adapter = createAdapter({
      getRuntimeInfo: () => new Promise(() => undefined),
      listSites: () => new Promise(() => undefined),
    });
    render(<App adapter={adapter} />);
    expect(screen.getByText("Cargando información…")).toBeInTheDocument();
  });

  it("shows backend unavailable instead of an empty list", async () => {
    const adapter = createAdapter({
      listSites: async () => { throw new AdapterError("BACKEND_UNAVAILABLE", "Sin backend"); },
    });
    render(<App adapter={adapter} />);
    expect(await screen.findByText("Backend no disponible")).toBeInTheDocument();
    expect(screen.queryByText("0 en total")).not.toBeInTheDocument();
  });

  it("shows an explicit not implemented state", async () => {
    const adapter = createAdapter({
      listSites: async () => { throw new AdapterError("NOT_IMPLEMENTED", "Consulta pendiente"); },
    });
    render(<App adapter={adapter} />);
    expect(await screen.findByText("Consulta aún no implementada")).toBeInTheDocument();
    expect(screen.getByText("Consulta pendiente")).toBeInTheDocument();
  });

  it("renders a legitimate empty result and coherent zero counts", async () => {
    const adapter = createAdapter({ listSites: async () => [] });
    render(<App adapter={adapter} />);
    expect(await screen.findByText("Todavía no hay sitios")).toBeInTheDocument();
    expect(screen.getByText("0 en total")).toBeInTheDocument();
  });

  it("handles unexpected rejections without an unhandled promise", async () => {
    const adapter = createAdapter({ listSites: async () => { throw new Error("fallo de prueba"); } });
    await act(async () => {
      render(<App adapter={adapter} />);
    });
    expect(await screen.findByText("No se pudieron cargar los sitios")).toBeInTheDocument();
    expect(screen.getByText("fallo de prueba")).toBeInTheDocument();
  });
});
