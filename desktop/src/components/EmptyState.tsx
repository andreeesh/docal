interface EmptyStateProps {
  title: string;
  description: string;
  kind?: "empty" | "unavailable" | "unsupported" | "error";
}

export function EmptyState({ title, description, kind = "empty" }: EmptyStateProps) {
  return (
    <div className={`empty-state empty-${kind}`} role={kind === "error" || kind === "unavailable" ? "alert" : "status"}>
      <div className="empty-icon" aria-hidden="true">
        {kind === "empty" ? "◫" : kind === "unsupported" ? "…" : "!"}
      </div>
      <h3>{title}</h3>
      <p>{description}</p>
    </div>
  );
}
