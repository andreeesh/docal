export type SiteStatus = "running" | "stopped" | "unknown";

export interface SiteSummary {
  slug: string;
  status: SiteStatus;
  url: string;
  phpVersion: string | null;
  mysqlVersion: string | null;
}
