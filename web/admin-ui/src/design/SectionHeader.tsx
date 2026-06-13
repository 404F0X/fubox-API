import type { ReactNode } from "react";

type SectionHeaderProps = {
  actions?: ReactNode;
  description?: ReactNode;
  title: string;
};

export function SectionHeader({ actions, description, title }: SectionHeaderProps) {
  return (
    <div className="section-heading">
      <div>
        <h2>{title}</h2>
        {description ? <p>{description}</p> : null}
      </div>
      {actions}
    </div>
  );
}
