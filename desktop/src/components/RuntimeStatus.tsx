import type { RuntimeInfo } from "../domain/runtime";

interface RuntimeStatusProps {
  runtime: RuntimeInfo;
}

const OS_LABELS = {
  windows: "Windows",
  linux: "Linux",
  macos: "macOS",
  unknown: "No detectado",
} as const;

export function RuntimeStatus({ runtime }: RuntimeStatusProps) {
  const isConnected = runtime.backendStatus === "connected";
  const statusLabel = isConnected
    ? "Conectado"
    : runtime.backendStatus === "error"
      ? "Error de conexión"
      : "No conectado";

  return (
    <section className="panel runtime-panel" aria-labelledby="runtime-heading">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">ENTORNO</p>
          <h2 id="runtime-heading">Runtime</h2>
        </div>
        <span className={`status-pill ${isConnected ? "status-running" : "status-stopped"}`}>
          <span className="status-dot" aria-hidden="true" />{statusLabel}
        </span>
      </div>
      <div className="runtime-details">
        <div className="runtime-detail">
          <span className="detail-label">Sistema operativo</span>
          <span className="detail-value">{OS_LABELS[runtime.hostOs]}</span>
        </div>
        <div className="runtime-detail">
          <span className="detail-label">Motor Docal</span>
          <span className="detail-value">{statusLabel}</span>
        </div>
        <div className="runtime-detail">
          <span className="detail-label">Fuente de datos</span>
          <span className="detail-value">{runtime.dataSource === "mock" ? "Demostración" : "Nativa"}</span>
        </div>
      </div>
    </section>
  );
}
