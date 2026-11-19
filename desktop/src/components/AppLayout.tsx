import type { ReactNode } from "react";
import type { DataSource } from "../domain/runtime";
import { Sidebar, type AppView } from "./Sidebar";

interface AppLayoutProps {
  children: ReactNode;
  dataSource: DataSource;
  view: AppView;
  onViewChange: (view: AppView) => void;
}

export function AppLayout({ children, dataSource, view, onViewChange }: AppLayoutProps) {
  return (
    <div className="app-shell">
      <Sidebar dataSource={dataSource} view={view} onViewChange={onViewChange} />
      <main className="main-content">{children}</main>
    </div>
  );
}
