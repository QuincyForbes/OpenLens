# What each completed ticket enables

What you can do in OpenLens once each ticket is done. Add an entry here when a ticket is marked done.

## 01: Preserve canonical V2 session model, variant, and agent

Commits: `dfdaf23`, marked done in `830c344`.

- When you open or reopen a session, the phone shows the model, reasoning variant and agent the server is actually using. This also works for a new session with no assistant reply yet.
- If you switch model, variant or agent on the desktop, an ordinary prompt from the phone keeps that choice instead of overwriting it.
- If you change a setting on the phone, the server applies it before your next prompt is sent. If the change fails, the prompt isn't sent with the wrong settings.
- Defaults for new sessions stay separate from the settings of existing sessions.

## 02: Confirm V2 prompt admission and retry without duplicate work

Commits: `47d707d`, `14d26dc`, marked done in `2b73675`.

- Each prompt shows whether it is being sent, was accepted, couldn't be confirmed, or failed.
- On a flaky network, a prompt whose response was lost shows "Not confirmed" and returns to the composer. Sending it unchanged is safe: the server never runs it twice or shows it twice.
- A timeout is no longer reported as the server rejecting your prompt, and your input is kept.
- Normal, queued and steering prompts all go through the same confirmed flow.

## 03: Restore the shared V2 session inbox after reconnecting

Commits: `add6e64`, including the ticket's done status.

- When you reopen a session, return to the app, or reconnect after a stream gap, the phone restores pending work accepted by the server, including prompts sent from another client.
- The queue distinguishes prompts still being submitted from accepted work. User prompts, automatic messages, compaction and session moves retain their useful labels, delivery mode and queue position; files attached elsewhere stay visible by name.
- Steering entries appear before queued work. Steered compaction appears before earlier steers when the server gives it priority, while respecting a pending session move.
- When another client admits or cancels work, changes its delivery mode, or the server delivers it, the phone refreshes the same queue. Already delivered entries are not repeated, and separate server entries remain visible even when their text is identical.
- If the queue cannot be recovered, the session is not shown as synchronized. A successful recovery retry restores the queue and clears the recovery error.
- Pending external work survives resetting the open chat. Finishing a reply on the phone does not prematurely promote the next V2 queue entry into the transcript.

Verified with 507 passing simulator tests and a [shared inbox screenshot](screenshots/03-shared-v2-session-inbox.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server run remains unverified.

## 04: Cancel pending V2 prompts and promote queue to steer

Commits: `5d7ee85`, including the ticket's done status.

- From an accepted user prompt's actions menu, you can cancel pending work, including prompts sent from another client.
- You can promote a queued prompt to "Steer at next step" using its existing server identity. The phone does not resend its text as a new prompt.
- After either action, the phone refreshes the shared queue and transcript. If a response is lost, recovered server state can confirm the change. A prompt delivered during the action appears in history instead of remaining in the queue.
- Failed actions leave pending work available to retry. Duplicate taps are blocked while an action is in progress, and a delayed result from the previous session cannot change the newly opened session.
- Stopping the active reply preserves remaining pending work. Pending user prompts have individually accessible menus; automatic messages, compaction and session moves keep their existing presentation.

Verified with 519 passing simulator tests, separate standards/spec reviews, and simulator use of both actions against a local V2 fixture. Screenshots show the [actions menu](screenshots/04-pending-prompt-actions.png) and [the queue after promotion](screenshots/04-promoted-prompt.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server run remains unverified.

## 06: Show authoritative V2 execution outcomes

Commits: `c345d35`, corrected after review in `78e5e40`, including the ticket's done status.

- Session rows and the open chat show whether the server's last execution succeeded, failed or was interrupted, along with when it ended.
- Active work, waiting for permission and waiting for a form response have their own chat status. A completed assistant step keeps the session working while server execution continues.
- If execution disappears from the active list without a confirmed result and idle timestamp, the chat shows “Outcome unavailable.” It also prevents an older success from being reused for a newly observed run or published as a successful Live Activity completion.
- Returning to the app, reconnecting after a stream gap and receiving execution events restore the canonical result. A delayed response from a previous chat cannot change the newly opened session.
- Session rows reread the server's result when a run ends, when the list returns or foregrounds, and when you change the selected chat in the iPad sidebar. A failed result read keeps the row visible with “Outcome unavailable” and retries; a failed status fetch retains the last known active statuses.
- If another client answers a permission or form and the run ends before the phone clears the request, the Live Activity still ends with the canonical result or is dismissed when the result is unavailable. Malformed advisory outcome/idle fields leave the session visible with unavailable evidence.

Verified after review with 525 passing tests in 56 suites on the dedicated AFK simulator on 2026-10-09. Screenshots show [session outcomes](screenshots/06-session-outcomes.png), [a freshly recovered result](screenshots/06-refreshed-session-outcomes.png), [a failed result read](screenshots/06-failed-outcome-refresh.png), [successful execution](screenshots/06-chat-succeeded.png), [failed execution](screenshots/06-chat-failed.png), [interruption](screenshots/06-chat-interrupted.png), [active work](screenshots/06-chat-working.png), [permission waiting](screenshots/06-chat-permission.png), [form waiting](screenshots/06-chat-form.png), and [unavailable outcome evidence](screenshots/06-chat-unknown.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server session, physical-device Live Activity run, and manual iPad selection exercise remain unverified; the selection recovery is covered at the service boundary.

## 07: Mark newly completed V2 session results as unread

Commits: `dc47a29`, corrected after AFK reviews in `c19246a` and `00abfff`, including the ticket's done status.

- Completed V2 results show an Unread badge until the server confirms that completion was viewed. Active work keeps its working indicator; changing a title does not make a result unread.
- Opening a synchronized chat in the foreground acknowledges the displayed completion. Each newer completion you watch in that chat also gets acknowledged, with one request in flight and the latest displayed marker next. An older request cannot mark an unseen newer completion read.
- Switching to Workspace or Review stops viewing observation, even while the app stays in the foreground. Returning to the on-screen chat restarts a cancelled acknowledgement without requiring its session to change.
- A lost response is checked against canonical server state. Re-syncing the transcript preserves an in-flight acknowledgement. If viewing cannot be confirmed, the result stays unread and the chat offers Try Again, even if another operation also fails. Confirmed retry or later confirmation clears the viewing error.
- Confirmed viewing immediately clears the matching list/sidebar badge, including while the chat stays open. An older poll cannot restore it, and a delayed acknowledgement cannot replace a newer result or change a different chat.
- Refreshing or returning to the list restores shared desktop/phone read markers. Every 30 seconds while the foreground V2 list stays visible, only unread inactive rows reread their markers, with at most four concurrent requests. A failed attention read preserves the result and waits for another attention refresh. Desktop viewing events recover only session info without reloading the open chat's transcript, inbox, permissions or forms.
- If refresh discovers a newer completion still unread on the server, its newer idle marker replaces the stale row before merging read markers, so an older viewed result cannot hide it. Send and other operation errors show with Dismiss ahead of a viewing error; dismissing them reveals its retained Try Again action.
- V1 behavior and chat tab bar hiding are preserved.

Verified after the second review with **582 passing tests in 59 suites** on the dedicated AFK simulator on 2026-10-09. Ticket 07 now has 26 Swift Testing tests, including hosted sequential completions, re-sync during POST/canonical reread, hidden-tab foreground recovery and return after cancellation, typed error priority/dismissal/retry, immediate row marker propagation, stale idle/polls, a 200-read-row refresh exclusion and marker-only event request checks. Screenshots show [unread results](screenshots/07-unread-results.png), [viewed results](screenshots/07-viewed-results.png), [unconfirmed viewing with retry](screenshots/07-view-acknowledgement-failed.png), and [a send error with Dismiss while viewing is also unconfirmed](screenshots/07-send-and-view-acknowledgement-failed.png); both error screenshots were captured from the second-review build. This supersedes the original 572-test and first-review 578-test verification and once-per-visit policy. The suspected hidden-tab regression did not reproduce before the explicit visibility guard on this simulator; both tab directions now have hosted coverage. Live two-client server/device behavior and manual iPad/poll-timer interaction remain unverified; transport, row merging, refresh selection and foreground/on-screen chat behavior are covered with injected fixtures. Remote and its gateway were removed in `77b72ac`.

## 08: Rebind an open V2 session after its location changes

Commits: `8fee5d0`, corrected after AFK review in `2dba41c`, with post-commit cancellation and queued-command recovery fixed in `b3ac488`, including the ticket's done status.

- When another client moves your open session, the phone rereads its canonical location and restores the new project, branch, model catalog, commands, skills and files. Your conversation, typed draft and inline phone attachments stay with the session.
- Location-dependent requests use the restored directory. Prompts retain the same server session ID; the server owns their execution location. Successful recovery clears old repository attachment references and composer selections and resets the Workspace browser to the new root. Obsolete responses cannot replace the recovered chat or workspace.
- Move events can reach the open chat from either directory; another session's move is ignored. Canonical recovery and explicit session loading follow the latest location. Returning to an already loaded chat destination preserves its current binding and respects a refused handoff instead of restoring a stale navigation value.
- An SSE reconnect during project metadata recovery still completes attachment cleanup and model reload. Moving back to the original directory while another catalog is loading also restores the correct models.
- If the server refuses the new location or canonical recovery fails after a known move, the chat keeps your draft and conversation, shows an explicit error with Try Again, and blocks new work until recovery succeeds. It never starts using an event's unverified destination.
- Cancelling a handoff leaves an explicit retry state. Try Again restores project name, current project, branch and models even when the new directory had already committed before cancellation. During a failed handoff the header shows the bound project and branch, with the requested destination explained in the error.
- If a move interrupts work waiting to be sent, the phone restores unsent prompt or command text and inline phone files, drops stale repository references from restored attachments, and asks you to review and retry. It does not automatically forward that work. An interrupted queued command leaves the existing response generating, keeps loading active and preserves its Live Activity.
- This observes moves initiated elsewhere. Initiating a move from the phone remains ticket 22.

Verified after both reviews with 546 passing tests in 57 suites on the dedicated AFK simulator on 2026-10-09. Ticket 08 has 20 tests with 59 cases, including real SSE parsing/filter/reconnect callbacks over an injected stream transport, navigation restoration, cancelled recovery (including nine post-commit metadata/model cancellation cases), and ten settings-wait/send cases that also assert active response and Live Activity preservation for queued work. Screenshots show [the rebound chat and command catalog](screenshots/08-rebound-chat.png), [the restored Workspace project and branch](screenshots/08-rebound-files.png), [a refused rebind with its bound header and retry](screenshots/08-rebind-failed.png), [restored unsent text and an inline phone file](screenshots/08-unsent-move.png), and [a restored queued command alongside the running response](screenshots/08-queued-command-move.png). This supersedes the original 538-test completion claims and the earlier 545-test repair verification. A live V2 server/two-device move or prompt execution and manual iPad navigation remain unverified; raw stream behavior and the navigation service helper are covered through injected transports. Remote and its gateway were removed in `77b72ac`, so this follows the current direct-connection scope.

## 09: Show running and completed V2 subagent tools

Commits: `7e179e6`, including the ticket's done status, corrected after review in `c030ad8`.

- Legacy `task` tools and V2 `subagent` tools show the same delegated-work cards in streamed and reopened conversations.
- Cards preserve child state reported by tool progress/results. A successful background launch shows Working after the parent's reply ends. Done applies when completion is reported in the tool result itself; failed calls show Error.
- Background cards do not follow later child completion yet. With only launch-time running evidence they remain Working, including the shimmer and after reopening history, even once the child finishes. Ticket 11 must deliver the later synthetic result.
- A launch with a known tool state shows a Subagent card before its agent or task details arrive. Its Working label remains visible even without a detail line. An unknown tool status without useful details stays hidden instead of inventing a Working card.
- Unknown or malformed child metadata leaves the tool and transcript readable. Supported status values and validated child-session identifiers survive stream safety preparation; unsafe identifiers are dropped rather than shortened or used as session links.
- Permissions and forms from linked children retain their owning session. Unrelated requests and links from a previous parent do not become requests for the newly opened chat.
- Later delivery of synthetic background results remains ticket 11; opening child conversations remains ticket 23.

Verified after review with 556 passing tests in 58 suites on the dedicated AFK simulator on 2026-10-09, including parent-turn completion followed by child permissions/forms and malformed native V2 progress/success metadata. Screenshots show [Working, Done and Error cards](screenshots/09-subagent-tools.png), [a launch before input arrives](screenshots/09-subagent-pending.png), and [an unknown status without an invented Working card](screenshots/09-subagent-unknown.png), with the chat tab bar hidden. No live V2 server/two-device run, physical-device run or manual iPad navigation was performed. Remote and its gateway were removed in `77b72ac`, so this follows the current direct-connection scope.

## 13: Send screenshots and supported photos in V2 prompts

Commits: `c685bb2`, marked done in `b61ed5a`.

- From the composer you can attach photos and screenshots (PNG, JPEG, GIF, WebP and HEIC), preview them, remove them, and send them with your prompt.
- HEIC and other iOS formats are converted to formats the server accepts, and large images are resized to fit the request limit.
- If the selected model doesn't accept images, or the attachments are too large, you get a clear error before anything is sent.
- Images you send, and images from the desktop or from history, stay visible in the chat.
- Not yet verified: a live model receiving the image, both directly and through Remote.

## 14: Attach text files and repository line references

Commits: `bf3136c`, marked done in `13b7293`.

- **Text files from the phone:** use Attach → Files to add UTF-8 text, Markdown or source files. Tap a chip to preview the file, remove it, and send it with your prompt.
- **Repository files:** use Attach → Repository File to browse the session's folder on the computer. Pick a file and optionally a line range, like "lines 12–20" or "from line 5 to the end", so the agent reads just that part from the server.
- Phone files and server files are kept separate. A file outside the session's folder, a phone path or a web URL can't be referenced.
- Attachments still show up correctly after a retry or a history reload.
- Errors say what went wrong:
  - a binary file
  - an oversized file
  - a file that couldn't be read
  - an invalid line range
  - a range past the end of the file
  - the server rejecting a file
- **Through OpenLens Remote:** prompts and commands can only reference files inside the session's approved folder. Requests that try to get around this check are refused.
- Limitations:
  - A prompt still needs text.
  - Repository file chips can only be previewed in the picker.

## 15: Display supported files returned by V2 tools

Commits: `dbc37f0`, marked done in `cb1a25c`.

- **Files from tools:** when a tool returns a file, such as a screenshot from read, an MCP or browser tool image, a text file or a PDF, it now appears under that tool's row in the chat.
  - Images show as thumbnails.
  - Text and PDF files show as chips.
  - Tap either to open a preview.
- **Failed tools:** a failed tool still shows the output it produced before the error ("Output before the error:") and any files it returned.
- **Files that can't be shown** stay listed, with the reason:
  - "Too large to show here"
  - "No preview" for an unsupported type
  - unavailable, for a web URL
  - "N more files not shown" for files past the per-tool limit
- **Through OpenLens Remote:** a large tool image no longer breaks the event stream or a history page. Direct and Remote connections show the same files.
- Limitations:
  - Withheld files can't be fetched on demand.
  - Server files open only inside the session folder, up to 8 MiB.

## 10: Preserve useful V2 context changes in the timeline

Commit: `f6e020b`, including the ticket's done status.

- Your conversation now shows model, agent and location changes, system updates and activated skills in their original position, as compact context rows.
- You can expand rows to read previous selections/location, system instructions and skill text. Saved shell results expose output and exit codes; compaction rows expose the saved summary, recent context and failure details.
- Idle entries show where an execution succeeded, failed or was interrupted. Unknown outcomes keep a neutral completion label.
- Refreshing, reconnecting and receiving context changes from the desktop restore the same ordered history without duplicate rows. Overlapping pages retain the latest record in its original position, and unknown entry kinds leave the rest of history usable.
- Load earlier history restores older context alongside messages and tool results. A staged revert hides both at the same canonical boundary. Existing V1 chat and chat tab bar hiding remain available.

Verified with **590 passing tests in 60 suites** on the dedicated AFK simulator on 2026-10-09. Screenshots show [context changes](screenshots/10-context-changes.png), [compact results alongside a reply](screenshots/10-context-results.png), and [expanded shell/compaction details](screenshots/10-context-details.png). Live two-client server and physical-device behavior remain unverified; injected transport/native-event tests and simulator captures cover the implemented behavior. Per-token compaction summary updates, compaction admission, active-context inspection, shell output paging/PTY and synthetic background-child delivery remain outside this ticket. Remote and its gateway were removed in `77b72ac`.
