import { useEffect, useState } from "react";
import type { RuntimeInfo } from "./domain/runtime";
import type { SiteSummary } from "./domain/site";
import type { DocalAdapter } from "./adapters/docal-adapter";
import { AdapterError } from "./adapters/adapter-error";
import { createDocalAdapter } from "./adapters/create-adapter";
import { AppLayout } from "./components/AppLayout";
import { EmptyState } from "./components/EmptyState";
import { RuntimeStatus } from "./components/RuntimeStatus";
import { SiteList } from "./components/SiteList";
import type { AppView } from "./components/Sidebar";

type SiteLoadState =
  | { kind: "loading" }
  | { kind: "available"; sites: SiteSummary[] }
  | { kind: "unavailable"; message: string }
  | { kind: "unsupported"; message: string }
  | { kind: "error"; message: string };

interface AppProps {
  adapter?: DocalAdapter;
}

const DEFAULT_ADAPTER = createDocalAdapter();

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Ocurrió un error inesperado.";
}

function App({ adapter = DEFAULT_ADAPTER }: AppProps) {
  const [view, setView] = useState<AppView>("dashboard");
  const [runtime, setRuntime] = useState<RuntimeInfo | null>(null);
  const [runtimeError, setRuntimeError] = useState<string | null>(null);
  const [siteState, setSiteState] = useState<SiteLoadState>({ kind: "loading" });

  useEffect(() => {
    let active = true;

    async function loadData() {
      const runtimeResult = adapter.getRuntimeInfo();
      const sitesResult = adapter.listSites();

      const [runtimeResponse, sitesResponse] = await Promise.allSettled([runtimeResult, sitesResult]);
      if (!active) return;

      if (runtimeResponse.status === "fulfilled") {
        setRuntime(runtimeResponse.value);
        setRuntimeError(null);
      } else {
        setRuntime(null);
        setRuntimeError(getErrorMessage(runtimeResponse.reason));
      }

      if (sitesResponse.status === "fulfilled") {
        setSiteState({ kind: "available", sites: sitesResponse.value });
        return;
      }

      const error = sitesResponse.reason;
      if (error instanceof AdapterError && error.code === "BACKEND_UNAVAILABLE") {
        setSiteState({ kind: "unavailable", message: error.message });
      } else if (error instanceof AdapterError && error.code === "NOT_IMPLEMENTED") {
        setSiteState({ kind: "unsupported", message: error.message });
      } else {
        setSiteState({ kind: "error", message: getErrorMessage(error) });
      }
    }

    void loadData().catch((error: unknown) => {
      if (active) {
        setRuntimeError(getErrorMessage(error));
        setSiteState({ kind: "error", message: getErrorMessage(error) });
      }
    });

    return () => {
      active = false;
    };
  }, [adapter]);

  const dataSource = runtime?.dataSource ?? "native";
  const sites = siteState.kind === "available" ? siteState.sites : null;
  const runningCount = sites?.filter((site) => site.status === "running").length;
  const stoppedCount = sites?.filter((site) => site.status === "stopped").length;

  return (
    <AppLayout dataSource={dataSource} view={view} onViewChange={setView}>
      <header className="page-header">
        <div>
          <p className="eyebrow">TU ESPACIO LOCAL</p>
          <h1>{view === "dashboard" ? "Dashboard" : "Sitios"}</h1>
          <p className="page-subtitle">
            {view === "dashboard" ? "Una vista clara de tu entorno de desarrollo." : "Tus proyectos WordPress locales."}
          </p>
        </div>
        {runtime?.dataSource === "mock" && (
          <div className="demo-banner" role="status">
            <span aria-hidden="true">✦</span> Modo demostración · Datos ficticios
          </div>
        )}
      </header>

      {view === "dashboard" && (
        <div className="dashboard-grid">
          <RuntimeStatus
            runtime={runtime ?? { hostOs: "unknown", backendStatus: "not_connected", dataSource }}
          />
          <section className="panel sites-panel" aria-labelledby="sites-heading">
            <div className="panel-heading sites-panel-heading">
              <div>
                <p className="eyebrow">WORDPRESS</p>
                <h2 id="sites-heading">Sitios</h2>
              </div>
              {sites !== null && <span className="site-count">{sites.length} en total</span>}
            </div>
            {siteState.kind === "loading" && <div className="loading-state" role="status">Cargando información…</div>}
            {siteState.kind === "available" && siteState.sites.length === 0 && (
              <EmptyState title="Todavía no hay sitios" description="Cuando haya sitios disponibles, aparecerán aquí." />
            )}
            {siteState.kind === "available" && siteState.sites.length > 0 && (
              <>
                <div className="site-summary" aria-label="Resumen de sitios">
                  <div><strong>{runningCount}</strong><span>Running</span></div>
                  <div><strong>{stoppedCount}</strong><span>Stopped</span></div>
                </div>
                <SiteList sites={siteState.sites} />
              </>
            )}
            {siteState.kind === "unavailable" && (
              <EmptyState kind="unavailable" title="Backend no disponible" description={siteState.message} />
            )}
            {siteState.kind === "unsupported" && (
              <EmptyState kind="unsupported" title="Consulta aún no implementada" description={siteState.message} />
            )}
            {siteState.kind === "error" && (
              <EmptyState kind="error" title="No se pudieron cargar los sitios" description={siteState.message} />
            )}
            {runtimeError !== null && <p className="inline-error" role="alert">Runtime: {runtimeError}</p>}
          </section>
        </div>
      )}

      {view === "sites" && (
        <section className="panel sites-page-panel" aria-labelledby="all-sites-heading">
          <div className="panel-heading">
            <div><p className="eyebrow">WORDPRESS</p><h2 id="all-sites-heading">Todos los sitios</h2></div>
          </div>
          {siteState.kind === "loading" && <div className="loading-state" role="status">Cargando información…</div>}
          {siteState.kind === "available" && siteState.sites.length === 0 && (
            <EmptyState title="Todavía no hay sitios" description="Cuando haya sitios disponibles, aparecerán aquí." />
          )}
          {siteState.kind === "available" && siteState.sites.length > 0 && <SiteList sites={siteState.sites} />}
          {siteState.kind === "unavailable" && <EmptyState kind="unavailable" title="Backend no disponible" description={siteState.message} />}
          {siteState.kind === "unsupported" && <EmptyState kind="unsupported" title="Consulta aún no implementada" description={siteState.message} />}
          {siteState.kind === "error" && <EmptyState kind="error" title="No se pudieron cargar los sitios" description={siteState.message} />}
        </section>
      )}
      <footer className="app-footer">Docal Desktop <span>·</span> Fundamentos de escritorio</footer>
    </AppLayout>
  );
}

export default App;
