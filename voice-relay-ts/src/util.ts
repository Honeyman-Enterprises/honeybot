import { randomBytes, timingSafeEqual } from "node:crypto";

/** Extract a bearer token from an Authorization header value. */
export function bearer(authorization: string | undefined): string {
  const value = (authorization ?? "").trim();
  if (value.toLowerCase().startsWith("bearer ")) return value.slice(7).trim();
  return value;
}

/** Short URL-safe random id. */
export function randomId(bytes = 9): string {
  return randomBytes(bytes).toString("base64url");
}

/** Constant-time string compare (avoids leaking a secret via timing). */
export function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}
