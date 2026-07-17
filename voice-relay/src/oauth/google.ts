/**
 * Google as the upstream identity provider.
 *
 * The id_token is fetched over a direct TLS backchannel to Google's token
 * endpoint, authenticated with our client secret — so it's authentic and we
 * read the email from its payload (we still require email_verified; the
 * provider enforces the allowed domain).
 */

const GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";

export class GoogleError extends Error {}

export function googleAuthUrl(opts: {
  clientId: string;
  redirectUri: string;
  state: string;
  scope?: string;
}): string {
  const q = new URLSearchParams({
    client_id: opts.clientId,
    redirect_uri: opts.redirectUri,
    response_type: "code",
    scope: opts.scope ?? "openid email",
    state: opts.state,
    access_type: "online",
    prompt: "select_account",
  });
  return `${GOOGLE_AUTH}?${q.toString()}`;
}

export async function exchangeCodeForEmail(opts: {
  code: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}): Promise<string> {
  let res: Response;
  try {
    res = await fetch(GOOGLE_TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code: opts.code,
        client_id: opts.clientId,
        client_secret: opts.clientSecret,
        redirect_uri: opts.redirectUri,
        grant_type: "authorization_code",
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (e) {
    throw new GoogleError(`google token exchange failed: ${String(e)}`);
  }
  if (!res.ok) throw new GoogleError(`google token exchange HTTP ${res.status}`);

  const data = (await res.json()) as { id_token?: string };
  if (!data.id_token) throw new GoogleError("google response had no id_token");

  const claims = decodeJwtPayload(data.id_token);
  const email = String(claims["email"] ?? "").trim().toLowerCase();
  if (!email) throw new GoogleError("id_token had no email");
  const verified = claims["email_verified"];
  if (verified !== true && verified !== "true") {
    throw new GoogleError(`email ${email} is not verified by Google`);
  }
  return email;
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new GoogleError("malformed id_token");
  try {
    return JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf-8")) as Record<
      string,
      unknown
    >;
  } catch (e) {
    throw new GoogleError(`could not decode id_token payload: ${String(e)}`);
  }
}
