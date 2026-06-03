import { CheckCircle2, CircleDashed } from "./icons";

export type FeaturePanelData = {
  checklist: string[];
  eyebrow: string;
  stats: Array<{
    label: string;
    tone: "good" | "neutral" | "warn";
    value: string;
  }>;
  summary: string;
  title: string;
};

type Props = {
  panel: FeaturePanelData;
};

export function FeaturePanel({ panel }: Props) {
  return (
    <section className="feature-layout" aria-label={`${panel.title} workspace`}>
      <div className="feature-summary">
        <p className="eyebrow">{panel.eyebrow}</p>
        <h2>{panel.title}</h2>
        <p>{panel.summary}</p>
      </div>

      <div className="feature-stats" aria-label={`${panel.title} summary`}>
        {panel.stats.map((item) => (
          <article className={`metric-card metric-card--${item.tone}`} key={item.label}>
            <span>{item.label}</span>
            <strong>{item.value}</strong>
          </article>
        ))}
      </div>

      <div className="feature-checklist" aria-label={`${panel.title} readiness`}>
        {panel.checklist.map((item, index) => {
          const Icon = index === 0 ? CheckCircle2 : CircleDashed;

          return (
            <div className="checklist-row" key={item}>
              <Icon aria-hidden="true" size={18} />
              <span>{item}</span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
