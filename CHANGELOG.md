# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
