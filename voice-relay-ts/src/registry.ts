/**
 * Per-request state + single-delivery claim.
 *
 * `claim()` is a check-and-set with no `await` between read and write, so in
 * single-threaded JS (one event loop) it's atomic: exactly one of {fast, slow}
 * path delivers. A duplicate is therefore impossible in normal flow — and even
 * if one slipped through the payload is identical, so no lock is warranted.
 */

interface Entry {
  slackUid: string;
  text: string;
  client: string;
  openedAt: number;
  delivered: boolean;
  closed: boolean;
}

export class Registry {
  private entries = new Map<string, Entry>();

  open(requestId: string, slackUid: string, text: string, client: string): void {
    this.entries.set(requestId, {
      slackUid,
      text,
      client,
      openedAt: Date.now(),
      delivered: false,
      closed: false,
    });
  }

  /** Atomically claim delivery. true = you won, go deliver. */
  claim(requestId: string): boolean {
    const e = this.entries.get(requestId);
    if (!e || e.delivered) return false;
    e.delivered = true;
    return true;
  }

  close(requestId: string): void {
    const e = this.entries.get(requestId);
    if (e) e.closed = true;
  }

  snapshot(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [id, e] of this.entries) {
      out[id] = {
        slack_uid: e.slackUid,
        client: e.client,
        age_s: Math.round((Date.now() - e.openedAt) / 100) / 10,
        delivered: e.delivered,
        closed: e.closed,
      };
    }
    return out;
  }
}
