# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

The default changed: with no arguments the server now serves in `read` mode
and lists 15 tools. Existing client configs that only name the binary lose
the input and management tools until `--mode input` or `--mode full` is added
to their args. This is a breaking change and the next release should be
2.0.0.

### Added
- `--mode read|input|full` on `serve`, default `read`. `read` lists the 15
  tools that observe the phone, devices, and simulators; `input` adds the 19
  that send taps, keys, and navigation; `full` lists all 63. A hidden tool is
  absent from `tools/list` and answers "Unknown tool" when called by name.
  The mode is fixed at launch; a model cannot change it. The mcpb bundle
  exposes it as the `mode` user setting.
- Every tool carries MCP annotations: `readOnlyHint` and `idempotentHint` for
  read tools, `destructiveHint` for everything else (a tap can delete
  anything on the phone), `openWorldHint` only for `xcode_build`,
  `xcode_test`, `run_on_iphone` and `run_on_sim`, plus a title.

### Changed
- The server resumes only an idle pause whose overlay shows a button labeled
  Resume (one AX press, then one real click at that button), and only when an
  input tool runs. Read tools never click, so an idle pause is resumed only by
  an input tool. The server never clicks past "iPhone in Use" or an overlay
  with no labeled button, and no longer blind-clicks the window center or the
  65 percent point. After any other pause, or a labeled Resume press that
  does not take, it refuses input, `mirror_launch`, `mirror_restart`,
  `launch_app`, `open_url`, `notification_click` and `batch` until a person
  resumes the session (the server sees `connected` again) or the server
  restarts. Read tools still work and add a note that the session is paused.
- `launch_app` and `open_url` run every keystroke through the same readiness
  check as the standalone input tools.

### Fixed
- `read_clipboard` waits for the pasteboard change count to move after
  Command-C and reports "Nothing was copied" instead of returning the old Mac
  clipboard as if it came from the phone.
- `record_start` no longer hands `screencapture` the MCP stdin and stdout.
- `run_on_iphone` picks the first paired iPhone (not the first devicectl row,
  which could be an iPad, a Watch, or an unpaired phone) and the
  `<scheme>.app` bundle (not the first `.app` in derived data, which could be
  a UI-test runner). Several bundles with no name match is now an error that
  names the candidates.

## [1.0.1] - 2026-08-14

### Changed
- Pointer gestures skip the window-center re-engagement leg when the cursor
  is already inside the mirroring window. The leg absorbs the engagement
  transition played on window *entry*; a cursor that never left is still
  engaged, so it was pure overhead. Measured: warm off-center taps dropped
  from 1.65-1.68s to 1.00s. The entry path is unchanged. (#4)
- Activation polls for frontmost at 25ms instead of sleeping a fixed 300ms
  per stage of its fallback chain.
- ScreenCaptureKit capture retries once after a short backoff — it fails
  transiently under sustained capture load — and a failure of both capture
  engines now reports both causes instead of a bare "couldn't be read".

### Added
- Live tests that prove a flick and a slow drag scroll real content and that
  the session still accepts input afterwards. They gate on the OCR row set
  (calibrated live: real scrolls move 9-11 rows, idle churn 0-3), normalize
  scroll position first, and must run hands-off — they share the real cursor
  with whoever is at the keyboard.
- Documented limitations discovered reviewing Apple's iPhone Mirroring
  surface: cross-device file drag-and-drop (#2) and Live Activities (#3).

## [1.0.0] - 2026-08-13

### Added
- `--version`, `--help`, and a `doctor` subcommand on the binary, so a setup
  can be verified before any MCP client is wired up. Previously the binary
  ignored its arguments entirely and always started a stdio server, which is
  indistinguishable from a hang when run by hand.
- `install.sh` — checks the machine, builds, installs to `~/.local/bin`, runs
  the permission check, and prints ready-to-paste client configuration.
- Documentation site under `docs/`: getting started, per-client configuration,
  a generated tool reference, recipes, troubleshooting, architecture, and
  tested limitations.
- `scripts/generate_tool_docs.py` generates `docs/tools.md` from the server's
  live `tools/list` output; CI fails if it is out of date.
- GitHub Actions CI: build, test, CLI smoke checks, release build, shellcheck.
- Live integration tests that verify a swipe actually scrolls real content and
  that the session still accepts input afterwards.
- MIT license, contributing guide, and security policy.

### Changed
- Rewrote the swipe planner around a trajectory model: a position curve is
  sampled at the frame rate and per-frame deltas are the differences between
  samples, so displacement conservation is structural rather than restored by
  a reconciliation pass. The contact/inertia split for a flick now falls out
  of integrating the velocity profile instead of being a tuned ratio.
- Every tool parameter now has a description (44 were missing). Schema
  descriptions are the only documentation a model sees at call time, and
  weaker models depend on them most. A test enforces this.

### Fixed
- A flick's momentum tail could strand travel past its last frame and emit it
  as a lone unit after a run of dead frames, which reads as a second flick.
  The tail now ends where a frame stops carrying a whole wheel unit.
