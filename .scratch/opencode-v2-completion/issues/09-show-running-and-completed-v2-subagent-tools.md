# 09: Show running and completed V2 subagent tools

**What to build:** Identify delegated work across V1 task tools and V2 subagent tools and preserve the actual child execution state.

**Blocked by:** None (can start immediately).

**Status:** done

**Priority:** P1

- [x] Both legacy task and released V2 subagent names produce the existing delegated-work presentation.
- [x] Validated session identifiers and supported status metadata survive safety preparation.
- [x] A successful tool launch with running child metadata remains marked as running.
- [x] Unknown or malformed metadata safely degrades without invalidating the tool or transcript.
- [x] Existing permission/form relationships remain tied to the correct child session.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services. Remote isolation is no longer applicable after `77b72ac`.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.

**Verification:**

- Added eight `V2SubagentToolTests` in Swift Testing. History tests use `MessagesService` and the production `OpenCodeClient` with an injected contract transport. Stream tests use `V2EventAdapter`, production `SSEInboundEvent` safety preparation and `SSEEventHandler` with observable `ChatClient` state. Coverage includes both tool names, successful background launches staying Working after the parent message ends, completed children, failed calls overriding stale running metadata, all three existing child-session aliases, unknown/malformed metadata, unsafe/oversized identifiers, and launches before input arrives. Child permission/form requests retain their owning session after progress and successful launch; unrelated requests and links from a previous parent are ignored. Existing V1 stream, permission, form-route and tab-bar tests also pass.
- Test-first runs reproduced the missing `subagent` card (`build/afk-logs/20261009-110911-tests-1.log`), falsely completed background launches (`build/afk-logs/20261009-111026-tests-1.log`), and the missing delegated-work row before input arrives (`build/afk-logs/20261009-111120-tests-1.log`). Each was corrected before continuing; the final focused run passed all eight new tests.
- Ran `/Users/example/Developer/afk-agent/runs/20261009-0950/bin/verify` after all implementation, fixture and layout changes. **VERIFY RESULT: PASS** — all **554 tests in 58 suites passed on 2026-10-09**, with no failures or skips, on dedicated AFK simulator `C25B01FF-5F58-4572-BD98-548790F43A2C`. Final log/result bundle: `build/afk-logs/20261009-111524-tests-1.log` and `build/afk-logs/20261009-111524-tests-1.xcresult`. `git diff --check` passed. The branch remains `afk/20261009-0950`.
- Extended stable screenshot fixtures and captured/visually inspected the final verified build: [legacy task and V2 subagent Working, Done and Error cards](../screenshots/09-subagent-tools.png), and [a pending subagent launch before input arrives](../screenshots/09-subagent-pending.png). Reproduce with `SCREENSHOT_MODE SCREENSHOT_TAB=chat SCREENSHOT_CHAT_SESSION SCREENSHOT_SUBAGENT_TOOLS`; add `SCREENSHOT_SUBAGENT_PENDING` for the second capture. Both retain the hidden chat tab bar. These fixtures exercise the production activity projection; history and event behavior is verified by the tests above.
- The first pending-launch capture exposed a compressed-away Working label when there was no detail line. Preserved the status label's intrinsic width, repeated full verification and recaptured both screenshots. The layout correction is screenshot-verified; Swift Testing covers the underlying pending/active state.
- Decisions: follow the pinned [V2 2.0.23 subagent contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/tool/plugin/subagent.ts). Preserve only supported child `status` strings (`running`, `completed`) and use them independently of tool-call completion. A failed tool call remains Error even if advisory metadata still says running. Unknown or malformed child status falls back to the existing tool state rather than rejecting a tool/message. Keep a generic Subagent card when a recognized launch has not yet supplied input. Retain child identifiers unchanged only when they fit the existing form-route identifier validation and 256-byte limit; invalid identity fields are dropped without discarding independent valid status evidence. Preserve the existing `sessionID`, `sessionId`, and `session_id` relationships without new navigation or service layers.
- Confirmed `1dfb5aa` is an ancestor. Remote and its gateway were removed in `77b72ac`, making their coverage/isolation criteria inapplicable, consistent with tickets 03/04/06/08. Existing observable services, environment injection, V1 routes and `ConnectedRootView` navigation are retained. No live V2 server, two-device run, physical-device run or manual iPad navigation was performed. Delivery of later synthetic background-child results remains ticket 11; opening child conversations remains ticket 23.
