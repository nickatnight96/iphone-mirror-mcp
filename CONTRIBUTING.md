# Contributing

Thanks for looking. This project automates a surface Apple does not document,
so a lot of what matters here is *evidence* — what you observed on a real
machine, not what should work in principle.

## Getting set up

```sh
git clone https://github.com/nickatnight96/iphone-mirror-mcp.git
cd iphone-mirror-mcp
swift build
scripts/run_tests.sh
```

You need macOS 15+ and Xcode. For anything touching the mirroring path you
also need a paired iPhone and the Accessibility + Screen Recording
permissions — see [docs/getting-started.md](docs/getting-started.md).

## Running the tests

```sh
scripts/run_tests.sh                    # what CI runs
MIRROR_MCP_LIVE=1 scripts/run_tests.sh  # + tests needing a live session
```

The live suite is gated because several mechanisms — AX focus, event delivery,
the run-loop-dependent APIs — behave differently in a test runner than in the
real server process. **If you change anything in the input or capture path,
run the live suite and say so in the PR.** CI cannot run it: a runner has no
iPhone and no TCC grants.

To run live tests you need the session *connected*, which means the phone
locked and nearby. They skip cleanly otherwise rather than failing.

## Expectations for a change

**Every change ships with a test.** That is the house rule. Unit-test the
logic, and if the change touches a real-hardware seam, add or extend a live
test too — this codebase's recurring defect is code that reads correctly but
that nothing on the running path ever executes.

A test that would pass with the fix reverted is not a test. Check by actually
reverting it.

**Regenerate the tool docs if you touch the catalog:**

```sh
scripts/generate_tool_docs.py
```

`docs/tools.md` is generated from the server's live `tools/list` output, and
CI fails if it is stale — so a tool cannot ship undocumented.

**Every tool parameter needs a description.** Schema descriptions are the only
documentation a model gets at call time, and weaker models depend on them
most. There is a test enforcing this.

## Style

Match the surrounding code. A few conventions worth knowing:

- Comments explain *why*, especially where the platform behaves surprisingly.
  The AX and CGEvent workarounds in `MirrorCore` are load-bearing knowledge —
  if you discover a new one, write down how you found out.
- `MirrorCore` must not know about MCP; `MirrorServer` must not know about
  CGEvent. That split is what keeps the logic testable without hardware.
- Errors are for the model to read. "Parameter x must be a number" beats a
  stack trace.
- Never trap on caller-controlled input. `Int(someDouble)` traps on non-finite
  values and one trap kills the whole stdio server.

## Reporting a bug

Include the output of `iphone-mirror-mcp doctor`, your `sw_vers`, the tool
call you made, what came back, and what you expected. See
[docs/troubleshooting.md](docs/troubleshooting.md#filing-a-good-issue).

Please do not file security issues publicly — see [SECURITY.md](SECURITY.md).

## Adding a tool

1. Register it in `MirroringTools.swift` or `XcodeToolCatalog.swift`.
2. Give every parameter a `description`.
3. Add tests; extend `ToolCatalogTests` if it needs new catalog invariants.
4. Run `scripts/generate_tool_docs.py`.
5. Mention it in the README table if it is user-facing.

Mirroring tools are serialized FIFO — they share one cursor and one window, so
interleaving corrupts them. Xcode and simulator tools run concurrently. Put
new tools on the right side of that line.

## Cutting a release

1. Bump `version` in `Sources/MirrorServer/MirrorMCPServer.swift`.
2. Update `CHANGELOG.md`.
3. `scripts/run_tests.sh` — this checks the version agrees across the binary,
   `server.json`, and the package URL.
4. Commit, then tag: `git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z`.
   The release workflow builds the universal bundle and publishes it.
5. **After the release exists**, sync the checksum:

   ```sh
   scripts/build_mcpb.sh --from-release vX.Y.Z
   git commit -am "Record the vX.Y.Z bundle checksum"
   ```

   Step 5 is not optional and cannot be done earlier. A locally built bundle is
   not byte-identical to CI's, and MCP clients verify `fileSha256` before
   installing — advertising the wrong hash fails every bundle install.
