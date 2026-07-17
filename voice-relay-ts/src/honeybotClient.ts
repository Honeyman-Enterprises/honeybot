/** Drive honeybot's agent via its OpenAI-compatible api_server. */

export class HoneybotClient {
  constructor(
    private readonly baseUrl: string,
    private readonly apiKey: string,
    private readonly model: string,
    private readonly timeoutMs: number,
  ) {}

  async run(text: string, opts: { identity: string; requestId: string }): Promise<string> {
    const res = await fetch(`${this.baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
        // Identity hint for per-user credential resolution (Phase 3).
        "X-Honeybot-Slack-User": opts.identity,
        "X-Voice-Request-Id": opts.requestId,
      },
      body: JSON.stringify({
        model: this.model,
        messages: [{ role: "user", content: text }],
        stream: false,
        user: opts.identity,
      }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok) throw new Error(`api_server returned HTTP ${res.status}`);
    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: string | null } }>;
    };
    const content = data.choices?.[0]?.message?.content;
    if (content == null) throw new Error("api_server returned an empty message");
    return content.trim();
  }
}
