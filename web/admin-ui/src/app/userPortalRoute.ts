export type UserPortalRouteTarget = "user" | "portal" | "developer-console";

export const USER_PORTAL_ROUTE_QUERY_KEY = "mode";

export const USER_PORTAL_ROUTE_TARGETS: readonly UserPortalRouteTarget[] = [
  "user",
  "portal",
  "developer-console",
];

const userPortalPathTargets = new Set<string>(USER_PORTAL_ROUTE_TARGETS);
const userPortalQueryTargets = new Set<string>(USER_PORTAL_ROUTE_TARGETS);

export type UserPortalRouteLocation = Pick<Location, "hash" | "pathname" | "search">;

export function resolveUserPortalRouteTarget(
  location: UserPortalRouteLocation = window.location,
): UserPortalRouteTarget | null {
  const queryTarget = targetFromSearch(location.search);
  if (queryTarget) {
    return queryTarget;
  }

  const hashTarget = targetFromHash(location.hash);
  if (hashTarget) {
    return hashTarget;
  }

  return targetFromPath(location.pathname);
}

export function isUserPortalStandaloneRoute(
  location: UserPortalRouteLocation = window.location,
): boolean {
  return resolveUserPortalRouteTarget(location) !== null;
}

export function replaceUserPortalRouteTarget(target: UserPortalRouteTarget | null): void {
  const url = new URL(window.location.href);

  if (target) {
    url.searchParams.set(USER_PORTAL_ROUTE_QUERY_KEY, target);
  } else {
    url.searchParams.delete(USER_PORTAL_ROUTE_QUERY_KEY);
  }

  window.history.replaceState(window.history.state, "", url);
}

function targetFromSearch(search: string): UserPortalRouteTarget | null {
  const params = new URLSearchParams(search);
  const mode = params.get(USER_PORTAL_ROUTE_QUERY_KEY) ?? params.get("app") ?? params.get("console");
  return normalizeTarget(mode);
}

function targetFromHash(hash: string): UserPortalRouteTarget | null {
  const normalized = hash.replace(/^#\/?/, "").split(/[/?&]/, 1)[0]?.trim().toLowerCase();
  return normalizeTarget(normalized);
}

function targetFromPath(pathname: string): UserPortalRouteTarget | null {
  const normalized = pathname
    .split("/")
    .filter(Boolean)
    .at(-1)
    ?.trim()
    .toLowerCase();

  if (!normalized || !isUserPortalRouteTarget(normalized, userPortalPathTargets)) {
    return null;
  }

  return normalized;
}

function normalizeTarget(value: string | null | undefined): UserPortalRouteTarget | null {
  const normalized = value?.trim().toLowerCase();

  if (!normalized || !isUserPortalRouteTarget(normalized, userPortalQueryTargets)) {
    return null;
  }

  return normalized;
}

function isUserPortalRouteTarget(
  value: string,
  targets: ReadonlySet<string>,
): value is UserPortalRouteTarget {
  return targets.has(value);
}
