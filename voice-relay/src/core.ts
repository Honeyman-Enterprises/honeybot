/**
 * The fast-ack / async-DM state machine (see docs/voice-relay.md).
 *
 * Don't classify request duration — RACE a timeout. Fire the command at the
 * agent, wait `fastAckMs`. Settled in time → speak it. Timed out → return the
 * ack and let the same promise finish, delivering the late result to Slack.
 * Exactly one path delivers (registry claim); JS promises can't be cancelled,
 * so the "task" promise keeps running after a timeout — which is what we want.
 */

import type { Config } from "./config.js";
import type { Registry } from "./registry.js";
import type { VoiceReply, VoiceRequest } from "./types.js";

// Collaborators are interfaces (not concrete classes) so tests can inject
// fakes — TS `private` fields would otherwise make the classes nominal.
export interface Agent {
  run(text: string, opts: { identity: string; requestId: string }): Promise<string>;
}
export interface SlackDelivery {
  dm(slackUid: string, text: string): Promise<void>;
}
export interface TokenResolver {
  resolve(token: string): string; // throws UnknownToken on a bad token
}

interface Deps {
  tokens: TokenResolver;
  registry: Registry;
  honeybot: Agent;
  slack: SlackDelivery;
  config: Config;
}

type RaceResult =
  | { timedOut: true }
  | { timedOut: false; value: string }
  | { timedOut: false; error: unknown };

export class Core {
  constructor(private readonly deps: Deps) {}

  async handle(req: VoiceRequest): Promise<VoiceReply> {
    // OAuth requests arrive with a pre-resolved UID; static-bearer requests
    // resolve the token via the TokenStore (throws UnknownToken → 401).
    const slackUid = req.slackUid || this.deps.tokens.resolve(req.token);
    this.deps.registry.open(req.requestId, slackUid, req.text, req.client);

    // One promise; both the fast path and the slow path observe it.
    const task = this.produce(req, slackUid);
    const result = await firstWithin(task, this.deps.config.fastAckMs);

    if (result.timedOut) {
      // Slow path: hand back the ack; deliver to Slack when the agent finishes.
      void this.deliverLate(task, req, slackUid);
      return { speech: this.deps.config.ackMessage, status: "accepted", requestId: req.requestId };
    }

    // Fast path: claim so nothing double-delivers, then speak.
    this.deps.registry.claim(req.requestId);
    this.deps.registry.close(req.requestId);
    if ("error" in result) {
      return { speech: friendlyError(), status: "answered", requestId: req.requestId };
    }
    return { speech: result.value, status: "answered", requestId: req.requestId };
  }

  private produce(req: VoiceRequest, slackUid: string): Promise<string> {
    return this.deps.honeybot.run(req.text, { identity: slackUid, requestId: req.requestId });
  }

  private async deliverLate(task: Promise<string>, req: VoiceRequest, slackUid: string): Promise<void> {
    let result: string;
    try {
      result = await task;
    } catch {
      result = friendlyError();
    }
    if (this.deps.registry.claim(req.requestId)) {
      try {
        await this.deps.slack.dm(slackUid, result);
      } catch {
        /* logged upstream; best-effort */
      }
    }
    this.deps.registry.close(req.requestId);
  }
}

/**
 * Resolve when `p` settles OR the timeout fires — without cancelling `p`
 * (it keeps running for the slow path). The .then handlers stay attached, so
 * a late rejection of `p` is consumed here (no unhandledRejection) and also
 * re-observed by deliverLate's own await.
 */
function firstWithin(p: Promise<string>, ms: number): Promise<RaceResult> {
  return new Promise<RaceResult>((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve({ timedOut: true });
      }
    }, ms);
    p.then(
      (value) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve({ timedOut: false, value });
        }
      },
      (error: unknown) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve({ timedOut: false, error });
        }
      },
    );
  });
}

function friendlyError(): string {
  return "Sorry — I couldn't finish that request.";
}
