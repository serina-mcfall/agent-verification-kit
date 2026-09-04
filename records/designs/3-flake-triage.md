# Design — Stage 3, `flake-triage`

**Status** designed, **not built** · **Dated** 2026-09-04 · **Decided by** Serina, in session

> Written down because it existed only in a conversation. Every decision below was hers; the
> concerns at the end are mine and are unresolved. **Nothing here has been implemented.**

---

## Why the stage exists, measured rather than assumed

The roadmap says Stage 3 exists because *"none of the above distinguishes flaky from failed, and an
agent's documented response to a flake is to add retries until it stops."* That is the motivation.
This is the **measurement**:

```
run 1:  python3 test_flaky.py   →  exit 1, "FAILED: intermittent"
run 2:  python3 test_flaky.py   →  exit 0, "1 passed"      ← nothing changed between them
        stamp written:  1788489511|python3 test_flaky.py|inferred
        commit 9212df9: ALLOWED
```

**A suite that failed, re-run until it passed, earns a stamp and unlocks a commit.**

Both shipped stages miss it, and for different reasons:

- **Stage 1** sees only the final pass. The stamp protocol has no memory of the failure.
- **Stage 2** sees nothing at all — no test file was touched, so `guard-test-changes.sh` never fires.

**Run-until-green costs an agent one extra tool call and defeats both.** That is the gap.

## Searched before prescribing

| Searched for | Result |
|---|---|
| `flaky` / `quarantine` as first-party code anywhere in `~/Launchpad` | **absent** — only vendored `node_modules` |
| A flake mechanism in this kit | **absent** — the words appear only in `guard-test-changes.sh` prose and one fixture |
| Prior art | **found** — `buzz/desktop/scripts/summarize-flaky-tests.mjs`, which INC-0001 showed had never once run |
| Live flake incidents | **found** — buzz INC-0001, INC-0004 |

## The decisions

Each was a fork with real alternatives; the rejected ones are kept so a later reader can see the
trade rather than only the outcome.

| # | Decision | Rejected |
|---|---|---|
| 1 | **Core job: run-until-green laundering** | flaky-as-a-distinct-reported-state (needs per-runner integration); quarantine-with-issue-numbers (needs detection first) |
| 2 | **Refuse the stamp until declared** | never-block-always-disclose; refuse-with-no-override (the README argues against it by name); warn-only |
| 3 | **Any edit clears the failure memory**, reusing `edit-tracker.sh` | non-test-source only; nothing-clears-it (**rejected as wrong** — it would fire on every red-green cycle) |
| 4 | **Declaration = command + reason + `#issue`** | free-text only; full owner+deadline per PRD #290 |
| 5 | **New sourced library + three small hook edits** | all inside `post-bash.sh`; a separate PostToolUse hook (**rejected** — two hooks racing on run state, and the losing order fails open) |

## The mechanism

```
flake-ledger.sh          sourced library, following stamp-path.sh exactly
test-flake-ledger.sh     its control suite
                         + small call sites in post-bash / edit-tracker / verify-gate
```

**Flow.** A failing test command records itself in `<repo>/.claude/.failed-runs` (`epoch|command`,
30-minute TTL). Any `Edit`/`Write` clears that ledger in the same call `edit-tracker.sh` already
clears the stamp. A later *pass* of the **same command** with the ledger still populated is a
**flake**, and the stamp is written as `epoch|command|basis|flaky` — a fourth field.
`verify-gate.sh` refuses a flaky stamp unless `<repo>/.claude/.flaky` declares that command.

**Why clearing on edit is load-bearing:** write failing test → implement → pass is *also*
fail-then-pass. Without clearing, the detector fires on every legitimate TDD cycle, and the
false-positive rule says that is `fix` or `drop` however correct it is in principle.

**Matching is prefix + whitespace**, as in `guard-test-changes.sh` — the fix for the spaced-path
defect found in the PR #143 review. Commands contain spaces far more often than paths do.

**`verify-gate.sh` needs no new dependency** — it reads field 4 and greps `.flaky`. No sourcing,
nothing new that can fail closed at the wrong scope.

**Degraded states fail open, loudly.** Missing library or unreadable ledger → stamp as today, print
*"flake detection is NOT enforcing"*. That is the lockout recorded in `verify-gate.sh`'s header.

**The refusal names the time**, because the ledger is repo-scoped and Serina runs 5–7 concurrent
sessions: *"'npm test' failed at 14:02 and passed at 14:09 with no edit between."* One timestamp is
the difference between "the gate is broken" and "that was my other session."

## Controls — thirteen, each red first, each with a distinct killing mutation

vacuity guard · fail→pass same command → flaky · fail→**edit**→pass → clean · fail→pass *different*
command → clean (pins the bypass as known) · past TTL → clean · repo scoping · declared → allowed
and names the issue · no `#issue` → refused · declaration for another command → authorises nothing ·
prefix boundary · library missing → visible non-enforcement · ledger unreadable → same · 3-field
stamp → clean (the documented fail-open, asserted so it is deliberate).

Plus integration controls in the three hook suites, and the workflow's explicit suite list updated.

---

## My concerns, unresolved — read these before building

### 1. It has no half anyone else sees

Stage 2's teeth are the `Test-change:` **trailer**, because it is in the permanent record and shows
up in the pull request. A flake declaration lives in `.claude/.flaky`, which is **gitignored and
expires in 30 minutes.** An agent can hit a flake, declare it, commit, and leave *no trace a
reviewer will ever encounter*. The gate makes it deliberate; it does not make it visible — and the
kit's own criterion is *"someone else sees it."*

**Proposed fix, agreed but not designed in detail: require a `Flaky:` commit trailer** carrying the
command and the issue number, mirroring Stage 2.

### 2. Command narrowing may be the modal path, not a corner case

`pytest` fails → `pytest -k test_auth` passes → *different command string* → clean stamp.

That is not evasion. **Narrowing to the failing test is correct debugging**, for a person or an
agent. So the most natural honest workflow defeats the detector without intending to. No
normalisation fixes this reliably across eight ecosystems. **This belongs in the trial record as a
headline limitation, not the fourth bullet.**

A second false positive: fail → start a dev server / export a var / pull a dependency → pass. No
edit, genuine fix, reads as flaky.

### 3. It may not be the right Stage 3 at all

The hole is real and I have the commit hash. But **I found it in a fixture I built for the
purpose.** The recorded flake pain in this workspace is buzz INC-0001 (a reporter that had never
run) and INC-0004 (E2E flakes failing docs-only PRs) — and **Stage 3 as designed does nothing for
either.**

The programme dropped quarantine saying *"no evidence yet that quarantine is needed."* This design
may be the mirror image: building detection where the evidence points at reporting.

---

## Why it is parked

On 2026-09-04 the session pivoted to buzz INC-0001 on my recommendation, which turned out to be
partly wrong — that fix crosses the fork's upstream boundary, which I had not read. INC-0001 is now
fixed and guarded regardless.

**Nothing here is blocked.** Stage 3 is in this kit, which Serina owns outright: no fork boundary,
no governance, no upstream. It can be picked up whenever, starting from the decisions above.

**If it is picked up, change two things first:** add the `Flaky:` trailer, and promote command
narrowing to a headline limitation in the trial record.
