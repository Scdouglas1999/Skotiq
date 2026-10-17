# Diagnostics and Privacy

How Skotiq 4.1.0 produces logs and diagnostic data, what that data can
contain, and how to share it safely. This applies to the desktop app, the
headless server (Pi / embedded appliance), and the mobile companion that
reads logs over the LAN.

If you are configuring remote access, read this alongside
[`headless-secure-setup.md`](headless-secure-setup.md) and
[`remote-control.md`](remote-control.md).

---

## Where logs live and who can read them

Skotiq writes a structured log through `LoggingService`. Entries land in
three places:

- **On-disk log files** under the platform app-data directory. The Rust
  `tracing` appender rolls daily (`skotiq.log`, `skotiq.log.YYYY-MM-DD`).
  These files are **not auto-pruned** — they accumulate until an operator
  clears them. Anyone with filesystem or SSH access to the host can read them.
- **An in-memory ring buffer** (the most recent ~1000 entries), surfaced for
  quick inspection without touching disk.
- **The console / stdout** of the headless server, captured by whatever
  launched it (systemd journal, a terminal, a redirect file).

The headless server additionally exposes the log surface over the API so a
phone on the LAN can diagnose without SSH:

| Endpoint | What it returns | Auth |
| --- | --- | --- |
| `GET /api/logs` | List of on-disk log files (name, size, mtime) | view scope |
| `GET /api/logs/recent` | Last N ring-buffer entries (JSON) | view scope |
| `GET /api/logs/files/<name>/download` | A full log file as an attachment | view scope |
| `GET /api/logs/tail` | Live Server-Sent-Events stream of new entries | view scope |
| `POST /api/logs/clear` | Delete non-current log files | admin scope |
| `POST /api/logs/test-entry` | Write a synthetic entry | admin scope |

**Auth gating.** When authentication is configured (a paired token, an
`--auth-token`, or `--require-auth`), the read endpoints above require a valid
bearer token; only `clear` and `test-entry` need admin scope. When the server
is started **without** auth (no token configured), the auth middleware is
skipped entirely and these endpoints — and therefore the full log contents —
are reachable by anyone who can reach the port. Do not run an
unauthenticated headless server on an untrusted network. The download handler
hardens the *filename* against path traversal (anchored regex plus a
resolved-parent check), but it does not redact the *contents* of a valid log
file.

---

## What a log / diagnostic copy can contain

Logs are operational, not deliberately personal, but the following sensitive
values can appear. Treat any shared log as containing all of these until you
have scrubbed it.

- **Observer location (latitude / longitude).** The configured site
  coordinates are effectively your home or observatory address. Weather and
  forecast requests carry the site lat/lon. (As of 4.1.0 the weather handler
  log lines coarsen these to ~one decimal place; see "What the code already
  does" below. Other surfaces may still record finer values.)
- **Local network details.** The headless startup banner prints the LAN IP and
  port the server binds (`http://192.168.x.x:PORT`), and request/audit lines
  can carry client IPs. These reveal your internal network layout.
- **Filesystem paths.** App-data, catalog, capture-output, and calibration
  paths are logged on errors and during setup. On most platforms these paths
  embed your **OS username** (e.g. `/home/<user>/...`, `C:\Users\<user>\...`).
- **Device identifiers.** Camera/mount/focuser names, serials, COM ports, and
  Alpaca/INDI host:port addresses appear in discovery and connection logs.
- **Equipment and target metadata.** Object names, RA/Dec, sequence and
  project names — generally not sensitive, but they describe what and where you
  were imaging.
- **Auth-token *digests* and redacted prefixes.** The server logs a token's
  SHA-256 digest or a `abcd...wxyz` redacted form for correlation. These are
  not the secret itself, but they identify a session.

What logs should **never** contain (and, where the code is the source of the
value, do not):

- Raw bearer / pairing tokens in the persisted log.
- Notification or push credentials (FCM/APNs registration tokens, etc.).
- Passwords or API keys.

> Note on scope: Skotiq's push notifications use the platform FCM/APNs
> channels, so there are **no** Pushover/Discord/webhook URLs or third-party
> API keys stored or logged by this build. If such integrations are added
> later, their secrets fall under the redaction rules below.

---

## Redaction rules (policy)

These are the rules the project holds itself to. Each is marked **Enforced**
(the code honors it today) or **Aspirational** (the policy, not yet uniformly
guaranteed in code).

1. **Tokens, pairing codes, and session secrets must never be written to a
   persisted log in plaintext.** — *Enforced.* The structured log records only
   a redacted form (`redactBearer`: first 4 + last 4, middle masked; fully
   masked for short tokens) or a SHA-256 digest. The raw auto-generated token
   is printed **once to stdout** for the operator to copy, with an explicit
   comment that persisting it to the log file would be a security defect.
   Request context carries only the token *digest*, never the raw value, so a
   handler that dumps `request.context` cannot leak it.

2. **Notification / push credentials, API keys, and passwords must never be
   logged.** — *Enforced by absence.* No code path logs these; failures around
   push delivery log only the error, not the token. There is no
   webhook/Pushover/API-key surface in this build.

3. **Observer coordinates are sensitive and must be omitted or coarsened in
   anything shareable.** — *Partially enforced.* The weather API handler log
   lines now coarsen lat/lon to ~one decimal place (~11 km). This is not yet a
   global guarantee — other components may log finer coordinates, and API
   *response bodies* (not logs) still return full precision by design.

4. **Local network details (LAN IPs, hostnames) are sensitive.** — *Aspirational.*
   The startup banner intentionally prints the connect URL (including LAN IP)
   to stdout so an operator can configure a client; this is useful but should
   be scrubbed before sharing. There is no automatic coarsening of IPs in logs.

5. **Filesystem paths embed usernames.** — *Aspirational.* Paths are logged
   verbatim. Scrub the username before sharing.

6. **Device text is sanitized before display/logging.** — *Enforced (control
   chars only).* `_sanitizeDeviceText` strips control characters (CR/LF/tab)
   and collapses whitespace from device names/descriptions so a serial driver
   answering with raw `\r\n` can't inject broken multi-line entries. This is a
   correctness/anti-injection measure, not a privacy redaction — the device
   name and serial are preserved.

---

## Before you share logs (user checklist)

When attaching a log to a public GitHub issue (the **Bug report** or
**Hardware report** templates) or any public channel, scrub these first. A
quick find-and-replace covers most of it:

- [ ] **Coordinates.** Search for your latitude/longitude and your town name.
      Replace with `[REDACTED]` or a rough region ("~45N, central Europe") if
      location is relevant to the bug.
- [ ] **LAN IPs and hostnames.** Replace `192.168.x.x`, `10.x.x.x`,
      `your-pi.local`, etc. The connect-URL banner and any Alpaca/INDI
      `host:port` lines are the usual offenders. (The bug template's example
      field literally shows `192.168.1.50:11111` — don't paste your real one.)
- [ ] **Username in paths.** Replace `/home/<you>/`, `/Users/<you>/`,
      `C:\Users\<you>\` with `/home/USER/` etc.
- [ ] **Tokens / pairing codes.** You shouldn't see a full token in a persisted
      log, but if you captured **stdout** from a first run it contains the raw
      auto-generated token and pairing code — remove those lines entirely.
- [ ] **Device serials**, if you'd rather not publish them (optional; usually
      harmless).

If in doubt, attach only the lines around the error rather than a full
multi-day log file.

---

## For developers

- **Never `log(token)`.** Route any token, pairing code, or session secret
  through `redactBearer` (in `headless_api/request_context.dart`) or log its
  digest. Pass only the digest through `request.context`
  (`authIdentityContextKey`) — never the raw value.
- **Never log push/notification credentials, API keys, or passwords** at any
  level, including in caught-exception strings. Log the error, not the payload.
- **Coarsen coordinates before logging.** Don't interpolate raw site
  `lat`/`lon` into a log line. Round to ~1 decimal place (see `_coarseCoord`
  in `headless_api/handlers/weather_handlers.dart`) when the value is needed
  for debugging; omit it otherwise. The API response can still carry full
  precision — the restriction is on the *log copy*.
- **Use the device-text sanitizer** (`_sanitizeDeviceText`) for any wire-sourced
  device name/description before it reaches a log or a UI surface, so a driver
  can't inject control characters.
- **Assume logs are shareable.** Anyone debugging will paste them into an
  issue. Write log lines so that the default output is safe to share, and put
  anything that must reveal a secret (e.g. the one-time token) on **transient
  stdout**, never in the persisted structured log.
- **Auth-gate any new log/diagnostic endpoint.** New routes are write/view
  scope by default; do not add a log-exposing path to the `publicPaths`
  allow-list in `headless_api_server/http_middleware.dart`.

---

## Known gaps (flagged for follow-up)

- Coordinate coarsening is applied at the weather-handler log lines only; a
  repo-wide audit for other coordinate log sites has not been done.
- LAN IPs, hostnames, and username-bearing filesystem paths are logged
  verbatim — there is no automatic redaction layer. The user checklist above
  is the current mitigation.
- There is no one-click "scrubbed support bundle" export. Log download and tail
  ship the raw file/stream; scrubbing is manual.
