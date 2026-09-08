# Trial — mutation-gate

**Phase** 4 · **Started** 2026-09-06 (UTC; morning of 2026-09-07 NZ) · **Closed** — open
**Where** `serina-mcfall/agent-verification-kit`, branch `spike/stage4-payload`
**Verdict** — **not yet reached.** Run 1 (harness measurement) and Run 1b (evidence about the
premise, from another repository). **No mechanism exists.** Run 1b is deliberately not numbered
Run 2: Run 2 is the live exercise of a built mechanism, and there is nothing yet to exercise.

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

Not reached. **No mechanism exists yet, and nothing below is one.**

### Run 1b — evidence about the premise, from a hand-built matrix in another repository

**Added 2026-09-08. This is not the mechanism and carries no verdict.** What it is: the first
live evidence that the thing this mechanism is meant to catch actually happens, gathered by
hand-mutating one script rather than by any gate. `mutation-gate` still sits at **verdict not
reached**.

The distinction matters. What ships here is meant to be *diff-scoped, automatic and advisory*.
What produced the evidence below is a 13-mutation matrix, written by hand, aimed at one script,
run deliberately. It answers *"is the premise sound?"* and says nothing about *"does an
automatic gate pay for itself?"*

Where: `serina-skills`, reconciling two lineages of `verdict.sh` into one. Committed there as
`test/mutate-verdict.py` and `test/mutate-runner.sh`.

#### 1. The target defect class is real, and here is a dated instance

This trial's own opening says the mechanism exists to catch *"an assertion weakened without
changing the assertion count — `assert_eq!(a, 5)` becoming `assert_eq!(a, a)` — which stage 2
sees as a change and never as a weakening."* That was a hypothesis. It is now an observation:

> A control named *"a tab-indented PASSING command runs and is recorded in full"* asserted an
> exit code and a recorded string, and **not execution**. A build that recorded the command
> without running it passed it. The change was **declared** to `guard-test-changes.sh`, which
> allowed it correctly — the declaration was honest, the assertion count was unchanged, and the
> weakening was invisible to a diff.

Mutation found it: replacing the suite execution with a no-op left that control green while
`T1` and `J` went red. Two further instances in the same session — a control accepting an
instant refusal as proof of deadline enforcement, and one asserting a property of its own
environment rather than of the code.

**This is the strongest argument for the mechanism so far, and it is the argument stage 2 cannot
make for itself.** It is also confirmation of the stated blind spot in `REV-0020`, not a fault
found in the guard.

#### 2. Cost, measured

| | |
|---|---|
| Suite under test | 88 controls |
| One suite run | 19s |
| 13-mutation matrix | 260s |
| Per mutation | 20s |

Roughly *n* × the suite. That is affordable deliberately and **unaffordable per edit**, which is
what the ladder's governing rule already predicts: this belongs at the merge gate or below, never
in the inner loop. A diff-scoped gate would run far fewer than 13, so 260s is an upper bound for
a script this size, not a projection.

#### 3. A design requirement Run 1 could not have found: the harness must prove it mutated

The first version of this matrix split its arguments on a **NUL byte**, which bash cannot pass.
The split raised, **no mutation was applied**, and all five controls reported `PASS`. It was
recorded as a successful mutation run.

> **A mutation gate that fails to mutate reports a perfect score.** Its failure mode is
> indistinguishable from total success, and it fails in the reassuring direction.

Both committed harnesses now abort loudly when an anchor is missing. **Any mechanism that ships
here needs the same property as an acceptance criterion**, and it is not obvious from the outside
— a survivor count of zero reads as good news.

#### 4. A false-positive source that will decide this mechanism's verdict

This trial's rule is that `false_positives` decides most verdicts. Here is one that a naive
diff-scoped gate would produce on this codebase:

> `verdict.sh` calls `json.loads(text)` after encoding, to refuse writing a file it cannot read
> back. Removing it changes **no** control's outcome, so mutation reports it as a survivor — an
> uncovered line. It is not a defect. The guard fires only on output `json.dumps` cannot produce,
> so it is **behaviourally invisible while the encoder is correct**.

Measured, because the obvious reading is wrong in an interesting way: with the encoder replaced
by naive interpolation, a crafted reason still read back as `READY` and still opened the gate
**with the guard present** — a duplicate-key document is valid JSON. So the guard does not defend
what it appears to; the escaping does.

**Consequence for the design.** Defence-in-depth guards whose precondition cannot arise are
*unkillable by construction*, and a gate that reports them as survivors is crying wolf on exactly
the code most carefully written. The matrix handles it with an allowlist carrying a demonstrated
justification, which fails if an allowlisted mutant ever turns out killable. Whether that is
tolerable at gate scale is an open question — it is hand-maintained, and hand-maintained
allowlists rot.

#### What this does NOT establish

- Nothing about **diff-scoping**. Every mutation here was chosen by hand against a whole file.
- Nothing about **`mutmut` or `cargo mutants`** specifically; no tool was used.
- Nothing about **Python or Rust**. The subject was bash, which neither tool covers.
- Nothing about **fleet cost**, one repository and one machine.
- Nothing about whether survivors get **read** when reported — Addendum 1 answers the channel
  question, not the attention question.

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

---

## Addendum 1 — the channel question, answered on the fourth attempt

**Recorded `NOTE-0032`.** The section above says Run 1 did not settle whether any hook output
channel is displayed to a human. A fourth round settled it.

**Method, and the reason it is trustworthy where three earlier rounds were not.** Six nonces were
emitted in one round — three channels across `PreToolUse` and `PostToolUse`. The agent did not
read, print, or know any token before Serina reported. The only route from hook to human was the
channel itself.

**Result.** She reported exactly two of the six, and both were channel A, `systemMessage`, one from
each event. Plain stdout and stderr were emitted on both events and neither arrived.

| Channel | `PreToolUse` | `PostToolUse` |
|---|---|---|
| A — `systemMessage` (JSON on stdout) | **displayed** | **displayed** |
| B — plain stdout, exit 0 | not displayed | not displayed |
| C — stderr, exit 0 | not displayed | not displayed |

**The selectivity is the evidence.** Two of six, both the same channel, drawn from a set the
reporter could not see in advance.

The surfaced form is attributed to its origin: `PreToolUse:Bash says: <text>`.

**This confirms `research/claude-code-hook-output-channels.md`** (2026-09-04), which said from
documentation that plain stdout and stderr at exit 0 reach the debug log and never the transcript.
Its one open question — whether `PreToolUse` honours `systemMessage` — is now closed by measurement
rather than by reading.

**It also corrects an inference made earlier in this same trial.** The structural finding above
notes channel A landing in `attachment.stdout` and reads that as the JSON form not being honoured.
That was wrong. It is recorded as stdout *and* surfaced. Presence in the transcript says nothing
either way about display — which is the distinction this trial was arguing at the time, and then
failed to apply to its own reading.

**Consequence for this mechanism.** `mutation-gate` can ship advisory and actually be read. The
roadmap entry survives its first design risk.

**Consequence for `INC-0013` and `INC-0016`.** Both stay open, because nothing is fixed yet. But
they stop being research. `guard-test-changes.sh`, `verify-gate.sh` and `post-bash.sh` announce on
stdout or stderr — the two channels that reach nobody — while `systemMessage` worked the whole time.
