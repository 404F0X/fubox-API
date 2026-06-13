import type { ButtonHTMLAttributes, ReactNode } from "react";

type ActionButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  icon?: ReactNode;
  variant?: "primary" | "secondary" | "table";
};

export function ActionButton({
  children,
  className,
  icon,
  type = "button",
  variant = "secondary",
  ...props
}: ActionButtonProps) {
  const variantClass =
    variant === "primary" ? "primary-button" : variant === "table" ? "table-action" : "secondary-button";

  return (
    <button className={[variantClass, className].filter(Boolean).join(" ")} type={type} {...props}>
      {icon}
      {children}
    </button>
  );
}
