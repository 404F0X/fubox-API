import type { ReactNode } from "react";

type StatusTone = "good" | "neutral" | "warn" | "danger";

type StatusChipProps = {
  children: ReactNode;
  tone?: StatusTone;
};

export function StatusChip({ children, tone = "neutral" }: StatusChipProps) {
  return <span className={`status-chip-v2 status-chip-v2--${tone}`}>{children}</span>;
}

export function ProbeStatusChip({ status }: { status: "online" | "offline" | "pending" | string }) {
  return <StatusChip tone={probeStatusTone(status)}>{probeStatusLabel(status)}</StatusChip>;
}

function probeStatusTone(status: string): StatusTone {
  if (status === "online") {
    return "good";
  }
  if (status === "offline") {
    return "danger";
  }
  return "warn";
}

function probeStatusLabel(status: string): string {
  const labels: Record<string, string> = {
    offline: "离线",
    online: "在线",
    pending: "等待中",
  };

  return labels[status] ?? status;
}
