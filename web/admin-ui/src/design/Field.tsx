import type { ReactNode } from "react";

type FieldProps = {
  children: ReactNode;
  className?: string;
  label: string;
};

export function Field({ children, className, label }: FieldProps) {
  return (
    <label className={["field", className].filter(Boolean).join(" ")}>
      {label}
      {children}
    </label>
  );
}
