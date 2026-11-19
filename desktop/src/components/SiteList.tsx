import type { SiteSummary } from "../domain/site";

interface SiteListProps {
  sites: SiteSummary[];
}

const STATUS_LABELS = {
  running: "Running",
  stopped: "Stopped",
  unknown: "Unknown",
} as const;

export function SiteList({ sites }: SiteListProps) {
  return (
    <div className="site-list" role="list" aria-label="Sitios WordPress">
      {sites.map((site) => (
        <article className="site-row" role="listitem" key={site.slug}>
          <div className="site-identity">
            <div className="site-avatar" aria-hidden="true">{site.slug.charAt(0).toUpperCase()}</div>
            <div className="site-name-block">
              <h3>{site.slug}</h3>
              <span className="site-url">{site.url}</span>
            </div>
          </div>
          <div className="site-meta">
            <span className={`status-pill status-${site.status}`}>
              <span className="status-dot" aria-hidden="true" />{STATUS_LABELS[site.status]}
            </span>
            <div className="version-item"><span>PHP</span><strong>{site.phpVersion ?? "No disponible"}</strong></div>
            <div className="version-item"><span>MySQL</span><strong>{site.mysqlVersion ?? "No disponible"}</strong></div>
          </div>
        </article>
      ))}
    </div>
  );
}
