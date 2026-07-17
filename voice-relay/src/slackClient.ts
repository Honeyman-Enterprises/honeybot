/** Slack: DM late results, and resolve a Slack UID from an email (for OAuth). */

const SLACK_API = "https://slack.com/api";

export class SlackClient {
  constructor(private readonly botToken: string) {}

  async dm(slackUid: string, text: string): Promise<void> {
    const headers = {
      Authorization: `Bearer ${this.botToken}`,
      "Content-Type": "application/json; charset=utf-8",
    };
    const opened = (await (
      await fetch(`${SLACK_API}/conversations.open`, {
        method: "POST",
        headers,
        body: JSON.stringify({ users: slackUid }),
      })
    ).json()) as { ok?: boolean; error?: string; channel?: { id?: string } };
    if (!opened.ok || !opened.channel?.id) {
      throw new Error(`conversations.open failed: ${opened.error ?? "unknown"}`);
    }
    const posted = (await (
      await fetch(`${SLACK_API}/chat.postMessage`, {
        method: "POST",
        headers,
        body: JSON.stringify({ channel: opened.channel.id, text }),
      })
    ).json()) as { ok?: boolean; error?: string };
    if (!posted.ok) throw new Error(`chat.postMessage failed: ${posted.error ?? "unknown"}`);
  }
}

/**
 * Return a resolver(email) -> Slack UID | "". Fail-closed on any error; the
 * OAuth provider refuses to mint a token when the email resolves to nothing.
 * Rejects bot/deleted accounts. Needs the bot's users:read.email scope.
 */
export function slackUidResolver(botToken: string): (email: string) => Promise<string> {
  return async (email: string): Promise<string> => {
    if (!botToken || !email) return "";
    try {
      const res = await fetch(
        `${SLACK_API}/users.lookupByEmail?${new URLSearchParams({ email })}`,
        { headers: { Authorization: `Bearer ${botToken}` } },
      );
      const data = (await res.json()) as {
        ok?: boolean;
        user?: { id?: string; is_bot?: boolean; deleted?: boolean };
      };
      if (data.ok && data.user && !data.user.is_bot && !data.user.deleted) {
        return data.user.id ?? "";
      }
    } catch {
      /* fail closed */
    }
    return "";
  };
}
