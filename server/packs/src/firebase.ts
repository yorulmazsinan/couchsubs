// SPDX-License-Identifier: AGPL-3.0-only
// Firebase ID token doğrulaması (Firebase Admin SDK olmadan, Workers'ın WebCrypto'suyla).
// Kurallar: https://firebase.google.com/docs/auth/admin/verify-id-tokens#verify_id_tokens_using_a_third-party_jwt_library
// RS256, "kid" Google'ın securetoken anahtarlarından biri, aud = proje kimliği, iss = https://securetoken.google.com/<proje>,
// exp gelecekte, iat ve auth_time geçmişte, sub boş değil.

/** Google'ın securetoken anahtarları JWK biçiminde (x509 adresindekilerle aynı anahtarlar). */
export const JWKS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

/** Saat kayması payı (saniye). */
const LEEWAY = 60;

export interface FirebaseUser {
  uid: string;
  email?: string;
}

export class TokenError extends Error {}

interface Jwk extends JsonWebKey {
  kid: string;
}

let cachedKeys: { keys: Map<string, CryptoKey>; until: number } | null = null;

/** Testler için önbelleği boşaltır. */
export function resetKeyCache(): void {
  cachedKeys = null;
}

function base64UrlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeJson(part: string): Record<string, unknown> {
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlDecode(part)));
  } catch {
    throw new TokenError("malformed");
  }
}

/** Anahtarlar Cache-Control max-age süresince bellekte tutulur. */
async function signingKeys(fetcher: typeof fetch, now: number): Promise<Map<string, CryptoKey>> {
  if (cachedKeys && cachedKeys.until > now) return cachedKeys.keys;
  const response = await fetcher(JWKS_URL);
  if (!response.ok) throw new TokenError("keys_unavailable");
  const body = (await response.json()) as { keys?: Jwk[] };
  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys ?? []) {
    if (!jwk.kid) continue;
    keys.set(
      jwk.kid,
      await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]),
    );
  }
  const maxAge = /max-age=(\d+)/.exec(response.headers.get("cache-control") ?? "")?.[1];
  cachedKeys = { keys, until: now + (maxAge ? Number(maxAge) : 3600) };
  return keys;
}

/** Geçerli bir Firebase ID token'ının kullanıcısı; geçersizse TokenError. */
export async function verifyIdToken(
  token: string,
  projectId: string,
  fetcher: typeof fetch = fetch,
  now: number = Math.floor(Date.now() / 1000),
): Promise<FirebaseUser> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new TokenError("malformed");
  const header = decodeJson(parts[0]);
  const payload = decodeJson(parts[1]);
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new TokenError("bad_header");

  const key = (await signingKeys(fetcher, now)).get(header.kid);
  if (!key) throw new TokenError("unknown_key");
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64UrlDecode(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!valid) throw new TokenError("bad_signature");

  const exp = Number(payload.exp);
  const iat = Number(payload.iat);
  const authTime = Number(payload.auth_time);
  if (payload.aud !== projectId) throw new TokenError("bad_audience");
  if (payload.iss !== `https://securetoken.google.com/${projectId}`) throw new TokenError("bad_issuer");
  if (!(exp > now - LEEWAY)) throw new TokenError("expired");
  if (!(iat <= now + LEEWAY) || !(authTime <= now + LEEWAY)) throw new TokenError("not_yet_valid");
  if (typeof payload.sub !== "string" || payload.sub.length === 0 || payload.sub.length > 128) throw new TokenError("bad_subject");
  return { uid: payload.sub, email: typeof payload.email === "string" ? payload.email : undefined };
}
