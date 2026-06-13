import { safeDisplayText } from "./safeText";

export function formatMoney(
  amount: string | number | null | undefined,
  currency: string | null | undefined,
): string {
  const safeAmount = safeDisplayText(amount);
  const safeCurrency = safeDisplayText(currency);

  if (safeAmount === "-" && safeCurrency === "-") {
    return "-";
  }

  if (safeCurrency === "-") {
    return safeAmount;
  }

  return `${safeAmount} ${safeCurrency}`;
}

export function formatTokenUsage(inputTokens: number | null | undefined, outputTokens: number | null | undefined): string {
  return `输入 ${formatCount(inputTokens)} / 输出 ${formatCount(outputTokens)}`;
}

export function formatTokenCount(value: number | null | undefined): string {
  return formatCount(value);
}

export function formatCount(value: number | null | undefined): string {
  return typeof value === "number" && Number.isFinite(value) ? value.toLocaleString() : "-";
}

export function formatMilliseconds(value: number | null | undefined): string {
  return typeof value === "number" && Number.isFinite(value) ? `${value.toLocaleString()} ms` : "-";
}

export function formatDateTime(value: string | null | undefined): string {
  const safeValue = safeDisplayText(value);

  if (safeValue === "-") {
    return safeValue;
  }

  const date = new Date(safeValue);

  if (Number.isNaN(date.getTime())) {
    return safeValue;
  }

  return date.toLocaleString([], {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
  });
}

export function formatErrorParts(...parts: Array<unknown>): string {
  const safeParts = parts
    .map((part) => safeDisplayText(part))
    .filter((part) => part !== "-");

  return safeParts.length > 0 ? safeParts.join(" / ") : "-";
}

export function formatList(values: unknown[]): string {
  const safeValues = values.map((value) => safeDisplayText(value)).filter((value) => value !== "-");

  return safeValues.length > 0 ? safeValues.join(", ") : "-";
}
