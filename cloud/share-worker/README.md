# Resoniq share worker

A small Cloudflare Worker in front of one R2 bucket. The iOS app sends the raw recordings of kept speaker tests
here, but only when the person has turned sharing on. The contract (routes, names, limits) is in
`docs/plans/phase-10-share-recordings.md`, section "The service". Nothing in the iOS build refers to this folder.

| Request | Does |
|---|---|
| `POST /v1/installs` | Makes an installation, returns `installId` and `token`; only a SHA-256 of the token is stored |
| `PUT /v1/installs/<installId>/examples/<exampleId>/<file>` | Stores one file (bearer token). 413 over 4 MB, 507 over 300 MB in all |
| `DELETE /v1/installs/<installId>` | Deletes everything of that installation (bearer token) |
| `GET /v1/health` | `{ "ok": true }` |

There is no way to read anything back through the Worker, no listing and no CORS. You read the bucket with your
own Cloudflare login.

## Run it locally

```sh
cd cloud/share-worker
npm install
npm test                                   # Vitest inside the Workers runtime
npx wrangler dev --port 8787 --var RATE_LIMIT_MAX:1000
```

The service is then at `http://localhost:8787` (use this as `RESONIQ_SHARE_URL` for a simulator build).
`--var RATE_LIMIT_MAX:1000` lifts the registration limit, which is 10 an hour per address: a local server sees
every request from the same address, so without it the eleventh test registration in an hour is refused (429).
Deleting `.wrangler/state` also resets it.

The local bucket lives in `cloud/share-worker/.wrangler/state/v3/r2/` (git-ignored). Objects are stored there as
hash-named blobs plus a SQLite index, so you cannot browse them as files. Read one when you know its key:

```sh
npx wrangler r2 object get resoniq-recordings-preview/examples/<installId>/<exampleId>/run-1.wav --local --file run-1.wav
```

(Wrangler has no command to list objects.) Delete the local state with `rm -rf .wrangler`.

## Deploy to your Cloudflare account

You need a Cloudflare account with R2 turned on (R2 asks for a payment method even on the free tier).

1. `cd cloud/share-worker && npm install`
2. `npx wrangler login` (opens a browser; it signs in to your account, nothing is stored in the repository)
3. `npx wrangler r2 bucket create resoniq-recordings`
4. `npx wrangler deploy`
5. Wrangler prints the address, like `https://resoniq-share.<your-subdomain>.workers.dev`. Put it in the local
   xcconfig (the untracked one) as the build setting `RESONIQ_SHARE_URL`, without a trailing slash. An empty
   value means the feature does not exist in that build.
6. Check it: `curl https://resoniq-share.<your-subdomain>.workers.dev/v1/health` should print `{"ok":true}`.

The bucket name and the Worker name are in `wrangler.toml`; if the bucket name is taken or you want another, change
`bucket_name` there. No secret is needed and none is kept in the repository.

## Look at what arrived

- Dashboard: Cloudflare dashboard, R2, `resoniq-recordings`, Objects. Recordings are under `examples/<installId>/<exampleId>/`;
  `installs/` holds the installations (token hashes) and `ratelimit/` the registration counters (hashed addresses).
- One file: `npx wrangler r2 object get resoniq-recordings/examples/<installId>/<exampleId>/manifest.json --remote --file manifest.json`
- Everything: create an R2 API token (dashboard, R2, Manage API tokens, Object Read), then use rclone with the S3
  API: remote type `s3`, provider `Cloudflare`, endpoint `https://<account-id>.r2.cloudflarestorage.com`, and run
  `rclone copy r2:resoniq-recordings/examples ./arrived`. The token and account id stay on your machine.

## Delete an installation by hand

Dashboard: delete the objects under `examples/<installId>/` and the object `installs/<installId>.json`. With
rclone: `rclone purge r2:resoniq-recordings/examples/<installId>` then
`rclone deletefile r2:resoniq-recordings/installs/<installId>.json`. (The app's "Delete what I shared" does the
same through the Worker.)

## Limits and rate limit (all first guesses)

- 4 MB a file, refused by `Content-Length` and again while the body streams.
- 300 MB an installation. The Worker lists the installation's objects on each upload and adds their sizes, so the
  total cannot drift when an upload fails, and a replaced file is not counted twice. It counts again after the
  write and removes the file if the installation is now over, so uploads that arrive together cannot all pass a
  check made before any of them was stored. The cost is two list calls (Class A) per 1000 objects, normally two.
- Registration: 10 installations an hour per address (an IPv6 address counts as its /64, since one customer holds
  the whole prefix), and 500 a day from everyone together (`GLOBAL_DAILY_MAX`), so many addresses cannot fill the
  bucket with installations. That shared limit is a trade: someone with many addresses can use it up and keep new
  installations out until the next day (existing ones keep uploading). That is preferred to unbounded storage on
  your account. The shared limit is kept in 8 counters; an address always writes to the same one and every
  request reads them all, so nothing passes uncounted and a burst from one address cannot make everyone else's
  writes lose their race. Raise `GLOBAL_DAILY_MAX` with
  `--var` or in `wrangler.toml` if honest use reaches it; App Attest is what removes the problem. I checked Cloudflare's docs: the Workers Rate Limiting binding
  is in open beta and the pages I read do not say it is free on the Workers Free plan, so I did not rely on it.
  Instead the Worker keeps one tiny object per hashed address at `ratelimit/<hash>.json` (a window start and a
  count) in the same bucket. It costs one read and one write (a Class B and a Class A operation) per registration,
  and no extra product. Each counter write is conditional on the object not having changed since it was read
  (its etag) and is tried again when another request got there first, so a burst is counted; only the very first
  writes of a counter that does not exist yet can race. The address is stored only as a truncated SHA-256. Counters are not cleaned up; add an R2 lifecycle rule
  for the `ratelimit/` prefix (for example expire after 1 day) in the dashboard if they bother you.

## What it costs on the free plan

Read on 2026-11-14 from Cloudflare's pages:

- R2 (<https://developers.cloudflare.com/r2/pricing/>): free each month: 10 GB-month of Standard storage,
  1 million Class A operations (writes, lists), 10 million Class B operations (reads); egress to the internet is free.
- Workers (<https://developers.cloudflare.com/workers/platform/pricing/>, <https://developers.cloudflare.com/workers/platform/limits/>):
  Free plan: 100,000 requests a day, 10 ms CPU time per request, no charge for duration.

Rough use: an upload is one Class B read (the token check), two Class A lists (the quota, before and after) and
one Class A write, so 1 million Class A operations a month is more than 300,000 uploaded files. The 10 GB storage is the first limit
you would meet: at 300 MB per installation that is about 33 full installations, and a kept test is a few MB.
Past the free tier R2 bills storage and operations; Workers on the Free plan stop answering at 100,000 requests a
day instead of billing. Set a billing alert in the dashboard if you move to a paid plan.

## What is not protected

- The token stops one installation writing into another's folder. It does **not** prove the request comes from the
  app: anyone who registers can upload up to 300 MB of anything that has a valid file name. The size limits and the
  rate limit are the only brakes. App Attest is left for when the feature is opened to more people.
- Files are not checked for being real recordings or valid JSON.
- The address-based limit trusts Cloudflare's `CF-Connecting-IP` header, which Cloudflare sets itself on deployed
  Workers.
- Anyone with your Cloudflare login or an R2 token can read every recording, which can hold voices.
