---
name: handoff
description: Write HANDOFF.md so the next session can pick up FastGlance work cold — what changed, what's verified, what's next. Use when the user types /handoff or asks to wrap up / hand off the session.
---

# /handoff

Update `HANDOFF.md` in the repo root so a fresh session can continue without this conversation.

## Steps

1. Gather facts, don't recall them:
   - `git log --oneline -15` and `git status --short` (uncommitted work must be named).
   - Read the current `HANDOFF.md` and keep anything still true; delete what's stale.
   - Run the tests if code changed since the last handoff:
     `xcodegen generate -q && xcodebuild -project FastGlance.xcodeproj -scheme FastGlance -derivedDataPath build test 2>&1 | grep -E "error:|Test Case.*failed|TEST (SUCCEEDED|FAILED)"`
2. Rewrite `HANDOFF.md` with exactly these sections, short bullets, no prose padding:
   - **Updated** — today's date and the last commit hash.
   - **State** — what works now, in one or two lines per feature area touched this session.
   - **Verified** — what was actually checked, and how (test, render, real hardware, history.json).
   - **Not verified** — what still needs real hardware or the user's eyes, with the exact check to run.
   - **Next** — the agreed next steps in priority order, and anything the user declined (so it isn't re-proposed).
   - **Gotchas** — new traps found this session (API quirks, numbering, signing). Long-lived ones belong in `CLAUDE.md` instead.
   - **Open questions** — decisions waiting on the user.
3. Keep it under ~80 lines. Facts only; mark guesses as guesses.
4. `HANDOFF.md` is gitignored (personal session state). If a gotcha is permanent, add it to `CLAUDE.md` and commit that.
5. Tell the user in one or two lines (in their language) that the handoff is written and what the top "Next" item is.
