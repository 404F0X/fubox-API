type MetricTileProps = {
  detail?: string;
  label: string;
  tone?: "default" | "good" | "neutral" | "warn";
  value: string;
};

export function MetricTile({ detail, label, tone = "default", value }: MetricTileProps) {
  return (
    <article className={["metric-card", tone === "default" ? "" : `metric-card--${tone}`].filter(Boolean).join(" ")}>
      <span>{label}</span>
      <strong>{value}</strong>
      {detail ? <small>{detail}</small> : null}
    </article>
  );
}
