# Security

## What this software can do

While a mirroring session is active, this server can **see and control
whatever iPhone the Mac is paired with**: read the screen, tap anything, type
anything, open any app. Messages, mail, photos, banking apps — all of it.

Treat running it like handing your unlocked phone to whoever is on the other
end of the model. That is not a flaw; it is the feature. But it means the
trust boundary is the *client*, not this server.

## The trust model

- **The model can do anything the mode allows, and in `full` that is
  anything you could do on the phone.** `--mode` is the only allowlist:
  `read` (the default) lists 15 tools that observe, `input` adds the 19 that
  send taps and keys, `full` adds the rest. A hidden tool is absent from
  `tools/list` and answers "Unknown tool"; the mode is fixed at launch and a
  model cannot change it. Every tool carries MCP annotations (`readOnlyHint`,
  `destructiveHint`, `idempotentHint`, `openWorldHint`); clients may use them
  for confirmation prompts, but they are hints, not enforcement. There is no
  sandbox and no per-tool permission prompt in the server itself. Run it only
  from clients you trust with that access.
- **macOS permissions belong to the launching app.** Granting Accessibility
  and Screen Recording to your terminal or desktop client grants them for
  everything that app runs, not just this server.
- **The phone is the kill switch.** Picking up or unlocking the iPhone pauses
  the session immediately, and resuming requires it locked again. That is a
  genuine physical control and the server does not override it: it clicks
  Resume only on an idle pause whose button is labeled Resume, and only when
  an input tool runs. Read tools never click, so an idle pause is resumed
  only by an input tool. It never clicks past "iPhone in Use" or an overlay it
  cannot read. Once it has seen such a pause, or a labeled Resume press that
  does not take, it refuses all input, `mirror_launch`, `mirror_restart`,
  `notification_click` and `batch` until a person resumes the session or the
  server restarts.
- **Prompt injection reaches the phone.** Content the model reads off the
  screen — a message, an email, a web page — is untrusted input that could try
  to steer subsequent actions. This matters more here than in most MCP servers
  because the actions are real taps on a real device.
- **The clipboard is touched.** `paste_text` briefly places text on the *Mac*
  clipboard and restores the previous contents; `read_clipboard` reads it.
- **Screenshots and recordings are real data.** They may contain anything on
  the phone at that moment. Recordings are written to disk where you point
  them.

## What it does not do

- No network calls of its own. It talks stdio to your client and shells out to
  Apple's tools (`xcodebuild`, `devicectl`, `simctl`, `open`).
- No telemetry, no analytics, no data collection.
- No credentials, tokens, or API keys — it has nothing to leak.
- Nothing is installed on the iPhone.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting — the **Security** tab → **Report a
vulnerability** — on
https://github.com/nickatnight96/iphone-mirror-mcp/security/advisories/new

Include what you observed, how to reproduce it, and the impact. Expect an
acknowledgement within a week. This is a personal project maintained in spare
time; there is no formal SLA, but real issues will be taken seriously and
credited unless you prefer otherwise.

## Scope

In scope: anything that lets a caller escape the intended tool surface, or
that exposes data beyond what the tools are documented to return.

Out of scope: the fact that the server can control the phone (that is the
point), and anything requiring physical access to an unlocked Mac.
