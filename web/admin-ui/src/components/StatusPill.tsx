import type { ProbeResult } from "../api/client";

type Props = {
  status: ProbeResult["status"];
};

export function StatusPill({ status }: Props) {
  return (
    <span className={`status-pill status-pill--${status}`}>
      {status}
    </span>
  );
}
