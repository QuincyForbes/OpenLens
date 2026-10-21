# V2 compaction model selection

Checked 2026-10-15 using official upstream source: pinned `v2.0.23` compaction/model resolver/config schemas and current `v2` built-in agent/context loader. No live server configuration or session was inspected, and no app code changed.

## Selection and failure

- Compaction does not hardcode GPT-5.4. For ordinary summarization it tries the optional `compaction` agent's model, falling back to the loaded session model. If that override cannot be resolved, its resolution error is swallowed and the session model is used. Native provider compaction bypasses the separate compaction agent entirely. [Pinned implementation, lines 194–213](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/compaction.ts#L194-L213).
- The current built-in Compaction agent only sets its name, mode and visibility; it has no default model reference. [Current built-in agent, lines 109–113](https://github.com/anomalyco/opencode/blob/v2/packages/core/src/plugin/agent.ts#L109-L113).
- Exact `Model unavailable: provider/model` comes from resolving a session's explicit model against the location's available model catalog. It means that provider/model pair is absent from that catalog. [Pinned resolver, lines 17–27 and 69–84](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/runner/model.ts#L69-L84).
- Context loading resolves the session model before it returns the loaded context consumed by compaction. [Current loader, lines 152–166](https://github.com/anomalyco/opencode/blob/v2/packages/core/src/session/context.ts#L152-L166). Therefore, for this exact error in the checked implementation, an unavailable session model is a stronger explanation than an unavailable compaction override. The latter would fall back. A running server at another version or a plugin may behave differently; the user's precise provider/model/error payload is not yet known.

## Configuration syntax, if a separate summarizer is intended

Canonical V2 uses plural `agents`; each agent supports an optional `model`. [Pinned config schema](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/config.ts#L54-L56), [agent schema](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/config/agent.ts#L9-L19). A model selection accepts `provider/model` or an object with `providerID` and `model`. [Current model-selection schema](https://github.com/anomalyco/opencode/blob/v2/packages/schema/src/config/model.ts#L10-L24).

```json
{
  "agents": {
    "compaction": {
      "model": "YOUR_PROVIDER/YOUR_AVAILABLE_MODEL"
    }
  }
}
```

This is a verified structural example with placeholders, not a claim about any installed model. It does not repair an unavailable session model, because that model must resolve before compaction begins. Legacy singular `agent` is normalized into `agents`; canonical V2 values have precedence on conflicts. [Pinned normalizer, lines 124–157](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/config/normalize.ts#L124-L157).

The published V2 compaction docs describe the normal session-model path. The optional override above is visible in source and is bypassed for native compaction, so do not assume every server/version honors it identically or recommend it as the first fix for this specific error.
