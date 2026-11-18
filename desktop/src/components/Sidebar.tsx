import type { DataSource } from "../domain/runtime";

export type AppView = "dashboard" | "sites";

interface SidebarProps {
  dataSource: DataSource;
  view: AppView;
  onViewChange: (view: AppView) => void;
}

const NAV_ITEMS: { id: AppView; label: string; icon: string }[] = [
  { id: "dashboard", label: "Dashboard", icon: "▦" },
  { id: "sites", label: "Sitios", icon: "◫" },
];

export function Sidebar({ dataSource, view, onViewChange }: SidebarProps) {
  return (
    <aside className="sidebar" aria-label="Navegación principal">
      <div className="brand-lockup">
        <div className="brand-mark" aria-hidden="true">D</div>
        <div>
          <div className="brand-name">docal</div>
          <div className="brand-caption">DESKTOP</div>
        </div>
      </div>

      <div className="nav-group-label">ESPACIO DE TRABAJO</div>
      <nav className="primary-nav" aria-label="Secciones">
        {NAV_ITEMS.map((item) => (
          <button
            className={`nav-item${view === item.id ? " is-active" : ""}`}
            key={item.id}
            type="button"
            aria-current={view === item.id ? "page" : undefined}
            onClick={() => onViewChange(item.id)}
          >
            <span className="nav-icon" aria-hidden="true">{item.icon}</span>
            {item.label}
          </button>
        ))}
      </nav>

      <div className="sidebar-footer">
        <span className="source-label">Fuente de datos</span>
        <span className={`source-pill source-${dataSource}`}>
          <span className="source-dot" aria-hidden="true" />
          {dataSource === "mock" ? "Demo" : "Nativa"}
        </span>
      </div>
    </aside>
  );
}
