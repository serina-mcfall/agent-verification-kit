# Trial — evidence-required completion, delivered as a plugin

**Stage** 1 · **Started** 2026-09-03 · **Closed** — open
**Where** `serina-mcfall/agent-verification-kit` · **Verdict** `blocked`

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

## Record it

```bash
<skill>/record.sh --kind review \
  --summary "evidence-required completion as a plugin: blocked — scripts proven, delivery never run" \
  --tags ci/hooks,process/verification \
  --field verdict=blocked --field mechanism=evidence-required-completion \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=1 \
  --doc records/trials/1-evidence-required-completion.md
```
