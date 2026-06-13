import type { ProbeResult } from "../api/client";

type Props = {
  status: ProbeResult["status"];
};

export function StatusPill({ status }: Props) {
  return (
    <span className={`status-pill status-pill--${status}`}>
      {statusLabel(status)}
    </span>
  );
}

function statusLabel(status: ProbeResult["status"]): string {
  return {
    offline: "离线",
    online: "在线",
    pending: "等待中",
  }[status];
}
