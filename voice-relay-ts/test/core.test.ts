import assert from "node:assert/strict";
import { test } from "node:test";

import type { Config } from "../src/config.js";
import { Core, type Agent, type SlackDelivery, type TokenResolver } from "../src/core.js";
import { Registry } from "../src/registry.js";
import { UnknownToken } from "../src/tokenStore.js";
import type { VoiceRequest } from "../src/types.js";

class FakeHoneybot implements Agent {
  calls = 0;
  constructor(
    private readonly delayMs: number,
    private readonly result = "the answer",
    private readonly err?: Error,
  ) {}
  async run(): Promise<string> {
    this.calls += 1;
    await sleep(this.delayMs);
    if (this.err) throw this.err;
    return this.result;
  }
}

class FakeSlack implements SlackDelivery {
  dms: Array<[string, string]> = [];
  async dm(uid: string, text: string): Promise<void> {
    this.dms.push([uid, text]);
  }
}

const tokens: TokenResolver = {
  resolve(token: string): string {
    if (token === "tok-eric") return "U04ERIC";
    throw new UnknownToken();
  },
};

function config(fastAckMs = 50): Config {
  return {
    port: 8080,
    fastAckMs,
    agentTimeoutMs: 5000,
    honeybotApiUrl: "http://x/v1",
    honeybotApiKey: "k",
    honeybotModel: "m",
    slackBotToken: "xoxb",
    tokenMap: {},
    ackMessage: "On it — Slack incoming.",
    tokenStorePath: "",
    adminKey: "",
    publicUrl: "https://voice.example",
    oauthGoogleClientId: "",
    oauthGoogleClientSecret: "",
    oauthAllowedDomains: new Set(["honeymanenterprises.com"]),
    oauthStorePath: "",
  };
}

function req(over: Partial<VoiceRequest> = {}): VoiceRequest {
  return { text: "what's on my calendar", token: "tok-eric", slackUid: "", client: "siri", requestId: "r1", ...over };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("fast path answers inline, no DM", async () => {
  const hb = new FakeHoneybot(5, "3 meetings");
  const slack = new FakeSlack();
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack, config: config() });
  const reply = await core.handle(req());
  assert.equal(reply.status, "answered");
  assert.equal(reply.speech, "3 meetings");
  await sleep(30);
  assert.deepEqual(slack.dms, []);
});

test("slow path acks then DMs exactly once", async () => {
  const hb = new FakeHoneybot(120, "done: image updated");
  const slack = new FakeSlack();
  const cfg = config(40);
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack, config: cfg });
  const reply = await core.handle(req());
  assert.equal(reply.status, "accepted");
  assert.equal(reply.speech, cfg.ackMessage);
  assert.deepEqual(slack.dms, []);
  await sleep(150);
  assert.deepEqual(slack.dms, [["U04ERIC", "done: image updated"]]);
});

test("fast error speaks friendly, no crash, no DM", async () => {
  const hb = new FakeHoneybot(5, "", new Error("boom"));
  const slack = new FakeSlack();
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack, config: config() });
  const reply = await core.handle(req());
  assert.equal(reply.status, "answered");
  assert.match(reply.speech.toLowerCase(), /couldn't finish/);
  await sleep(30);
  assert.deepEqual(slack.dms, []);
});

test("slow error DMs friendly", async () => {
  const hb = new FakeHoneybot(120, "", new Error("boom"));
  const slack = new FakeSlack();
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack, config: config(40) });
  const reply = await core.handle(req());
  assert.equal(reply.status, "accepted");
  await sleep(150);
  assert.equal(slack.dms.length, 1);
  assert.match(slack.dms[0]![1].toLowerCase(), /couldn't finish/);
});

test("unknown token rejected before the agent runs", async () => {
  const hb = new FakeHoneybot(5);
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack: new FakeSlack(), config: config() });
  await assert.rejects(() => core.handle(req({ token: "tok-nope" })), (e) => e instanceof UnknownToken);
  assert.equal(hb.calls, 0);
});

test("pre-resolved slackUid bypasses the token map (OAuth path)", async () => {
  const hb = new FakeHoneybot(5, "hi");
  const slack = new FakeSlack();
  const core = new Core({ tokens, registry: new Registry(), honeybot: hb, slack, config: config() });
  const reply = await core.handle(req({ token: "", slackUid: "U09OAUTH" }));
  assert.equal(reply.status, "answered");
  assert.equal(hb.calls, 1);
});
