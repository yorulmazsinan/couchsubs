// SPDX-License-Identifier: AGPL-3.0-only
// RevenueCat REST API v1: GET /v1/subscribers/{app_user_id} (gizli anahtarla). Uygulama RevenueCat'i Firebase UID'siyle
// yapılandırır, böylece aynı kimlikle sorulur. Yanıtta subscriber.entitlements.<id>.expires_date null (ömür boyu) ya da
// gelecekteyse hak etkindir; grace_period_expires_date varsa o da sayılır.

export const ENTITLEMENT = "packs";

interface EntitlementInfo {
  expires_date?: string | null;
  grace_period_expires_date?: string | null;
}

/** Yanıttaki hakkın şu an etkin olup olmadığı (saf işlev; testlerde doğrudan denenir). */
export function isEntitlementActive(body: unknown, entitlement: string, nowMs: number): boolean {
  const entitlements = (body as { subscriber?: { entitlements?: Record<string, EntitlementInfo> } })?.subscriber?.entitlements;
  const info = entitlements?.[entitlement];
  if (!info) return false;
  if (info.expires_date === null || info.expires_date === undefined) return true;
  const until = Math.max(Date.parse(info.expires_date) || 0, Date.parse(info.grace_period_expires_date ?? "") || 0);
  return until > nowMs;
}

export class RevenueCatError extends Error {}

export async function hasEntitlement(
  uid: string,
  secret: string,
  fetcher: typeof fetch = fetch,
  nowMs: number = Date.now(),
): Promise<boolean> {
  const response = await fetcher(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`, {
    headers: { Authorization: `Bearer ${secret}`, Accept: "application/json" },
  });
  if (response.status === 404) return false;
  if (!response.ok) throw new RevenueCatError(`revenuecat_${response.status}`);
  return isEntitlementActive(await response.json(), ENTITLEMENT, nowMs);
}
