/** Transport-agnostic request/reply types (see docs/voice-relay.md). */

export interface VoiceRequest {
  /** The command, already voice->text'd by the client. */
  text: string;
  /** Per-user bearer token; resolves to a Slack UID (static-bearer path). */
  token: string;
  /**
   * Pre-resolved Slack UID. Set by the OAuth path (identity from the
   * validated access token); empty ⇒ core resolves `token` via the TokenStore.
   */
  slackUid: string;
  /** Which ingress produced this: 'siri' | 'mcp' | … */
  client: string;
  /** Idempotency key. Client-supplied when available, else relay-generated. */
  requestId: string;
}

export type ReplyStatus = "answered" | "accepted";

export interface VoiceReply {
  /** What the client speaks NOW. */
  speech: string;
  /** answered = fast path (real result); accepted = slow path (Slack DM to follow). */
  status: ReplyStatus;
  requestId: string;
}
