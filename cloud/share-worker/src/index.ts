// Resoniq share worker: receives opt-in speaker-test recordings into one R2 bucket.
// Contract: docs/plans/phase-10-share-recordings.md, section "The service".
// There is deliberately no route that reads an object back, and no CORS.

export interface Env {
  BUCKET: R2Bucket;
  // Optional override of the registration limit, for local development only (see README).
  RATE_LIMIT_MAX?: string;
  GLOBAL_DAILY_MAX?: string;
}

import { GLOBAL_DAILY_MAX, MAX_FILE_BYTES, MAX_INSTALL_BYTES, RATE_LIMIT_MAX, RATE_LIMIT_WINDOW_SECONDS } from "./limits";
import { clientKey } from "./address";

const INSTALL_ID = /^[0-9a-f]{32}$/;
const TOKEN = /^[0-9a-f]{64}$/;
const EXAMPLE_ID = /^[A-Za-z0-9_-]{8,64}$/;
const FILE_NAME = /^(manifest\.json|noise-floor\.wav|run-[1-9]\.wav)$/;

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

const fail = (status: number, code: string, headers: Record<string, string> = {}) =>
  json(status, { error: code }, headers);

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function randomHex(byteCount: number): string {
  return hex(crypto.getRandomValues(new Uint8Array(byteCount)));
}

async function sha256Hex(text: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))));
}

// Compares two strings without stopping at the first difference.
function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

interface InstallRecord {
  tokenHash: string;
  createdAt: string;
}

async function authenticate(request: Request, env: Env, installId: string): Promise<boolean> {
  const match = /^Bearer ([^\s]+)$/i.exec(request.headers.get("authorization") ?? "");
  const token = match?.[1] ?? "";
  const wellFormed = TOKEN.test(token);
  // Always hash and compare, so a missing installation and a wrong token behave alike.
  const presentedHash = await sha256Hex(wellFormed ? token : "invalid");
  const object = await env.BUCKET.get(`installs/${installId}.json`);
  let storedHash = "";
  if (object) {
    try {
      storedHash = ((await object.json()) as InstallRecord).tokenHash ?? "";
    } catch {
      storedHash = "";
    }
  }
  const equal = constantTimeEqual(presentedHash, storedHash || "0".repeat(64));
  return equal && object !== null && wellFormed;
}

// Adds one to a counter object if it is under `max` in the current window; returns the seconds to wait when it
// is not. The write is conditional on the object not having changed since it was read (its etag), and is tried
// again when another request got there first, so parallel requests cannot all read the same count. A counter
// that does not exist yet has no etag to hold, so its very first writes can still race; that lets through at most
// the number of requests that arrive before the first write lands.
async function countOne(env: Env, key: string, max: number, windowSeconds: number): Promise<number | null> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const now = Math.floor(Date.now() / 1000);
    let windowStart = now;
    let count = 0;
    const existing = await env.BUCKET.get(key);
    if (existing) {
      try {
        const state = (await existing.json()) as { windowStart: number; count: number };
        if (now - state.windowStart < windowSeconds) {
          windowStart = state.windowStart;
          count = state.count;
        }
      } catch {
        // A damaged counter starts a fresh window.
      }
    }
    if (count >= max) return Math.max(1, windowStart + windowSeconds - now);
    const written = await env.BUCKET.put(key, JSON.stringify({ windowStart, count: count + 1 }), {
      httpMetadata: { contentType: "application/json" },
      onlyIf: existing ? { etagMatches: existing.etag } : undefined,
    });
    if (written !== null) return null;
  }
  // Five lost races in a row is a burst: refuse rather than let it through uncounted.
  return 1;
}

// Two limits on making installations: one per address (per /64 for IPv6), and one for everyone together, so that
// many addresses cannot fill the bucket with installations.
async function rateLimited(request: Request, env: Env): Promise<number | null> {
  const address = clientKey(request.headers.get("cf-connecting-ip") ?? "unknown");
  const perAddress = Number.parseInt(env.RATE_LIMIT_MAX ?? "", 10) || RATE_LIMIT_MAX;
  const wait = await countOne(
    env, `ratelimit/${(await sha256Hex(address)).slice(0, 32)}.json`, perAddress, RATE_LIMIT_WINDOW_SECONDS,
  );
  if (wait !== null) return wait;
  const everyone = Number.parseInt(env.GLOBAL_DAILY_MAX ?? "", 10) || GLOBAL_DAILY_MAX;
  return countOne(env, "ratelimit/everyone.json", everyone, 24 * 3600);
}

async function register(request: Request, env: Env): Promise<Response> {
  const retryAfter = await rateLimited(request, env);
  if (retryAfter !== null) return fail(429, "rate_limited", { "retry-after": String(retryAfter) });
  const installId = randomHex(16);
  const token = randomHex(32);
  const record: InstallRecord = {
    tokenHash: await sha256Hex(token),
    createdAt: new Date().toISOString(),
  };
  await env.BUCKET.put(`installs/${installId}.json`, JSON.stringify(record), {
    httpMetadata: { contentType: "application/json" },
  });
  return json(200, { installId, token });
}

// Reads at most MAX_FILE_BYTES of the body; null means it is larger than that.
async function readLimited(body: ReadableStream<Uint8Array> | null): Promise<Uint8Array | null> {
  if (!body) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_FILE_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

// Sums the sizes of everything stored for the installation, by listing (paged).
// Chosen over a running total in the installation's JSON: a listing cannot drift when an upload
// fails halfway, when two uploads race, or when a file is replaced, and it needs no second write per
// upload. It costs one Class A list per 1000 objects, which is one call for a normal installation.
async function storedBytes(env: Env, installId: string, exceptKey: string): Promise<number> {
  let total = 0;
  let cursor: string | undefined;
  do {
    const page = await env.BUCKET.list({ prefix: `examples/${installId}/`, cursor });
    for (const object of page.objects) if (object.key !== exceptKey) total += object.size;
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return total;
}

async function upload(
  request: Request,
  env: Env,
  installId: string,
  exampleId: string,
  file: string,
): Promise<Response> {
  if (!INSTALL_ID.test(installId) || !EXAMPLE_ID.test(exampleId) || !FILE_NAME.test(file)) {
    return fail(400, "bad_name");
  }
  if (!(await authenticate(request, env, installId))) return fail(401, "unauthorized");

  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > MAX_FILE_BYTES) return fail(413, "too_large");
  const body = await readLimited(request.body);
  if (body === null) return fail(413, "too_large");
  if (body.byteLength === 0) return fail(400, "empty_body");

  const key = `examples/${installId}/${exampleId}/${file}`;
  if ((await storedBytes(env, installId, key)) + body.byteLength > MAX_INSTALL_BYTES) {
    return fail(507, "quota_exceeded");
  }
  await env.BUCKET.put(key, body, {
    httpMetadata: { contentType: file.endsWith(".json") ? "application/json" : "audio/wav" },
  });
  // Uploads of one installation that arrive together each pass the check above before any of them is stored.
  // Counting again after the write closes that: whichever write took the installation over its limit is removed.
  if ((await storedBytes(env, installId, "")) > MAX_INSTALL_BYTES) {
    await env.BUCKET.delete(key);
    return fail(507, "quota_exceeded");
  }
  return json(200, { ok: true });
}

async function deleteInstall(request: Request, env: Env, installId: string): Promise<Response> {
  if (!INSTALL_ID.test(installId)) return fail(400, "bad_name");
  if (!(await authenticate(request, env, installId))) return fail(401, "unauthorized");
  let cursor: string | undefined;
  do {
    const page = await env.BUCKET.list({ prefix: `examples/${installId}/`, cursor });
    if (page.objects.length > 0) await env.BUCKET.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  await env.BUCKET.delete(`installs/${installId}.json`);
  return json(200, { ok: true });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const segments = new URL(request.url).pathname.split("/").slice(1);
      if (segments.length > 1 && segments[segments.length - 1] === "") segments.pop();
      const method = request.method;
      const allow = (...methods: string[]) =>
        fail(405, "method_not_allowed", { allow: methods.join(", ") });

      if (segments[0] !== "v1") return fail(404, "not_found");

      if (segments.length === 2 && segments[1] === "health") {
        return method === "GET" ? json(200, { ok: true }) : allow("GET");
      }
      if (segments.length === 2 && segments[1] === "installs") {
        return method === "POST" ? await register(request, env) : allow("POST");
      }
      if (segments[1] === "installs" && segments.length === 3) {
        return method === "DELETE" ? await deleteInstall(request, env, segments[2]) : allow("DELETE");
      }
      if (segments[1] === "installs" && segments.length === 6 && segments[3] === "examples") {
        return method === "PUT"
          ? await upload(request, env, segments[2], segments[4], segments[5])
          : allow("PUT");
      }
      return fail(404, "not_found");
    } catch {
      return fail(500, "internal");
    }
  },
} satisfies ExportedHandler<Env>;
