# Trial — mutation-gate

**Phase** 4 · **Started** 2026-09-06 (UTC; morning of 2026-09-07 NZ) · **Closed** — open
**Where** `serina-mcfall/agent-verification-kit`, branch `spike/stage4-payload`
**Verdict** — **not yet reached.** Run 1 only. No mechanism exists.

> This file was opened at the measurement spike, before any design, which is what `CHG-0008`
> requires. It is not evidence that anything works. It is evidence about the harness.

---

## What this mechanism is meant to catch

An assertion weakened without changing the assertion count — `assert_eq!(a, 5)` becoming
`assert_eq!(a, a)` — which stage 2 sees as a change and never as a weakening.

**It ships only if it catches that thing at a cost people will tolerate.** Not if it is clever.

---

## What was observed LIVE

### Run 1 — the measurement spike, BEFORE the design exists

| | |
|---|---|
| What was measured | What the harness sends on `PreToolUse`, `PostToolUse`, `PostToolUseFailure` for `Bash`, `Edit` and `Write` — and separately, which hook output channel reaches a human |
| How | A throwaway plugin (`stage4-spike`) installed from a **local directory marketplace** in the session scratchpad, never in the repository. Two hooks: one dumping every payload verbatim to `payloads.jsonl`, one emitting probe strings. 65 payloads captured across 3 probe rounds |
| Reader | Shape-not-values by default. A raw payload carries whatever the tool call carried, so the reader prints key paths and types; values only on an explicit `--show` |

#### What the harness actually sends

Every event, without exception, carries: `session_id`, `prompt_id`, `transcript_path`, `cwd`,
`permission_mode`, `effort.level`, `hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`.

`Edit` — on **both** `PreToolUse` and `PostToolUse`:

| Field | Content |
|---|---|
| `tool_input.old_string` / `new_string` | the exact replaced text — present *before* the edit lands |
| `tool_response.originalFile` | the complete file contents prior to the edit |
| `tool_response.structuredPatch` | a real diff hunk: `oldStart`, `oldLines`, `newStart`, `newLines`, `lines[]` |

`Write` — `originalFile` is `null` and `structuredPatch` empty when creating a file; both are
populated when overwriting one. **This was a gap in the first probe and was only measured after
noticing it**: the first `Write` created a new file, so it said nothing about overwrites. A gate
assuming `Write` always carries prior state would have broken on every new file.

`PostToolUseFailure` — carries `error`, `is_interrupt`, `duration_ms`. **No exit code, no
`tool_response`.** Consistent with what the README already documents about inferred stamps.

#### Which design assumption this CHANGED

**That a diff-scoped mutation gate would have to shell out to git to reconstruct prior state.**
It does not. The harness hands over a structured patch and the complete original file, per edit,
synchronously. Diff-scoping is free.

A second, unplanned consequence: `old_string`/`new_string` arrive on `PreToolUse`, so a weakening
could in principle be inspected *before it reaches disk*. That is a stronger mechanism than the
advisory one on the roadmap. Recorded as an option, not a decision.

#### What Run 1 did NOT settle

**Whether any hook output channel is DISPLAYED to a human.** Three rounds, three invalid methods:

1. **Leading question.** The agent named the exact string, then asked whether it had been seen.
   Both "yes" answers are worthless — a confirmation of a supplied string, not a report of a
   received one.
2. **An instrument that emitted nothing.** The script ran and minted tokens; its `case` matched no
   channel because the registration passed no argument. It logged sends that never happened. Only
   the nonce log distinguished "no output" from "no hook" — without that control, the silence would
   have been recorded as a finding.
3. **A transcript membership test, killed by its own control.** Tokens from round 2 — never emitted
   on any channel — tested positive, because the agent had printed the nonce log into a tool result
   itself.

What *is* established structurally: hook output on all three channels, on both `PreToolUse` and
`PostToolUse`, is recorded in the transcript as `type=attachment` records — channels A and B under
`attachment.stdout`/`attachment.content`, channel C under `attachment.stderr`. Channel A's JSON
`systemMessage` landed as raw stdout rather than as a surfaced message, which suggests the JSON form
is not honoured as documented. **Present in the transcript is not the same as shown to a human, and
the second question is the one that matters for an advisory mechanism.**

### Run 2 — the live exercise, BEFORE the pull request leaves draft

Not reached. No mechanism exists yet.

### What the live run could not reach

- `MultiEdit` and `NotebookEdit` were never exercised — only `Edit` and `Write`.
- No `Stop` event was captured, though the hook is registered for it.
- One repository, one machine, one session. Not a fleet.
- Whether `permissionDecision` or other JSON output fields behave as documented.

---

## Infrastructure finding, unrelated to the design

The harness reads hook **scripts** live from the marketplace source directory
(`CLAUDE_PLUGIN_ROOT` pointed at the scratchpad source throughout), but reads **registrations**
(`hooks.json`) from the version-keyed cache at `~/.claude/plugins/cache/`.

That cache did **not** refresh after the plugin version was bumped `0.0.1` → `0.0.2` *and*
`/plugin marketplace update` *and* `/reload-plugins`. No `0.0.2` directory was created; `0.0.1`
retained round-1 contents. So round 2's script ran under round 1's registration.

`INC-0019` says bumping the version is what makes the cache copy. Here it was bumped and the cache
stayed stale. **Any live trial that edits `hooks.json` can silently run the old wiring**, which is
precisely the class of defect this programme exists to catch.

Workaround used, and worth keeping: because scripts *are* live, moving probe logic into a script
that is already registered reaches every event with no reload and nothing asked of the human.
