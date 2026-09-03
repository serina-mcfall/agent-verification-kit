# Trial — evidence-required completion, delivered as a plugin

**Stage** 1 · **Started** 2026-09-03 · **Closed** 2026-09-04
**Where** `serina-mcfall/agent-verification-kit` · **Verdict** `keep`

> **Was `blocked` until 2026-09-04.** It turned on one number — plugin installs observed — and that
> number was zero from the day this record was opened. It is now 1. **See Addendum 2.**

---

## What this mechanism is meant to catch

A commit made without a fresh, passing test run behind it.

## What was set up

A new public repository, structured as a Claude Code plugin marketplace with one plugin.

```
agent-verification-kit/
├── .claude-plugin/marketplace.json
└── plugins/agent-verification-kit/
    ├── .claude-plugin/plugin.json          version 0.1.0
    └── hooks/
        ├── hooks.json                      PreToolUse:Bash, PostToolUse:Bash,
        │                                   PostToolUse:Edit|Write|MultiEdit|NotebookEdit
        ├── stamp-path.sh      9.8K   sourced library — resolves WHICH repo's stamp
        ├── post-bash.sh      28.4K   writes the stamp (elapsed-time tail dropped)
        ├── edit-tracker.sh    3.8K   clears the stamp of the edited file's repo
        ├── verify-gate.sh    21.1K   reads it; blocks the commit
        ├── check-models.sh    7.2K   static agent-roster check
        └── test-*.sh          6 files
```

Five scripts adopted from `~/Launchpad/serina-learning/.claude/hooks/global/` (four) and
`~/Launchpad/serina-skills/test/` (`check-models.sh`).

### Why all five, when only one is the gate

`verify-gate.sh` only **reads** the stamp. Packaging it alone produces a plugin that blocks every
commit forever, because nothing in it ever writes one. Established by reading the source, not by
running it:

| Script | Role in the protocol |
|---|---|
| `post-bash.sh` | writes `<repo>/.claude/.verified` on a passing test/build command |
| `edit-tracker.sh` | deletes it when a file changes |
| `verify-gate.sh` | refuses `git commit` when it is absent or >30m old |
| `stamp-path.sh` | hard dependency of all three — `verify-gate.sh:103-129` sources it and **fails closed** on a commit if unreadable |
| `check-models.sh` | invoked by `verify-gate.sh`'s roster branch, which also fails closed |

### Three deliberate modifications

> **Corrected 2026-09-04.** This section said **two** until Serina's review found a third. The count
> is load-bearing — it is what a reviewer uses to bound what they must read — so it is corrected
> here rather than left for someone to discover by diffing.

1. **`post-bash.sh` truncated to its stamp section** (source lines 1–459 plus `exit 0`). The
   dropped tail (461–492) was session elapsed-time reporting: unrelated to verification, touching
   only `.session-tracker`, and — checked before cutting — covered by **zero** controls in
   `test-post-bash.sh`. No test was weakened to make this cut.
2. **`CHECK_MODELS` default changed** from `$HOME/.claude/hooks/check-models.sh` to a sibling
   lookup. That path is the original author's personal symlink layout; no adopter has it, and the
   branch consuming it fails closed. An adopter's first commit touching `.claude/agents/*.md` would
   have been refused, citing a file they had never heard of. **A gate that cannot be satisfied is
   not a gate; it is a lockout.**
3. **`edit-tracker.sh` now reads `notebook_path` as well as `file_path`** — added 2026-09-04 from
   the review. NotebookEdit's target lives under `notebook_path`, so the hook fell to its cwd
   fallback and cleared the **wrong repository's** stamp: fail-open for the repository that was
   edited, fail-closed for the one that was not. Covered by `test-edit-tracker-notebook.sh`,
   confirmed red first. The same one-line fix was applied to the live copy in `serina-learning`, so
   the two do not diverge.

## What was thrown at it

| # | Input | Expected | Actual | ✅/❌ |
|---|---|---|---|---|
| 1 | `test-stamp-path.sh` — repo scoping, `-C`/`cd` extraction, decoy messages, unexpanded `$HOME`/`~` | 25 pass | 25 pass, 0 fail | ✅ |
| 2 | `test-verify-gate.sh` — scoping fail-open, stale stamp, missing resolver, roster, non-vacuity | 20 pass | 20 pass, 0 fail | ✅ |
| 3 | `test-post-bash.sh` — 148 controls incl. heredocs, ANSI-C quoting, backticks, `--help`/`--collect-only`, prose naming a suite | 148 pass | 148 pass, 0 fail | ✅ |
| 4 | `test-edit-tracker.sh` — clears the *edited* repo, ancestor walk, `nofallback` | 12 pass | 12 pass, 0 fail | ✅ |
| 5 | `test-check-models.sh` — the 2026-08-06 fail-open, unclosed frontmatter, a11y tier floor | 16 pass | 16 pass, 0 fail | ✅ |
| 6 | **`test-verify-gate-portability.sh`** — new; the `CHECK_MODELS` default with no override | 3 pass | 3 pass, 0 fail | ✅ |
| 7 | **The plugin actually delivering these hooks** | a commit is blocked *by the plugin's copy* | **NOT RUN** | ⚠️ |

**Total: 224 controls, 0 failing.**

Row 7 is the one that matters and it is the one that did not happen. See *What this trial could NOT
determine*.

On row 6 — the reason it had to be written: every pre-existing roster control injects
`CHECK_MODELS` explicitly (`test-verify-gate.sh:176,210`), so the default was exercised by nothing.
Both outcomes of that branch are `exit 2`, so a control asserting on the exit code would have
passed whether the fix worked or not. It asserts on which message came out, and carries a vacuity
guard proving a valid roster is *not* refused.

---

## What happened

### ✅ What was great

- **The adopted suites are strong, and they are strong in the right direction.** 148 controls on
  `post-bash.sh` alone, most of them adversarial: a suite named in a heredoc, in a multi-line PR
  body, behind ANSI-C quoting, inside `$( )`, after an escaped quote. Every one asserts it does
  **not** stamp. That is a reward-signal defence tested by someone trying to defeat it.
- **Each suite carries an explicit vacuity guard** — `test-post-bash.sh`'s first control is *"a
  bare passing suite stamps (guard against a vacuous suite)"*, `test-check-models.sh` control B
  refuses to report clean on an empty directory. Tests that can fail.
- **The scripts resolve their own siblings via `readlink -f "${BASH_SOURCE[0]}"`**, which is why
  they transplanted into a plugin without touching the resolution logic. `${CLAUDE_PLUGIN_ROOT}`
  gives a real path, `readlink -f` returns it unchanged, `dirname` finds the siblings.

### ⚠️ What needs work

- **The delivery mechanism is unproven** (row 7). Everything here tests the *scripts*. Nothing yet
  tests that a plugin install puts them where Claude Code will run them.
- **`plugin.json` carries a `version` and nothing enforces it.** Version `0.1.0` is a string a
  human types. There is no signing, no digest, no provenance — the README says so, but saying so is
  not a control.

### ❌ What broke

Nothing. No control failed at any point.

One thing was *found* rather than broken: the `CHECK_MODELS` default. It was a live portability
defect in the adopted source — it would not have failed for the author, only for every adopter.

### 🗑️ What should go

`post-bash.sh`'s elapsed-time section, already dropped. Reason recorded above: unrelated to
verification, untested, and it would have made the plugin ship a feature at odds with what it
claims to be.

---

## The numbers

| Field | Value | Notes |
|---|---|---|
| `ci_seconds` | 0 | no CI yet; all six suites run locally in a few seconds |
| `true_positives` | 1 | the `CHECK_MODELS` portability defect, found by reading before packaging |
| `false_positives` | 0 | nothing fired wrongly |
| controls observed | 224 | across six suites, 0 failing |
| **plugin installs observed** | **0** | **the number this verdict turns on** |

---

## What this trial could NOT determine

- **Whether the plugin delivers the hooks at all.** `/plugin install` was never run, so no hook has
  ever fired from `${CLAUDE_PLUGIN_ROOT}`. The `hooks.json` shape was copied from an official
  installed plugin (`claude-plugins-official/security-guidance`), which makes it *plausible*, not
  *tested*. Structural similarity to something that works is not evidence that this works.
- **Whether the hooks load without a session restart.** Unknown; hooks are read at session start.
- **What happens when the plugin's copies run alongside the author's existing global symlinks.**
  Expected to be idempotent — both read and write the same stamp file — but expected is not
  observed, and duplicate `PostToolUse` writers is exactly the shape that produced the 2026-08-10
  cross-session stamp deletion.
- **Whether a genuine adopter can install and use it.** No second machine, no second account, no
  repository other than the author's. The portability *defect* was found by reading; portability
  itself is untested.
- **Whether the failure messages read clearly to someone who did not write them.** Author-tested
  only.
- **Anything about the `inferred` premise.** The README states that most stamps are `inferred`
  because the harness sends no exit code, and that a red suite could therefore unlock the gate if
  `PostToolUse` ever fires on a non-zero exit. `test-post-bash.sh` tests the *handling* of an
  absent exit code; it cannot test whether the harness's behaviour will hold.

---

## Verdict

**`blocked`** — and the distinction is worth stating precisely, because it would be easy and wrong
to call this `keep`.

**The mechanism is proven. The delivery is not.** 224 controls, zero failures, and a real defect
caught before it shipped — that is a strong result for the *scripts*, and they were already strong
before this trial, having been hardened against six recorded bypasses over the preceding month.
What this stage set out to establish is something different: that a **plugin** can carry a working
hook onto a machine. Zero plugin installs have been observed. The number of times these hooks have
fired from `${CLAUDE_PLUGIN_ROOT}` is zero.

`blocked`, not `fix`: there is no named defect to repair. There is an unrun test.

**What would settle it** — in order:

1. `/plugin marketplace add serina-mcfall/agent-verification-kit`, then
   `/plugin install agent-verification-kit@agent-verification-kit`, then restart the session.
2. In a scratch repository, edit a file and attempt `git commit -s`. Expect a refusal naming
   `<repo>/.claude/.verified`.
3. Confirm the refusal came from the **plugin's** copy and not the author's global symlink —
   temporarily unset the global wiring, or compare the stderr against a plugin-only marker.
4. Run the suite, then commit in a separate call. Expect the unlock line to name the suite that
   earned it.

Step 3 is the one that can produce a false `keep`. With the author's global hooks live in the same
session, a commit will be blocked whether the plugin works or not — and reading that block as proof
of the plugin is precisely the "absent data read as confirmation" error recorded as INC-0006.

---

## Addendum — Serina's review, 2026-09-04

### One of this trial's own controls could not fail

Row 6 of *What was thrown at it* credits `test-verify-gate-portability.sh` with 3 controls and
says it exists because the `CHECK_MODELS` default "was exercised by nothing". **That control was
itself exercising nothing.** Confirmed by mutation: the fix was reverted in a copy of the hooks
directory, this suite was run against it, and it reported **3 passed / 0 failed**.

The cause is specific. On this machine `$HOME/.claude/hooks/check-models.sh` exists and is
executable — it is the very symlink the plugin was extracted from — so the old expression and the
new one both resolved to a working checker, both produced the same message, and the assertion held
either way. The control measured *"some checker was found"*, never *"the sibling was found"*.

**So this trial's headline of "224 controls, 0 failing" was three controls weaker than it read.**
Not wrong about the other 221, but the one control written specifically to cover a modification was
the one that could not detect its reversal.

The sharpest part is that this file already recorded the reasoning that should have prevented it —
*"both outcomes are `exit 2`, so a control asserting on the exit code would have passed whether the
fix worked or not"* — and the same error was then made one level up: asserting on which **message**
came out rather than on which **file** produced it. Diagnosing a pattern in a comment is not the
same as not repeating it.

Closed by isolating `HOME` for every gate invocation, and by baking the mutation into the suite:
a copy carrying the old default is built at run time, with a working sibling beside it, and asserted
to report `not-found`. Verified both directions — **6 passed / 0 failed** against current code,
**3 passed / 2 failed, exit 1** against reverted code.

### A third modification to adopted code

`edit-tracker.sh` now reads `notebook_path` as well as `file_path`. Recorded in the modifications
list above, with the count corrected from two to three.

### Revised numbers

| Field | Was | Now | Why |
|---|---|---|---|
| controls in this trial's own portability suite | 3 | **6** | plus a baked-in mutation |
| `true_positives` | 1 | **1** | deliberately unchanged — see below |
| `false_positives` | 0 | 0 | |
| plugin installs observed | 0 | **0** | unchanged, and still what the verdict turns on |

**`true_positives` is deliberately not incremented.** The vacuous control and the `edit-tracker`
key were found by review, not caught by the mechanism. That field means "real problems this
mechanism caught", and padding it with things a reader found by eye corrupts the one number this
record's own template says decides most verdicts. The same objection applies to Stage 2's count of
5, and is flagged there for a human ruling rather than silently adjusted.

### Verdict — unchanged

**Still `blocked`.** Nothing here has fired from `${CLAUDE_PLUGIN_ROOT}`; zero plugin installs have
been observed. The review improved the evidence behind the *scripts* and changed nothing about the
*delivery*, which is the only thing this verdict was ever about.

---

## Addendum 2 — the plugin was installed, 2026-09-04

The unrun test has been run. Everything below was observed in one session, in order.

### What was actually done

| # | Action | Observed |
|---|---|---|
| 1 | `/plugin marketplace add serina-mcfall/agent-verification-kit` | `known_marketplaces.json` gained the entry, `2026-09-03T21:39:12Z`; repo cloned to `~/.claude/plugins/marketplaces/agent-verification-kit` with all 19 hook files |
| 2 | `/plugin install agent-verification-kit@agent-verification-kit` | `installed_plugins.json` went from 12 entries to 13; payload cached at `.../cache/agent-verification-kit/agent-verification-kit/0.1.0/hooks/` |
| 3 | `/reload-plugins` | reported `11 plugins · 5 skills · 15 agents · 7 hooks · 5 plugin MCP servers` |

**Adding a marketplace is not installing a plugin, and the difference is visible on disk.** After
step 1 every hook file was present and none of them was wired. Had the trial stopped there and read
"the files are on the machine" as "the plugin is active", it would have recorded a pass for
something that was doing nothing — the same shape as INC-0006.

### The probe sequence

The claim being tested is *"the plugin delivers a working hook"*. A single block proves nothing,
because this machine's global hooks are live in the same session. So the block was bracketed by
allows, with exactly one variable moving.

| # | Probe | Condition | Result |
|---|---|---|---|
| 1 | `Edit` an existing test file | before the marketplace was added | **allowed** |
| 2 | `Edit` an existing test file | installed, **not** reloaded | **allowed** |
| 3 | `Edit` an existing test file | after `/reload-plugins` | **BLOCKED** |
| 4 | `Edit` an existing test file | after writing the declaration | **allowed** |
| 5 | `git commit` with no fresh stamp | after `/reload-plugins` | **BLOCKED** |
| 6 | suite, then `git commit` in a separate call | after `/reload-plugins` | **allowed** — commit `5577dfb` |

Probes 1, 2 and 4 are the reason 3 and 5 mean anything. Three allows around two denies, and the
only thing that changed between 2 and 3 was the reload.

### Attribution came from the harness, not from inference

The trial's own *"What would settle it"* step 3 anticipated needing to unset the global wiring or
hunt for a plugin-only marker, because a commit would be refused whether the plugin worked or not.
Neither was necessary. **Claude Code prefixes a hook failure with the hook's own command string:**

```
PreToolUse:Edit hook error: [bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-test-changes.sh"]: EDIT BLOCKED — …
PreToolUse:Bash hook error: [bash "${CLAUDE_PLUGIN_ROOT}/hooks/verify-gate.sh"]: COMMIT BLOCKED — …
```

That is direct evidence, not evidence by elimination. The string discriminator prepared beforehand
— that no global hook of this machine emits `is a test file` — was verified and then not needed.
It is recorded here anyway, because it was the fallback and it held: `grep` across all nine global
hooks, the rules-engine, `pr-gate.sh` and `loom_hook.py` returned **no matches**.

The same run also produced a clean before/after on one hook:

| | Hook that refused the commit | Stamp path it resolved |
|---|---|---|
| Before the install | `/home/serina/.claude/hooks/verify-gate.sh` | `/home/serina/.claude/.verified` — a **fallback**, the repository did not resolve |
| After the reload | `bash "${CLAUDE_PLUGIN_ROOT}/hooks/verify-gate.sh"` | the fixture repository's own `.claude/.verified` |

### Three of the plugin's hooks are confirmed firing

| Script | Role | Evidence |
|---|---|---|
| `verify-gate.sh` | reads the stamp, refuses | probe 5 — refusal prefixed with `${CLAUDE_PLUGIN_ROOT}` |
| `post-bash.sh` | writes the stamp | stamp written after the suite ran, contents below |
| `guard-test-changes.sh` | refuses an undeclared test edit | probe 3 — refusal prefixed with `${CLAUDE_PLUGIN_ROOT}` |

The stamp `post-bash.sh` wrote:

```
1788471846|python3 tests/test_thing.py|inferred
```

Command recorded, basis recorded, and `inferred` exactly as the README says to expect while the
harness sends no exit code. The full protocol — refuse, earn, allow — completed end to end through
the plugin's copies.

### A question this record listed as undeterminable is now answered

*"Whether the hooks load without a session restart. Unknown; hooks are read at session start."*

**They load on `/reload-plugins`, and no session restart is needed.** They are not wired by the
install itself — probe 2 is the control that establishes this, and the harness says so in its own
install output (*"Run /reload-plugins to apply"*). This belongs in the README's install section,
which currently says nothing about either.

### The fixture

A throwaway git repository holding `tests/test_thing.py` (classifies `test`) and
`playwright.config.ts` (classifies `test-config`), both committed, plus a non-test `README.md` as a
vacuity guard. Classifier verdicts were checked directly before any probe ran, so a block could not
be mistaken for a misclassification.

### What this addendum still could NOT determine

- ~~**Whether the plugin's non-blocking stdout reaches anyone.**~~ **ANSWERED the same day — it
  reaches nobody. See Addendum 3 and `INC-0013`.** The question as originally written is left below
  because the shape of it is the point: it was recorded as unresolved rather than assumed either
  way, and the answer came from asking the operator and then measuring, not from either of us
  guessing.
  > `guard-test-changes.sh:213-222` is written to announce *"this change is declared — <reason>.
  > Allowed."* at the moment an authorisation is relied upon, and `verify-gate.sh` is written to
  > name the suite that earned a stamp. **Neither line was seen** on probe 4 or probe 6. The agent
  > does not receive allow-path stdout; whether the human operator sees it is **unresolved and
  > asked of Serina, unanswered at time of writing.** If she saw nothing either, then *"say what
  > authorised it"* is a documented design property that is not delivered — and this file's own
  > argument is that an authorisation nobody sees is indistinguishable from no gate. **That would
  > be a named defect and a `fix`, and it is deliberately not being written up as one until the
  > question is answered.**
- **Whether two copies of a hook both run.** Duplicate stderr was predicted. Only the plugin's
  message appeared on both denials. Either the first denial short-circuits the chain or the global
  copy did not run — **not determined**, and worth knowing before the README tells adopters what
  running both looks like.
- **Which copy of `edit-tracker.sh` cleared the stamp.** It was cleared, correctly. Both copies
  write the same path, so the observation cannot be attributed. The plugin's copy is therefore
  **unconfirmed**, and it is the one hook of the four whose delivery is still only inferred from
  its siblings.
- **Anything about a genuine adopter.** One machine, one account, one operator, and that operator
  wrote the code. Portability is exactly as untested as it was before this addendum.
- **Whether the refusal messages read clearly to someone who did not write them.** Unchanged.
- **The `inferred` premise.** Unchanged. The stamp written in this session is `inferred`, which is
  the premise being rested on rather than evidence for it.
- **Minor, unexplained:** `/reload-plugins` reported **11 plugins** while `installed_plugins.json`
  lists **13**. Not investigated. Recorded rather than dropped, because "a count that does not
  match the registry" is the shape of the stale-job-name defect in Stage 2.

### Revised numbers

| Field | Was | Now | Why |
|---|---|---|---|
| **plugin installs observed** | **0** | **1** | the number this verdict always turned on |
| hooks fired from `${CLAUDE_PLUGIN_ROOT}` | 0 | **3** | `verify-gate.sh`, `post-bash.sh`, `guard-test-changes.sh` |
| `ci_seconds` | 0 | 0 | unchanged; this stage's CI is Stage 2's workflow |
| `true_positives` | 1 | **1, disputed** | unchanged. Nothing here was caught *by the mechanism*; the delivery finding was produced by running a planned probe. Padding this field is what Addendum 1 refused to do and this one refuses too |
| `false_positives` | 0 | 0 | |
| controls observed | 224 | 224 | no control was added or run in this addendum |

### Verdict — `blocked` → `keep`

The mechanism was already proven. The delivery now is: a plugin install was observed, and three of
this stage's hooks have fired from `${CLAUDE_PLUGIN_ROOT}`, refusing and then allowing a commit on
the evidence the protocol is built on.

`keep` rather than `fix`, because no defect in the mechanism was found. The stdout-visibility
question above is real and is **open**, not resolved in the mechanism's favour — if answered badly
it warrants its own `fix`, and this verdict should be revisited rather than defended.

---

## Addendum 3 — the allow path reaches nobody, 2026-09-04

Addendum 2 left one question open and refused to resolve it in the mechanism's favour. Serina
answered it the same day: **she saw none of the text either.** Two absences are not a finding, so
the claim was then measured rather than concluded.

### What was measured

Both hooks were invoked directly with synthetic payloads, stdout and stderr captured to separate
files and counted in bytes.

| Case | exit | stdout | stderr |
|---|---|---|---|
| undeclared `test-config` path | `2` | 0 bytes | **1009 bytes** |
| declared, fresh, `test` path | `0` | **122 bytes** | 0 bytes |

```
test-guard: test change to tests/test_thing.py is declared — "…". Allowed.
```

**The scripts are correct.** They emit precisely what their comments promise, on stdout, at exit 0.
`verify-gate.sh:387-389` has the same shape — 11 of its 31 `echo`s are unredirected.

### The first attempt at this measurement was wrong, and the control caught it

The first run sent a payload carrying `tool_input.file_path` but **no `tool_name`**. Both cases
exited 0 in silence, which read exactly like "the hook is mute on both paths" — a plausible,
tidy, wrong conclusion.

It was caught because the *undeclared* case was run as a control and had to block. It didn't.
`guard-test-changes.sh:94-97` matches `tool_name` against its four tools and exits 0 for anything
else, so the whole probe had been standing the hook aside. **A measurement of an allow path is
worthless without a deny control beside it**, and that is the same lesson as the four instances in
Stage 2's Addendum 3 — the check that cannot fail.

### Why it reaches nobody, from the documentation

Full sourced note, with verbatim quotations and its own gaps declared:
[`research/claude-code-hook-output-channels.md`](../../research/claude-code-hook-output-channels.md).

> "For most events, Claude Code writes stdout to the debug log and doesn't show it in the
> transcript."

> "The exceptions are `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, and
> `PostModelSwitch`…"

`PreToolUse` is not among them.

**The obvious fix is refuted by primary source before anyone spent a commit on it:**

> "Stderr from a hook that exits 0 goes to the debug log only, never the transcript, and Claude
> never sees it."

So moving the announcement to stderr changes nothing. It is the **exit code**, not the stream, that
decides visibility. Had that not been checked, the "fix" would have been a second invisible message
and this record would have carried a closed finding that was still open.

The documented mechanism is `systemMessage` in JSON output — *"To surface a message to the user on
any platform, return `systemMessage` in JSON output. Some events discard it or deliver it elsewhere,
and each event's section says so."* **Whether `PreToolUse` is one of the events that discards it is
`could-not-determine`:** the page was fetched three times and truncated at the same point each
time, before the per-event sections.

### Recorded, not fixed

`INC-0013`, medium, `detected_by: human` — Serina's question is what found it. Refs `REV-0005` and
`REV-0006`.

**It does not reopen either verdict.** `keep` was earned on whether the mechanism refuses and
releases correctly, and it does, observed six ways. What is broken is a *stated design property*,
which is a different claim and gets its own record rather than being folded into a reversal. If a
reader disagrees, the disagreement is visible here rather than hidden in an unexplained verdict.

**Open, and deliberately not prescribed:** the fix depends on whether `PreToolUse` honours
`systemMessage`, which is unestablished. The research note names two ways to settle it — read the
untruncated reference, or wire a throwaway hook emitting a unique marker and look for it. Until one
of those happens, the comments in both files claim a property the harness does not deliver, and
`guard-test-changes.sh`'s own argument currently indicts the file it is written in.

---

## Addendum 4 — `true_positives` ruled, 2026-09-04

Serina ruled on the dispute this record has carried since Addendum 1. **`true_positives` counts only
what the mechanism caught by firing.** The rule is now written into
[`TEMPLATE.md`](TEMPLATE.md#the-numbers) rather than argued again per stage.

### `true_positives: 1` → `0`

The `1` was the `CHECK_MODELS` portability defect. This record's own words, unchanged since it was
written: *"found by reading before packaging."* That is review working, not the mechanism working,
and it is the **same category** as the two findings Stage 2's count was disputed over.

The inconsistency is what forced the ruling. Stage 2's `5` was disputed on the grounds that
eye-caught findings should not count, while Stage 1's `1` — an eye-caught finding — went undisputed
in the same programme. The field meant two different things in two adjacent files, which is worse
than either meaning.

**A `0` here is not a failure and should not be read as one.** Nothing in Stage 1 was ever given to
this mechanism to catch: it was trialled against controls and a fixture, never run against a real
attempt to commit without testing. `keep` was earned on delivery evidence and 224 controls, and none
of that changes.

| Field | Was | Now |
|---|---|---|
| `true_positives` | 1, disputed | **0** — ruled, no longer disputed |
| `false_positives` | 0 | 0 |
| everything else | | unchanged |

`REV-0005` is superseded by `REV-0007` carrying the corrected figure. The earlier events stay in the
record; the number moved once, in the open, with the reasoning attached.

---

## Record it

```bash
<skill>/record.sh --kind review \
  --summary "evidence-required completion as a plugin: blocked — scripts proven, delivery never run" \
  --tags ci/hooks,process/verification \
  --field verdict=blocked --field mechanism=evidence-required-completion \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=1 \
  --doc records/trials/1-evidence-required-completion.md
```

Superseded 2026-09-04 by the install. The original above is left in place because the record is
append-only and a verdict that changed is more informative than a verdict that was edited:

```bash
<skill>/record.sh --kind review \
  --summary "evidence-required completion as a plugin: keep — installed, reloaded, 3 hooks fired from CLAUDE_PLUGIN_ROOT" \
  --tags ci/hooks,process/verification \
  --field verdict=keep --field mechanism=evidence-required-completion \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=1 \
  --doc records/trials/1-evidence-required-completion.md
```
