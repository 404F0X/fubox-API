import type { ReactNode } from "react";

type EmptyStateProps = {
  action?: ReactNode;
  detail?: ReactNode;
  title: string;
};

export function EmptyState({ action, detail, title }: EmptyStateProps) {
  return (
    <div className="empty-state-v2">
      <strong>{title}</strong>
      {detail ? <span>{detail}</span> : null}
      {action}
    </div>
  );
}
