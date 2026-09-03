# Trial — test-modification guard

**Stage** 2 · **Started** 2026-09-03 · **Closed** 2026-09-04
**Where** `serina-mcfall/agent-verification-kit`

**Verdict — split, because the two halves have different evidence and one verdict
would hide that:**

| Half | Verdict | Why |
|---|---|---|
| `check-test-changes.sh` (CI) | **`keep`** | failed a real pull request with exit 1, naming the path — PR #1, run `33734157319` |
| `guard-test-changes.sh` (hook) | **`keep`** | fired from `${CLAUDE_PLUGIN_ROOT}` and refused an undeclared test edit, 2026-09-04 — **see Addendum 4** |

> **The hook half was `blocked` until 2026-09-04**, on one number and nothing else: zero plugin
> installs observed. That number is now 1, and the hook has been observed refusing, printing a
> remedy, and allowing the retry once the remedy was followed.

A single verdict for "the test-modification guard" would have had to pick one of those and
misreport the other. The template asks for one verdict per *mechanism*; this stage shipped two.

> **The `keep` was awarded prematurely and re-earned.** On 2026-09-03 it was granted while
> `check-test-changes.sh` still carried a Blocker — `--diff-filter=MD` omitted git type changes, so
> a test swapped for a symlink read as clean. Closed and covered 2026-09-04. **See Addendum 3**,
> which also records the other four review findings and the four separate cases of a control that
> could not fail.

---

> **Paths in this document are the names they had at the time.** On 2026-09-04 four files were
> renamed to close INC-0010. The historical names are left in place below rather than rewritten,
> because rewriting them would falsify what was built and reviewed under which name.
>
> | Then | Now |
> |---|---|
> | `test-guard.sh` | `guard-test-changes.sh` |
> | `test-patterns.sh` | `classify-test-paths.sh` |
> | `test-test-guard.sh` | `test-guard-test-changes.sh` |
> | `test-test-patterns.sh` | `test-classify-test-paths.sh` |
> | `.github/workflows/test-guard.yml` | `.github/workflows/verification.yml` |

## What this mechanism is meant to catch

A test, or test configuration, changed to make a red suite green.

## What was set up

Two halves and a shared classifier, all new code.

| File | Lines | Role |
|---|---|---|
| `test-patterns.sh` | ~200 | sourced classifier — a path is `test`, `test-config`, or `other` |
| `test-guard.sh` | ~200 | `PreToolUse` on `Edit\|Write\|MultiEdit\|NotebookEdit` — refuses an undeclared modification |
| `check-test-changes.sh` | ~170 | CI half — reads the branch diff, requires a `Test-change:` trailer per path |

`hooks.json` gained a second `PreToolUse` entry. `check-test-changes.sh` is invoked by a workflow,
not by a hook, and is therefore the only part of this kit that does not depend on the plugin
delivery mechanism Stage 1 could not prove.

### Searched before prescribing

Per this programme's first rule, recorded either as a location or as a named search that found
nothing:

| Searched for | Result |
|---|---|
| `test-change` as an existing convention | **absent as code** — appears only in the two buzz planning documents, i.e. proposed, never built |
| `test.modification` / `test-mod-guard` | **absent as code** — same two documents |
| `git-safety.sh` covering test paths | **absent** — it blocks destructive git operations only; no test-path logic, no overlap |
| an existing buzz workflow doing this | **absent** — 10 `launchpad-*` workflows exist, none is a test guard |

### Why the classifier is generous, and why that is the design

The predecessor of this mechanism named `crates/**` Rust and `.spec.ts` only. An adversarial review
counted what that missed in one repository: **610** Desktop `.test.mjs`, **156** Flutter
`_test.dart`, **100** Tauri Rust and **121** Python test files — including the tests for the very
checker the plan proposed to modify. A guard matching a fraction of the suites reports success
while everything it does not recognise is edited freely.

So the bias is deliberate: over-match rather than under-match. A false positive costs one
declaration line; a false negative is the bypass. `.claude/test-guard.conf` exists so a repository
can narrow it, because a guard nobody can narrow is a guard that gets switched off wholesale.

### Two classes, not one

`test-config` is a separate class because *"make the failing test pass"* has two shapes and only
one of them touches a test file. `retries: 2` in `playwright.config.ts` silences a real race
without editing a single assertion, and a guard watching only `*_test.*` never sees it. Clipboard
Health (2026-04-21) recorded agents responding to flakes exactly this way.

## What was thrown at it

| # | Input | Expected | Actual | ✅/❌ |
|---|---|---|---|---|
| 1 | `test-test-patterns.sh` — 8 ecosystems, directory layouts, 8 near-misses, config precedence, malformed config | 64 pass | 64 pass, 0 fail | ✅ |
| 2 | `test-test-guard.sh` — refusal, declaration, staleness, repo scoping, visible non-enforcement | 32 pass | 32 pass, 0 fail | ✅ |
| 3 | `test-check-test-changes.sh` — modify, delete, rename, added-file agreement, could-not-determine | 37 pass | 37 pass, 0 fail | ✅ |
| 4 | **Bypass attempts, hook half** — another path · blanket `*` · a glob · a path inside someone else's reason · a commented-out line | all refused | all refused | ✅ |
| 5 | **Bypass attempts, CI half** — trailer for another path · path inside a reason · blanket `*` · declaring 1 of 2 · rename to a non-test name | all refused | all refused | ✅ |
| 6 | **Could-not-determine** — unresolvable base ref · missing classifier · not a repository | exit **3**, never 0 | exit 3 in all three | ✅ |
| 7 | **The plugin actually delivering `test-guard.sh`** | the hook fires from `${CLAUDE_PLUGIN_ROOT}` | **NOT RUN** | ⚠️ |
| 8 | **`check-test-changes.sh` in a real CI workflow** | fails a PR that weakens a test | **NOT RUN** | ⚠️ |

**Total: 133 new controls, 0 failing.** Kit-wide: 357.

Row 4 and 5 are the rows that decide whether this is a guard or a formality. Both halves match the
declared path on its **first whitespace-delimited field**, so a path appearing inside another
entry's free-text reason authorises nothing — and neither accepts a glob, so weakening forty tests
costs forty declarations. A single `*` would have made the whole mechanism ceremony.

---

## What happened

### ✅ What was great

- **The bypass attempts all failed, including the two subtle ones.** A path mentioned inside
  someone else's reason, and a rename to a name the classifier no longer calls a test. The second
  is the one that would have shipped broken: with git's rename detection on, `git mv tests/test_a.py
  src/retired_a.py` reports as a single `R` that an added-and-modified filter drops entirely, so
  retiring a test would have needed no declaration at all.
- **Creation is free, and both halves now agree on it.** Adding a test is never blocked and never
  needs a trailer. Taxing new tests would train agents to avoid writing them, which is worse than
  anything this guard prevents.
- **Three exit codes in the CI half, not two.** `0` checked-and-clean, `1` checked-and-undeclared,
  `3` could-not-check. Every failure mode of a diff-based checker produces an empty list, and an
  empty list otherwise looks identical to "no tests were touched".

### ⚠️ What needs work

- **Row 7 — the hook's delivery is still unproven**, exactly as in Stage 1 and for the same reason:
  no plugin install has been observed.
- **Row 8 — the CI half has never run in CI.** It has been run against fixtures and against this
  repository's own history, both from a shell. No workflow file ships with this kit yet, so the
  `fetch-depth: 0` requirement is documented in the README and enforced by nothing.
- **The 30-minute TTL on `.claude/.test-change` is asserted, not reasoned.** It was chosen to match
  the verification stamp for consistency of expectation. Nobody has measured whether 30 minutes is
  right for a refactor that legitimately touches many test files.

### ❌ What broke

Nothing broke in testing. **Two defects were found by reasoning about the code rather than by
running it**, and both are recorded because the manner of finding them matters:

1. **A `2>/dev/null` on the classifier's config reads** would have silenced every configuration
   warning the function immediately above it claimed to emit loudly. Caught while writing the
   controls, before the first run. That is the fail-open shape recorded as INC-0003 — an absent
   input producing empty output that reads as a pass — reproduced by the author of a comment
   warning against it.
2. **The two halves disagreed about added files** (above). Caught by asking what this script would
   say about the very commit that introduces it: nine new test files, not one of them a weakening,
   all nine flagged. Neither existing control would have caught this, because every fixture
   modified a test rather than adding one.

Defect 2 is the more instructive. **A test suite built from the cases you thought of cannot find a
case you did not think of.** What found it was running the mechanism against real data — its own
repository — rather than against fixtures.

### 🗑️ What should go

Nothing yet. `*/e2e/*` and `*/spec/*` in the default classifier are the widest patterns and the
most likely future `drop` candidates — `docs/spec/api.md` classifying as a test is asserted in the
controls as a **known** false positive so that nobody silently narrows it without seeing the trade.

---

## The numbers

| Field | Value | Notes |
|---|---|---|
| `ci_seconds` | 0 | no workflow yet; the three suites run locally in a few seconds |
| `true_positives` | 2 | the silenced-warnings fail-open; the added-file disagreement |
| `false_positives` | 1 | `docs/spec/api.md` → `test`. Known, asserted, and narrowable via `.claude/test-guard.conf` |
| controls observed | 133 | new this stage; 357 kit-wide, 0 failing |
| **plugin installs observed** | **0** | unchanged from Stage 1 |
| **CI runs observed** | **0** | |

---

## What this trial could NOT determine

- **Whether the hook is delivered by the plugin.** Unchanged from Stage 1 and blocking for the same
  reason. Nothing here has fired from `${CLAUDE_PLUGIN_ROOT}`.
- **Whether the CI half works in CI.** It has only ever been invoked from an interactive shell. The
  `fetch-depth: 0` failure mode is the one most likely to bite, and it is the one exercised least —
  a shallow clone was simulated by passing a bad ref, which is not the same thing.
- **Whether the declaration friction is tolerable.** Author-tested only, on fixtures. A guard that
  fires correctly and annoys five people is a failure this trial reports as a success. The
  `false_positives` count of 1 is measured against controls I wrote, not against a week of real
  work.
- **Whether the classifier's coverage holds outside the ecosystems I know.** Eight are covered.
  Elixir, Scala, Swift, Haskell and Clojure conventions are guesses or absent.
- **Whether `assert_eq!(a, a)` gets past it.** It does, by design and by arithmetic — the assertion
  count is unchanged, so this shows as a *declared or undeclared change*, never as a *weakening*.
  Stage 4's mutation layer is the only thing that measures whether assertions still bite, and it
  will ship advisory. **This is a real remaining gap, not a covered one.**

---

## Verdict

**`fix`** — and unlike Stage 1 this is `fix` rather than `blocked`, because there is a named defect
with a named owner rather than only an unrun test.

The mechanism works and survived every bypass thrown at it. But **it ships with no workflow file**,
which means the half of it that has actual teeth — the half that reads git rather than a file the
agent can write — is documented and unwired. A CI check nobody has wired into CI is a README claim.

Two things close it, in order:

1. **Ship a workflow.** `.github/workflows/test-guard.yml` calling
   `check-test-changes.sh origin/main`, with `fetch-depth: 0`, and one deliberately-weakened test
   in a branch to prove it fails a real pull request once.
2. **Then the Stage 1 unblock steps**, which cover `test-guard.sh` too: install the plugin, restart,
   and confirm a refusal came from the plugin's copy rather than a global symlink.

Step 1 is genuinely independent of the plugin question and can be done now. That matters: it means
Stage 2 can reach `keep` on its CI half while Stage 1 is still `blocked` on delivery.

---

## Addendum — 2026-09-03, same session

Written after the verdict above rather than folded into it, so the progression is legible.

### Row 8 is now half-observed

A workflow was written and pushed. **Run `33726749724` completed `success`** on
`ubuntu-latest`, and its log shows nine `PASS test-*.sh` lines — every suite, on a clean runner,
with `jq-1.7` present. That answers a question the local runs could not: the controls do not depend
on this machine's state.

| Job | Status |
|---|---|
| `controls` | **observed green in CI** — 9/9 suites, run `33726749724` |
| `undeclared-test-changes` | **still not run** — it is `if: github.event_name == 'pull_request'` and no pull request exists |

So the half with teeth still has not fired in CI. `fix` stands.

### The guard was run against real history, twice

Fixtures test the cases you thought of. These are the repository's own commits.

1. **Clean case.** `check-test-changes.sh 4a56d78` over the Stage 2 commit range: *"2 files modified
   or deleted, 0 of them tests or test config"* → **exit 0**. The seven newly-added test files were
   correctly not gated, which is the added-file agreement defect (above) confirmed fixed on real
   data rather than on a fixture.
2. **Weakened case.** Branch `trial/undeclared-test-change` replaces `test-test-guard.sh`'s final
   `[ "$fail" -eq 0 ]` with `exit 0`, so the suite can report failures and still pass — a real
   weakening of a real file, committed. `check-test-changes.sh main` → **exit 1**, naming
   `plugins/agent-verification-kit/hooks/test-test-guard.sh`. That branch is retained as the
   fixture for the pull-request proof.

### A third defect, found by reading the output rather than the code

The refusal message's copy-pasteable example printed a **double space** after `Test-change:`,
because `${missing[0]#* }` strips to the first space while the array entries are
`class␠␠path`. Measured rather than assumed: `git` normalises the leading whitespace out of a
trailer value, so the pasted command *did* work — **cosmetic, not functional.** Fixed anyway, via a
parallel `missing_paths` array.

The valuable part is the control it produced. `test-check-test-changes.sh` section 10 now
**extracts the command the script tells you to run, runs it, and asserts the check then passes.**
That is the defect recorded as this kit's ancestor's issue #22: a refusal message documented an
escape hatch, the message was wrong about the runners the project had, and the escape hatch became
the trained route. A gate's message is its user interface, and an untested instruction is a guess
printed with authority.

Controls: **42** in that suite, **362** kit-wide.

### Revised numbers

| Field | Was | Now |
|---|---|---|
| `true_positives` | 2 | **3** (added the printed-remedy formatting) |
| controls observed | 133 new / 357 kit | **138 new / 362 kit** |
| CI runs observed | 0 | **1** (`controls` job only) |
| plugin installs observed | 0 | 0 |

### What still closes this

One thing, unchanged: **open a pull request from `trial/undeclared-test-change`** and confirm the
`undeclared-test-changes` job fails it. The branch exists and is known to fail the check locally.
Until that job has run once, "this fails a PR that weakens a test" is a claim about a workflow file
rather than an observation.

---

## Addendum 2 — the pull-request proof, 2026-09-03

**PR #1** — `DO NOT MERGE: trial — undeclared test weakening`, draft, opened on the instruction
*"yes open the trial PR"*. Branch `trial/undeclared-test-change` weakens
`plugins/agent-verification-kit/hooks/test-test-guard.sh` by replacing its final
`[ "$fail" -eq 0 ]` with `exit 0`, and declares nothing.

Run `33734157319`:

| Check | Result | Time |
|---|---|---|
| `controls (357)` | **pass** | 14s |
| `undeclared test changes` | **fail** | 3s |

The failing job's log ends `Process completed with exit code 1`, naming
`plugins/agent-verification-kit/hooks/test-test-guard.sh`. **Exit 1, not exit 3** — a genuine
refusal, not a could-not-determine dressed up as one. That was the specific risk written into the
PR body before it ran, because `fetch-depth: 0` on a `pull_request` event was untested; it holds.

An unplanned detail worth keeping: the log's copy-pasteable remedy shows the **corrected** single
space, even though the trial branch predates that fix. `pull_request` checks out the merge commit,
so the check ran against the merged result rather than the branch tip. Useful to know — it means
this job answers "would main be broken if this merged", which is the more useful question, and it
is not what a naive reading of the workflow would predict.

### The most important line in that table is the one that passed

**`controls` went green on a branch whose test suite can no longer fail.** The weakened suite still
prints its `FAIL` lines and still exits 0, so CI reported success. That is not a defect in the
workflow — it is the entire argument for this mechanism reading the *diff* rather than trusting the
*result*, and it is the argument for Stage 4 as well: a guard that watches for changes cannot
measure whether the assertions that survive still bite.

Anyone quoting "CI was green" about that commit would have been quoting a suite that had been
disabled.

### Two defects the run surfaced, both fixed

1. **The job was named `controls (357)`** and the suites held 362 by the time a pull request first
   displayed it. A count typed into a label is a stale claim printed with authority. Renamed to
   `controls`; the number is now only ever reported by running the suites.
2. **`actions/checkout@v4` raised a Node 20 deprecation warning** on the runner. Bumped to `v5` in
   both the workflow and the README snippet.

### Disposal

PR #1 stays **open as a draft** until a human closes it — it is the only live evidence of this
check working, and closing it before the trial record is read would leave the record citing a run
nobody can navigate to from the PR. It must never be merged.

### Revised numbers

| Field | Was | Now |
|---|---|---|
| `ci_seconds` | 0 | **17** (14s controls + 3s guard) |
| `true_positives` | 3 | **5** (added the stale job-name count; the deprecated checkout) |
| CI runs observed | 1 | **2** — `controls` on push, both jobs on a pull request |
| plugin installs observed | 0 | 0 |

---

## Addendum 3 — Serina's review, 2026-09-04

Reviewed by Serina, `review-code` and `review-tests`, split by artefact. **Five findings, two of
them Blockers. All five verified by reproduction before being accepted, and all five closed
control-first — the control written and observed RED before any code changed.**

### The `keep` in the header table was premature

It was awarded on the strength of PR #1 failing correctly. At that moment
`check-test-changes.sh` carried **Blocker 1**: `--diff-filter=MD` omitted git's type-change status,
so a tracked test file swapped for a symlink was invisible and the script reported clean.

The PR proof was real and remains real. It simply did not test the thing that was broken — every
fixture and the PR itself *modified* a test, and none changed a file's **type**. A `keep` earned by
one true positive is not a `keep` earned against the mechanism's failure modes, and this record
should not have implied otherwise.

The verdict stands as `keep` now, **re-earned 2026-09-04** with the hole closed and covered.

### The five findings

| # | Sev | Finding | Closed by |
|---|---|---|---|
| 1 | **Blocker** | `--diff-filter=MD` missed type changes (`T`). `rm x && ln -s /dev/null x` reported clean, exit 0, seen by **neither** half | `MDT`; suite section 11, red first (`exit 0, wanted 1`) |
| 2 | **Blocker** | `test-verify-gate-portability.sh` passed against the bug it existed to catch | `HOME` isolated + mutation baked into the suite; 6/0 current, 3/2 reverted |
| 3 | High | `test-guard.sh` read only `.tool_input.file_path`; `NotebookEdit` uses `notebook_path`, so every notebook edit was silently allowed | read both keys; section 10, red first. **Same defect fixed in `edit-tracker.sh` in both the plugin and the live copy** |
| 4 | Medium | unquoted `set -- $1` glob-expanded, freezing `AVK_TEST_EXTRA` to the files present at that instant | `read -ra`; section 12, red first |
| 5 | Medium | a path containing a space was permanently undeclarable, including via the printed remedy | prefix matching in **both** matchers; 5 negative controls hold the boundary |

Finding 3 reached beyond the kit. `edit-tracker.sh`'s version does not fail by leaving the stamp
alone — it clears the **wrong repository's** stamp, fail-open for the repository that was edited
and fail-closed for the one that was not. Invisible in a single-repo session, because there cwd and
the edited repository coincide.

### Four separate instances of "I wrote a check and it did not check"

This is the finding that outlives the five above, so it is recorded as a pattern rather than as four
footnotes:

| Instance | How it failed | How it was caught |
|---|---|---|
| `test-verify-gate-portability.sh` | passed against reverted code | mutation, prompted by `review-tests` |
| The first draft of section 12 | fixture name matched a built-in pattern, so 2 of 4 assertions passed either way | ran it and read the output |
| Section 8 | patterns were `vendor/*` and `*.feature` in a directory containing neither — the environment did the work | noticed while writing section 12 |
| The workflow's own staleness guard | `case` against a multi-line list failed for any filename ending a line; reported 3 listed suites as unlisted | ran it before trusting it |

Not one was caught by reading. Every one was caught by **executing the check against something it
should have rejected.** That is the entire method, and its absence is what produced all four.

### And CI had never run one of the suites

`test-edit-tracker-notebook.sh` was written, committed, and left out of the workflow's explicit
list — nine suites running while ten existed. A control that never runs is worth less than no
control, because its presence is counted as coverage. The list is now guarded: every `test-*.sh`
must be a listed suite or a named implementation file, and the step fails otherwise.

A bare glob is not the alternative. `test-guard.sh` and `test-patterns.sh` are **implementation**
files whose names begin with `test-`, so a glob runs them as suites and they exit 0 having asserted
nothing — and the kit's own classifier calls them `test` while calling their sibling
`check-test-changes.sh` `other`. **That naming is an open finding**, not closed here: the fix is a
rename touching `hooks.json`, the workflow, the README and both suites' defaults.

### Revised numbers

| Field | Was | Now |
|---|---|---|
| controls, this stage | 138 | **173** (68 + 46 + 54 + 5) |
| controls, kit-wide | 362 | **400**, ten suites |
| `ci_seconds` | 17 | 17 |
| `true_positives` | 5 | **5, disputed** — see below |
| `false_positives` | 1 | 1 |
| CI runs observed | 2 | **4** — both jobs on a PR, plus two pushes with the staleness guard |
| plugin installs observed | 0 | **0** |

**`true_positives: 5` remains disputed and unadjusted.** Two of the five are the stale job-name
count and the deprecated `checkout@v4`, neither of which the mechanism caught — they were noticed by
eye while reading CI output. The honest figure is arguably 3. It is left as recorded pending a
human ruling, because silently editing the number that decides verdicts is worse than leaving a
flagged dispute in the record.

### Verdict

| Half | Verdict | Change |
|---|---|---|
| `check-test-changes.sh` (CI) | **`keep`** | **re-earned 2026-09-04.** Awarded prematurely on 2026-09-03 over a live Blocker |
| `test-guard.sh` (hook) | **`blocked`** | unchanged. Still zero plugin installs; nothing has fired from `${CLAUDE_PLUGIN_ROOT}` |

---

## Addendum 4 — the hook half fired from the plugin, 2026-09-04

Stage 1's Addendum 2 carries the full install sequence and the probe table; this addendum records
only what is specific to `guard-test-changes.sh`, because the two stages were blocked by the same
missing observation and it would be dishonest to present one piece of evidence as two.

### What was observed

A fixture repository holding `tests/test_thing.py` (classifies `test`) and `playwright.config.ts`
(classifies `test-config`), both committed. Classifier verdicts checked **before** any probe, so a
refusal could not be confused with a misclassification.

| # | Probe | Condition | Result |
|---|---|---|---|
| 1 | `Edit` `tests/test_thing.py` | before the marketplace was added | **allowed** |
| 2 | same edit | plugin installed, **not** reloaded | **allowed** |
| 3 | same edit | after `/reload-plugins` | **REFUSED** |
| 4 | same edit | after writing the declaration | **allowed** |

Probe 3's refusal, in full attribution:

```
PreToolUse:Edit hook error: [bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-test-changes.sh"]:
EDIT BLOCKED — tests/test_thing.py is a test file and this change is not declared.
```

The harness prefixes the failure with the hook's own command string, so the plugin's copy is named
directly rather than inferred. The fallback discriminator prepared beforehand — that no global hook
on this machine emits `is a test file` or `is test configuration`, verified by `grep` across all
nine global hooks, the rules-engine, `pr-gate.sh` and `loom_hook.py`, **no matches** — held, and
was not needed.

### The printed remedy was executed rather than read

This is the part worth keeping. The refusal prints a copy-pasteable declaration, and Addendum 1
records why that matters: this kit's ancestor shipped a refusal whose documented escape hatch was
wrong about the project it was describing, and the wrong route became the trained one.

So probe 4 did not hand-write a declaration. It ran **the exact two commands the refusal printed**,
unmodified, and retried the identical edit. The edit was allowed. The remedy works, on real output,
from the plugin's copy — not from a fixture reproducing what the remedy is believed to say.

That is the same method as `test-check-test-changes.sh` section 10, applied to the hook half for
the first time.

### What this addendum did NOT determine

- ~~**Whether anyone sees the authorisation.**~~ **ANSWERED the same day: nobody sees it.** Probe 4
  produced no line to the agent, Serina confirmed she saw none either, and the hook was then run
  directly with its output split by file descriptor: **exit 0, 122 bytes on stdout, 0 on stderr.**
  The script is correct and emits exactly what lines 213–222 promise. A `PreToolUse` hook's exit-0
  stdout goes to the **debug log** — *"For most events, Claude Code writes stdout to the debug log
  and doesn't show it in the transcript"*, and `PreToolUse` is not one of the four documented
  exceptions. Moving it to stderr is refuted by the same source: *"Stderr from a hook that exits 0
  goes to the debug log only, never the transcript, and Claude never sees it."*
  Recorded as **`INC-0013`** (medium, `detected_by: human`); sourced write-up with its own declared
  gaps in [`research/claude-code-hook-output-channels.md`](../../research/claude-code-hook-output-channels.md);
  full narrative in trial 1's Addendum 3.
  **This does not downgrade the `keep`.** The verdict is about whether the guard refuses and
  releases correctly, and it does. What is undelivered is a stated *transparency* property, which
  is a separate claim with a separate record. **It remains open** — the fix depends on whether
  `PreToolUse` honours `systemMessage`, which the documentation says is stated per-event in a
  section that could not be retrieved. `could-not-determine`, not absent.
- **`test-config` was never probed.** `playwright.config.ts` sits in the fixture, classifies
  correctly, and **was never edited**. So the `test-config` branch of the refusal — the branch
  written for the `retries: 2` flake response this guard exists to slow down — **has still never
  fired from the plugin.** It is covered by local controls. It is not covered by this observation,
  and the two should not be conflated.
- **`MultiEdit` and `NotebookEdit` were not probed.** `hooks.json` matches
  `Edit|Write|MultiEdit|NotebookEdit`; only `Edit` was exercised. Finding 3 of Addendum 3 was
  precisely a `notebook_path` defect, so the untested matcher is the one with a defect history.
- **Deletion, `rm`, other harnesses, IDEs, humans.** Unchanged and unchangeable — the stated blind
  spot the CI half exists to cover.
- **Whether the declaration friction is tolerable.** Still author-tested only. One declaration was
  written, by the person who designed the format.

### Revised numbers

| Field | Was | Now | Why |
|---|---|---|---|
| **plugin installs observed** | **0** | **1** | |
| hook refusals observed from `${CLAUDE_PLUGIN_ROOT}` | 0 | **1** | probe 3 |
| declaration path exercised end to end | 0 | **1** | probe 4, using the printed remedy verbatim |
| `test-config` refusals observed from the plugin | 0 | **0** | the fixture supports it; it was not run |
| `ci_seconds` | 17 | 17 | unchanged |
| `true_positives` | 5, disputed | **5, still disputed** | see below |
| `false_positives` | 1 | 1 | |
| controls, kit-wide | 400 | 400 | no control added or run here |

**`true_positives: 5` is unchanged and still disputed, for the third record in a row.** Two of the
five — the stale job-name count and the deprecated `checkout@v4` — were noticed by eye while
reading CI output, not caught by the mechanism. The honest figure is arguably 3. Nothing in this
addendum changes the argument either way, and it is **not** being quietly adjusted while a verdict
is being raised in the same edit; that is exactly when a number is easiest to move unnoticed. It
remains a human ruling.

### Verdict

| Half | Verdict | Change |
|---|---|---|
| `check-test-changes.sh` (CI) | **`keep`** | unchanged; re-earned 2026-09-04 in Addendum 3 |
| `guard-test-changes.sh` (hook) | **`keep`** | **`blocked` → `keep` 2026-09-04.** Fired from `${CLAUDE_PLUGIN_ROOT}`, refused an undeclared `test` edit, and allowed the retry after its own printed remedy was run |

Both halves now hold `keep`, and **Stage 3 (`flake-triage`) is unblocked.**

---

## Addendum 5 — the remaining matchers, and `true_positives` ruled, 2026-09-04

### All four matchers are now covered

Addendum 4 recorded that only `Edit` had been probed, and named `test-config`, `MultiEdit` and
`NotebookEdit` as untested. All three have now been run.

| Matcher | Path | How | Result |
|---|---|---|---|
| `Edit` | `tests/test_thing.py` | real tool call | **refused** — `is a test file` |
| `Edit` | `playwright.config.ts` | real tool call | **refused** — `is test configuration` |
| `NotebookEdit` | `tests/test_notebook.ipynb` | real tool call | **refused** — `is a test file` |
| `MultiEdit` | `tests/test_notebook.ipynb` | direct payload | **refused**, exit 2, 914 bytes on stderr |
| `MultiEdit` | `README.md` | direct payload | **allowed**, exit 0, silent — vacuity control |
| `Write` | new `tests/test_notebook.ipynb` | real tool call | **allowed** — creation is free |

`MultiEdit` was probed by payload rather than by a real call because that tool is not in this
agent's toolset. **That is a weaker observation than the other three and is recorded as such**, not
folded in with them.

**The `NotebookEdit` row is the one that mattered.** Addendum 3's finding 3 was a `notebook_path`
defect that let every notebook edit through silently, and until now the fix was covered only by
section 10's synthetic payloads — a suite written against the implementation, which is precisely
the failure mode that let the original defect survive 32 controls. It has now refused a **real**
`NotebookEdit` call routed through the plugin.

Two properties held live rather than in fixtures: the `tests/test_thing.py` declaration did **not**
authorise `playwright.config.ts` (one path per declaration), and creating a new test file was not
blocked even though its path classifies as `test`.

**Still not probed:** deletion via `rm`, and any edit from outside this harness. Unchanged, stated
blind spots, covered by the CI half.

### `true_positives: 5` → `3`

Ruled by Serina 2026-09-04, ending a dispute this record carried for three consecutive addenda. The
rule is now in [`TEMPLATE.md`](TEMPLATE.md#the-numbers): **`true_positives` counts only what the
mechanism caught by firing.**

| # | Finding | Counts? |
|---|---|---|
| 1 | the silenced-warnings fail-open (`2>/dev/null`) | ✅ caught while writing the controls |
| 2 | the added-file disagreement between the halves | ✅ caught by running the mechanism on real history |
| 3 | the printed-remedy double space | ✅ caught by reading the mechanism's own output |
| 4 | the stale `controls (357)` job name | ❌ noticed by eye while reading CI |
| 5 | the deprecated `actions/checkout@v4` | ❌ noticed by eye while reading CI |

Findings 4 and 5 remain in this record as findings. They are real, they were worth fixing, and both
are still described in Addendum 2. What changes is that they no longer inflate the number a later
stage will use as its baseline.

| Field | Was | Now |
|---|---|---|
| `true_positives` | 5, disputed | **3** — ruled, no longer disputed |
| `false_positives` | 1 | 1 |
| everything else | | unchanged |

`REV-0002` and `REV-0004` recorded `true_positives=5` for the CI half; `REV-0008` supersedes the
current one with `3`. Neither verdict changes.

---

## Record it

```bash
<skill>/record.sh --kind review \
  --summary "check-test-changes: keep — failed a real PR with exit 1, naming the path" \
  --tags ci/required-checks,process/verification \
  --field verdict=keep --field mechanism=check-test-changes \
  --field ci_seconds=17 --field false_positives=1 --field true_positives=5 \
  --doc records/trials/2-test-modification-guard.md

<skill>/record.sh --kind review \
  --summary "test-guard hook: blocked — never fired from CLAUDE_PLUGIN_ROOT, no install observed" \
  --tags ci/hooks,process/verification \
  --field verdict=blocked --field mechanism=test-guard-hook \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=0 \
  --doc records/trials/2-test-modification-guard.md

<skill>/record.sh --kind note \
  --summary "a weakened suite still goes green: CI passed on a branch whose tests cannot fail" \
  --tags ci/flaky-tests,process/verification \
  --doc records/trials/2-test-modification-guard.md
```

The hook half's `blocked` above is superseded 2026-09-04. Left in place rather than edited, for the
same reason the rest of this file keeps its history: `query.sh --open` can only close an incident
via a superseding event, so an edited line would vanish from the record and an overwritten verdict
would look like it was never in doubt.

```bash
<skill>/record.sh --kind review \
  --summary "guard-test-changes hook: keep — refused an undeclared test edit from CLAUDE_PLUGIN_ROOT, and its printed remedy cleared it" \
  --tags ci/hooks,process/verification \
  --field verdict=keep --field mechanism=test-guard-hook \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=0 \
  --doc records/trials/2-test-modification-guard.md

<skill>/record.sh --kind note \
  --summary "adding a marketplace is not installing a plugin: all 19 hook files were on disk and none was wired" \
  --tags ci/hooks,process/verification \
  --doc records/trials/1-evidence-required-completion.md

<skill>/record.sh --kind note \
  --summary "plugin hooks load on /reload-plugins, not at install and not only at session start" \
  --tags ci/hooks,process/verification \
  --doc records/trials/1-evidence-required-completion.md
```
