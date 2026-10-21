# V2 active context occupancy

Checked 2026-10-15 against official `anomalyco/opencode` source on the `v2` branch, and compared with the project's recorded `v2.0.23` contract. The TUI formula below was independently confirmed unchanged at the `v2.0.23` tag. This is API/source verification, not a request against the user's running server. The public hosted OpenAPI URL was inaccessible to the web tool; direct network DNS was also unavailable in this environment.

## Finding

The context read API does **not** return a current token count or percentage: `GET /api/session/{sessionID}/context` returns `{ data: PublicSessionMessage[] }`. Therefore `loadActiveContext()` cannot obtain an authoritative occupancy value from that response. [Protocol source, lines 556–565](https://github.com/anomalyco/opencode/blob/v2/packages/protocol/src/groups/session.ts#L556-L565). This agrees with the earlier pinned `v2.0.23` finding in ticket 16.

However, upstream V2 itself **does show a context indicator**. Its TUI derives it from the latest assistant usage after the last completed compaction, restricted to before the revert boundary. It sums input, output, reasoning, cache read and cache write; then divides by the corresponding assistant model's context limit and rounds to a whole percentage. Thus this is a last-request indicator computed by the client, not a new current-projection measurement. [Pinned implementation, lines 41–66](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/tui/src/util/session.ts#L41-L66), [current V2 implementation](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/util/session.ts#L41-L66). The sidebar displays those values as tokens and percent used. [Sidebar, lines 14–28](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/feature-plugins/sidebar/context.tsx#L14-L28).

The server also internally estimates context for compaction. Its estimator anchors to measured provider usage from a recent usable assistant step and estimates subsequent content. That supports treating reply usage as useful evidence of the last request's context, rather than dismissing it as only cumulative historical work. The estimator is not the context endpoint's response field. [Compaction source, lines 798–849](https://github.com/anomalyco/opencode/blob/v2/packages/core/src/session/compaction.ts#L798-L849).

## Consequence for OpenLens

A truthful current-occupancy ring needs an upstream metric or a separate estimate. Restoring an indicator consistent with upstream TUI is possible with the existing assistant token usage and model limit, clearing it after completed compaction and respecting revert boundaries. It should be described as the latest request's usage; changes admitted since that request can make it stale. No app code was changed by this investigation.
