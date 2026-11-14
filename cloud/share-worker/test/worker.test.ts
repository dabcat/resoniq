import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_FILE_BYTES, MAX_INSTALL_BYTES, RATE_LIMIT_MAX } from "../src/limits";

const BASE = "https://share.test";
let ipCounter = 0;

function call(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(new Request(BASE + path, init));
}

// Each registration comes from its own made-up address so the rate limit does not interfere.
async function register(ip = `10.0.0.${++ipCounter}`) {
  const res = await call("/v1/installs", { method: "POST", headers: { "cf-connecting-ip": ip } });
  expect(res.status).toBe(200);
  return (await res.json()) as { installId: string; token: string };
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });
const EXAMPLE = "example-0001";

function put(installId: string, token: string | null, file: string, body: BodyInit, exampleId = EXAMPLE) {
  return call(`/v1/installs/${installId}/examples/${exampleId}/${file}`, {
    method: "PUT",
    headers: token ? auth(token) : {},
    body,
  });
}

async function keysFor(installId: string): Promise<string[]> {
  const listed = await env.BUCKET.list({ prefix: `examples/${installId}/` });
  return listed.objects.map((o) => o.key);
}

describe("health and unknown routes", () => {
  it("answers health", async () => {
    const res = await call("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("returns JSON 404 for unknown paths", async () => {
    for (const path of ["/", "/v2/health", "/v1", "/v1/installs/abc/extra", "/v1/other"]) {
      const res = await call(path);
      expect(res.status, path).toBe(404);
      expect(await res.json()).toEqual({ error: "not_found" });
    }
  });

  it("returns JSON 405 for the wrong method on a known path", async () => {
    const cases: [string, string][] = [
      ["POST", "/v1/health"],
      ["GET", "/v1/installs"],
      ["GET", `/v1/installs/${"a".repeat(32)}`],
      ["GET", `/v1/installs/${"a".repeat(32)}/examples/${EXAMPLE}/manifest.json`],
      ["POST", `/v1/installs/${"a".repeat(32)}/examples/${EXAMPLE}/manifest.json`],
    ];
    for (const [method, path] of cases) {
      const res = await call(path, { method });
      expect(res.status, `${method} ${path}`).toBe(405);
      expect(((await res.json()) as { error: string }).error).toBe("method_not_allowed");
    }
  });

  it("sends no CORS headers", async () => {
    const res = await call("/v1/health", { headers: { origin: "https://example.com" } });
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
  });
});

describe("registration", () => {
  it("returns an id and token of the right shape and stores only the token's hash", async () => {
    const { installId, token } = await register();
    expect(installId).toMatch(/^[0-9a-f]{32}$/);
    expect(token).toMatch(/^[0-9a-f]{64}$/);
    const stored = await env.BUCKET.get(`installs/${installId}.json`);
    const record = (await stored!.json()) as { tokenHash: string; createdAt: string };
    expect(record.tokenHash).toMatch(/^[0-9a-f]{64}$/);
    expect(record.tokenHash).not.toBe(token);
    expect(JSON.stringify(record)).not.toContain(token);
    expect(Number.isNaN(Date.parse(record.createdAt))).toBe(false);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const expected = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    expect(record.tokenHash).toBe(expected);
  });

  it("gives every installation different values", async () => {
    const a = await register();
    const b = await register();
    expect(a.installId).not.toBe(b.installId);
    expect(a.token).not.toBe(b.token);
  });

  it("limits registrations per address and recovers in a new window", async () => {
    const ip = "192.0.2.77";
    for (let i = 0; i < RATE_LIMIT_MAX; i++) await register(ip);
    const res = await call("/v1/installs", { method: "POST", headers: { "cf-connecting-ip": ip } });
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
    // Another address is unaffected.
    await register("192.0.2.78");
    // Age the counter past the window.
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
    const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    const old = Math.floor(Date.now() / 1000) - 7200;
    await env.BUCKET.put(`ratelimit/${hash.slice(0, 32)}.json`, JSON.stringify({ windowStart: old, count: RATE_LIMIT_MAX }));
    await register(ip);
  });
});

describe("upload", () => {
  it("stores a manifest and a wav under the right key with the right content type", async () => {
    const { installId, token } = await register();
    expect((await put(installId, token, "manifest.json", '{"a":1}')).status).toBe(200);
    expect((await put(installId, token, "run-3.wav", new Uint8Array([1, 2, 3, 4]))).status).toBe(200);
    expect((await put(installId, token, "noise-floor.wav", new Uint8Array([9]))).status).toBe(200);

    const manifest = await env.BUCKET.head(`examples/${installId}/${EXAMPLE}/manifest.json`);
    expect(manifest?.httpMetadata?.contentType).toBe("application/json");
    const wav = await env.BUCKET.get(`examples/${installId}/${EXAMPLE}/run-3.wav`);
    expect(wav?.httpMetadata?.contentType).toBe("audio/wav");
    expect(new Uint8Array(await wav!.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect((await keysFor(installId)).length).toBe(3);
  });

  it("replaces a file uploaded twice", async () => {
    const { installId, token } = await register();
    await put(installId, token, "manifest.json", '{"v":1}');
    await put(installId, token, "manifest.json", '{"v":2}');
    const stored = await env.BUCKET.get(`examples/${installId}/${EXAMPLE}/manifest.json`);
    expect(await stored!.text()).toBe('{"v":2}');
    expect((await keysFor(installId)).length).toBe(1);
  });

  it("accepts every allowed file name", async () => {
    const { installId, token } = await register();
    const names = ["manifest.json", "noise-floor.wav", ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => `run-${n}.wav`)];
    for (const name of names) expect((await put(installId, token, name, "x")).status, name).toBe(200);
  });

  it("refuses a missing token, a malformed header and a wrong token with 401", async () => {
    const { installId, token } = await register();
    const wrong = token.replace(/^./, token[0] === "0" ? "1" : "0");
    for (const headers of [{}, { authorization: "Basic abc" }, { authorization: "Bearer" }, auth(wrong), auth("short")]) {
      const res = await call(`/v1/installs/${installId}/examples/${EXAMPLE}/manifest.json`, {
        method: "PUT",
        headers,
        body: "x",
      });
      expect(res.status).toBe(401);
      expect(await res.json()).toEqual({ error: "unauthorized" });
    }
    expect((await keysFor(installId)).length).toBe(0);
  });

  it("refuses another installation's token and an unknown installation", async () => {
    const a = await register();
    const b = await register();
    expect((await put(a.installId, b.token, "manifest.json", "x")).status).toBe(401);
    expect((await put("f".repeat(32), a.token, "manifest.json", "x")).status).toBe(401);
    expect((await keysFor(a.installId)).length).toBe(0);
  });

  it("refuses bad example ids with 400", async () => {
    const { installId, token } = await register();
    for (const id of ["short", "x".repeat(65), "has space1", "dots.dots.", "uniécode1", "a%2Fb-12345678"]) {
      const res = await put(installId, token, "manifest.json", "x", id);
      expect(res.status, id).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_name" });
    }
    // Edges that are allowed.
    expect((await put(installId, token, "manifest.json", "x", "abcdefgh")).status).toBe(200);
    expect((await put(installId, token, "manifest.json", "x", "A_-" + "z".repeat(61))).status).toBe(200);
  });

  it("refuses bad file names with 400", async () => {
    const { installId, token } = await register();
    for (const file of [
      "run-0.wav",
      "run-10.wav",
      "run-1.WAV",
      "run-1.wav.bak",
      "Manifest.json",
      "notes.txt",
      "noise-floor.wav%20",
      "..%2Fmanifest.json",
      "a%2Fb.wav",
      "run-1%2ewav%00",
    ]) {
      const res = await call(`/v1/installs/${installId}/examples/${EXAMPLE}/${file}`, {
        method: "PUT",
        headers: auth(token),
        body: "x",
      });
      expect(res.status, file).toBe(400);
    }
  });

  it("does not let path traversal reach another path", async () => {
    const a = await register();
    const b = await register();
    // The URL parser resolves "..", so the request lands on a different route and is not an upload.
    const res = await call(`/v1/installs/${a.installId}/examples/${EXAMPLE}/../../${b.installId}/examples/${EXAMPLE}/manifest.json`, {
      method: "PUT",
      headers: auth(a.token),
      body: "x",
    });
    expect([400, 401, 404, 405]).toContain(res.status);
    // Encoded variants stay in one segment and fail validation.
    const encoded = await call(`/v1/installs/${a.installId}/examples/..%2F${b.installId}%2F${EXAMPLE}/manifest.json`, {
      method: "PUT",
      headers: auth(a.token),
      body: "x",
    });
    expect(encoded.status).toBe(400);
    expect((await keysFor(b.installId)).length).toBe(0);
    expect((await keysFor(a.installId)).length).toBe(0);
    // A malformed installation id is a bad name, even with a plausible token.
    const badInstall = await call(`/v1/installs/..%2F..%2Fx/examples/${EXAMPLE}/manifest.json`, {
      method: "PUT",
      headers: auth(a.token),
      body: "x",
    });
    expect(badInstall.status).toBe(400);
  });

  it("refuses a body over 4 MB by Content-Length without reading it", async () => {
    const { installId, token } = await register();
    const res = await call(`/v1/installs/${installId}/examples/${EXAMPLE}/run-1.wav`, {
      method: "PUT",
      headers: { ...auth(token), "content-length": String(MAX_FILE_BYTES + 1) },
      body: "tiny",
    });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "too_large" });
    expect((await keysFor(installId)).length).toBe(0);
  });

  it("refuses a body over 4 MB while streaming, with no Content-Length", async () => {
    const { installId, token } = await register();
    const chunk = new Uint8Array(1024 * 1024);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent >= 6) return controller.close();
        sent++;
        controller.enqueue(chunk);
      },
    });
    const res = await call(`/v1/installs/${installId}/examples/${EXAMPLE}/run-1.wav`, {
      method: "PUT",
      headers: auth(token),
      body: stream,
      // @ts-expect-error duplex is required for streamed request bodies
      duplex: "half",
    });
    expect(res.status).toBe(413);
    expect((await keysFor(installId)).length).toBe(0);
  });

  it("accepts a body of exactly 4 MB", async () => {
    const { installId, token } = await register();
    const res = await put(installId, token, "run-1.wav", new Uint8Array(MAX_FILE_BYTES));
    expect(res.status).toBe(200);
  });

  it("refuses an empty body", async () => {
    const { installId, token } = await register();
    const res = await put(installId, token, "manifest.json", "");
    expect(res.status).toBe(400);
  });

  it("refuses an upload that would pass 300 MB in all, but still allows a replacement", async () => {
    const { installId, token } = await register();
    const block = new Uint8Array(MAX_FILE_BYTES);
    const count = Math.floor(MAX_INSTALL_BYTES / MAX_FILE_BYTES); // 75 blocks fill it exactly
    for (let i = 0; i < count; i++) {
      await env.BUCKET.put(`examples/${installId}/seed-${String(i).padStart(4, "0")}/run-1.wav`, block);
    }
    const full = await put(installId, token, "run-1.wav", "x", "new-example");
    expect(full.status).toBe(507);
    expect(await full.json()).toEqual({ error: "quota_exceeded" });
    // Replacing an existing file of the same size stays within the total.
    const replace = await put(installId, token, "run-1.wav", block, "seed-0000");
    expect(replace.status).toBe(200);
    // Another installation has its own total.
    const other = await register();
    expect((await put(other.installId, other.token, "run-1.wav", "x")).status).toBe(200);
  }, 120_000);
});

describe("delete", () => {
  it("removes every object and the installation, and the token stops working", async () => {
    const a = await register();
    const b = await register();
    await put(a.installId, a.token, "manifest.json", "{}");
    await put(a.installId, a.token, "run-1.wav", "x");
    await put(a.installId, a.token, "run-2.wav", "x", "example-0002");
    await put(b.installId, b.token, "manifest.json", "{}");

    const res = await call(`/v1/installs/${a.installId}`, { method: "DELETE", headers: auth(a.token) });
    expect(res.status).toBe(200);
    expect(await keysFor(a.installId)).toEqual([]);
    expect(await env.BUCKET.head(`installs/${a.installId}.json`)).toBeNull();

    // The token is now useless for upload and delete.
    expect((await put(a.installId, a.token, "manifest.json", "{}")).status).toBe(401);
    const again = await call(`/v1/installs/${a.installId}`, { method: "DELETE", headers: auth(a.token) });
    expect(again.status).toBe(401);
    // The other installation is untouched.
    expect((await keysFor(b.installId)).length).toBe(1);
  });

  it("pages through more than 1000 objects", async () => {
    const { installId, token } = await register();
    for (let i = 0; i < 1100; i++) {
      await env.BUCKET.put(`examples/${installId}/seed-${String(i).padStart(5, "0")}/manifest.json`, "{}");
    }
    const res = await call(`/v1/installs/${installId}`, { method: "DELETE", headers: auth(token) });
    expect(res.status).toBe(200);
    expect(await keysFor(installId)).toEqual([]);
  }, 120_000);

  it("refuses a missing, wrong or foreign token and a bad id", async () => {
    const a = await register();
    const b = await register();
    await put(a.installId, a.token, "manifest.json", "{}");
    for (const headers of [{}, auth(b.token)]) {
      const res = await call(`/v1/installs/${a.installId}`, { method: "DELETE", headers });
      expect(res.status).toBe(401);
    }
    expect((await call("/v1/installs/not-an-id", { method: "DELETE", headers: auth(a.token) })).status).toBe(400);
    expect((await keysFor(a.installId)).length).toBe(1);
  });
});
