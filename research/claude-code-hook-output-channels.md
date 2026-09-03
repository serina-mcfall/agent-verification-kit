# Claude Code hook output channels — where a hook's words actually go

Researched 2026-09-04 · primary source: <https://code.claude.com/docs/en/hooks> · fetched three times,
see *What could not be determined*

## Why this note exists

This kit's hooks announce things on the **allow** path as a deliberate design property:

- `guard-test-changes.sh:213-222` — *"SAY WHAT AUTHORISED IT, at the moment it is relied upon…
  an authorisation nobody sees is indistinguishable from no gate."*
- `verify-gate.sh:387-389` — *"Verified Nm ago, exit code INFERRED… Commit allowed."*

On 2026-09-04, after the plugin's first observed install, **neither line reached the agent and
neither reached the operator.** The block path worked perfectly; the allow path was mute. This note
establishes why, from the documentation rather than from inference, because the fix depends on which
channel works and guessing produces a second silent hook.

## The finding, in one line

**Both lines are written to stdout at exit 0, and a `PreToolUse` hook's exit-0 stdout goes to the
debug log.** Not the transcript. Not the model. Not the terminal.

## What the documentation says, verbatim

### Exit 0, stdout

> "For most events, Claude Code writes stdout to the debug log and doesn't show it in the
> transcript."

> "The exceptions are `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, and
> `PostModelSwitch`, where Claude Code adds plain-text stdout as context that Claude can see and act
> on."

**`PreToolUse` is not among the four exceptions.** Neither is `PostToolUse`. So every plain-text
announcement this kit makes on an allowed call goes to the debug log.

### Exit 0, stderr

> "Stderr from a hook that exits 0 goes to the debug log only, never the transcript, and Claude
> never sees it."

**This refutes the obvious fix.** Moving the announcement from stdout to stderr changes nothing —
it is the *exit code*, not the stream, that decides visibility. Had this not been checked, the
"fix" would have been a second invisible message and the record would have carried a closed finding
that was still open.

### Exit 2

> "Exit 2 means a blocking error."

> "The blocking message is the reason from your JSON's blocking decision when it makes one, and your
> stderr text otherwise."

Per-event, for the two this kit uses:

| Event | Documented exit-2 behaviour |
|---|---|
| `PreToolUse` | "Blocks the tool call" |
| `PostToolUse` | "Shows stderr to Claude; the tool already ran" |

This is why the kit's refusals work and are the only part of it anyone has ever seen. `EDIT
BLOCKED` and `COMMIT BLOCKED` arrive on stderr at exit 2 and are surfaced verbatim.

### The documented way to surface a message

> "To surface a message to the user on any platform, return `systemMessage` in JSON output. Some
> events discard it or deliver it elsewhere, and each event's section says so."

So `systemMessage` is **the** documented mechanism, and it is a JSON-output field rather than a
stream. Reaching it means printing JSON rather than plain text:

> "Whether Claude Code reads your stdout as JSON output or as plain text depends on how it starts
> and ends, ignoring surrounding whitespace:
> - **Starts with `{` and ends with `}`**: Claude Code parses it as JSON…
> - **Starts with `{` but doesn't end with `}`**: Claude Code treats it as plain text.
> - **Starts with anything else**: Claude Code treats it as plain text…"

That parsing rule matters for any fix here: a hook that prints JSON **and** a stray plain-text line
gets its whole output read as plain text, silently.

### Exit codes other than 0 and 2

> "Any other exit code doesn't block on its own for most hook events."

> "With a parsed object that passes schema validation, for events that use the standard decision
> model, Claude Code ignores the exit code and the JSON alone decides the outcome"

> "it's a non-blocking error for most hook events: the action proceeds, and the transcript shows a
> `<hook name> hook error` notice followed by the first line of stderr, prefixed with `Failed with
> non-blocking status code:`"

## The channel table

| Want to… | Channel | Works? |
|---|---|---|
| Block a tool call and explain why | stderr, exit 2 | ✅ documented, and observed working in this kit |
| Tell the model something on an allowed call | plain stdout, exit 0 | ❌ debug log, on `PreToolUse`/`PostToolUse` |
| Tell the model something on an allowed call | stderr, exit 0 | ❌ "never the transcript, and Claude never sees it" |
| Tell the **user** something on an allowed call | `systemMessage` in JSON on stdout | ⚠️ documented as the mechanism; **per-event support for `PreToolUse` not established — see below** |
| Add context the model acts on | plain stdout, exit 0 | ✅ but only on `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, `PostModelSwitch` |

## What this means for this kit

1. **The design property is not delivered, and cannot be delivered by moving streams.** Both the
   guard's authorisation line and the gate's unlock line are invisible in normal use.
2. **The comments claiming it should not stand as written** until either the fix lands or the claim
   is corrected. `guard-test-changes.sh`'s own argument — that an authorisation nobody sees is
   indistinguishable from no gate — currently indicts the file it is written in.
3. **It is not a code defect.** Both scripts emit exactly what they say they emit, on exit 0, and
   that was confirmed by running them directly and measuring the bytes per file descriptor:

   | Case | exit | stdout | stderr |
   |---|---|---|---|
   | undeclared `test-config` path | 2 | 0 bytes | 1009 bytes |
   | declared, fresh, `test` path | 0 | **122 bytes** | 0 bytes |

4. **The same wrong assumption is in both twins.** This is not the README's row-4 pattern (a fix
   applied to one file and not its sibling) — it is worse, because grepping for the shape finds both
   files agreeing with each other. Only executing them and watching the file descriptors found it.

## What could not be determined

- **Whether `PreToolUse` honours, discards, or redirects `systemMessage`.** The documentation says
  each event's own section states this. **That section was not retrievable.** The page was fetched
  three times — at `#json-output`, `#pretooluse` and `#hook-events` — and every retrieval truncated
  at the same point, mid-table in "Exit code 2 behavior per event". The individual event subsections
  are past the truncation. Recorded as **could-not-determine**, not as absent.
- **Whether `permissionDecision: "allow"` is valid on `PreToolUse`, and whether
  `permissionDecisionReason` surfaces anything when it is.** Only the `"deny"` example is in the
  retrieved content. The docs do say: *"Exit 0 with no output means the hook has no decision to
  report… The hook can deny the call, but staying silent doesn't approve it."* — which implies an
  approve path exists but does not document its message behaviour.
- **Whether a `suppressOutput` field exists.** Not present in any retrieved content.
- **Whether the debug log is reachable in practice.** If it is, the messages are not lost, only
  filed somewhere nobody looks — which is a different problem with a different fix.

## How to close the gap

Two routes, either sufficient:

1. **Read the untruncated reference.** The page itself points at `https://code.claude.com/docs/llms.txt`
   for the full text; `https://code.claude.com/docs/hooks-reference` was also suggested by the fetch.
2. **Measure it.** Wire one throwaway `PreToolUse` hook that prints
   `{"systemMessage":"MARKER-<something-unique>"}` and exit 0, trigger a tool call, and look for the
   marker. This is the method this kit argues for everywhere else, and it answers the question for
   *this* harness version rather than for the documentation's.

**Do not prescribe a fix from this note alone.** It refutes one candidate (stderr) with a direct
quotation and identifies another (`systemMessage`) as documented-but-unverified for the event in
question. That is enough to stop a wrong fix and not enough to choose a right one.

## Sources

- Claude Code hooks reference — <https://code.claude.com/docs/en/hooks> — fetched 2026-09-04, three
  times, truncated at the event sections each time
- Direct measurement of `guard-test-changes.sh` and `verify-gate.sh` stdout/stderr byte counts at
  exit 0 and exit 2 — 2026-09-04, this repository
