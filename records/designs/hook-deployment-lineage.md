# Design — which repository owns the hooks that actually run

**Refs** `INC-0034`, `INC-0033`, `INC-0031`, `INC-0014`, `NOTE-0037` · **Branch** `docs/verify-gate-findings-from-reconciliation` · **Started** 2026-09-17 (UTC)
**Status** decided 2026-09-17 — **the kit owns them**. Eight files deployed and matching; two follow-ups open

> `INC-0034` closed its own record with *"deciding which copy should exist is a workspace question,
> not a change to this repository."* This document is that question, written down with the
> measurements it needs, so it can be decided once instead of re-discovered every time a hook is
> fixed.

---

## What was actually wrong, and it was not staleness

`NOTE-0037` recorded the deployed `verify-gate.sh` as a **stale copy**. Measured again on
2026-09-17, nine days later, that diagnosis is incomplete in a way that matters.

The deployed file was **byte-identical to `origin/main` of a different repository**. It was not
behind anything. It was current — in the wrong lineage.

| | Repository | `verify-gate.sh` | `INC-0033` fix | announce channel |
|---|---|---|---|---|
| deployed until today | `launchpad-26/serina-learning` | 379 lines | **no** | **no** |
| the kit | `serina-mcfall/agent-verification-kit` | 571 lines | yes | yes |

`serina-hooks`, `serina-learning` and `serina-git-safety-single-pattern` are three working copies of
**one** repository. That is why the file looked like it had many copies and one history: it has two
histories, in two repositories, and the count of checkouts hid it.

**Consequence, measured rather than inferred:** `INC-0033` merged on 2026-09-07 and governed nothing
on this machine until 2026-09-17. Ten days. Every session in that window — and several run
concurrently — was gated by a copy that refuses prose merely naming a commit.

## Why the usual check could not have caught it

`NOTE-0037` already names this and it is worth repeating here, because it is the reason the drift
survived a deliberate look: grepping `verify-gate.sh` for the phrase **"command position"** reports
a match on the *unfixed* file. The phrase appears in the file's description of the original defect
as well as in the fix.

A check that cannot distinguish the two states is not a check. Use line count plus a behavioural
probe:

| Payload `.tool_input.command` | Stale copy | Fixed copy |
|---|---|---|
| `echo "remember to git commit later"` | BLOCKED | **ALLOWED** |
| `git commit -m x` (unstamped) | BLOCKED | BLOCKED |
| `git -C /tmp/x commit -m x` (unstamped) | BLOCKED | BLOCKED |
| `git log --grep commit` | ALLOWED | ALLOWED |

## What is deployed now

Deployed 2026-09-17 from the kit's `main`, with the before/after probe above run against the live
file. Pre-deploy copy kept at `~/.claude/hooks-backup-2026-09-17/verify-gate.sh.before`.

| File | Before | After | |
|---|---|---|---|
| `verify-gate.sh` | 21111 B (learning) | 32292 B (kit) | deployed today |
| `announce.sh` | **absent** | 4089 B (kit) | added today — required |
| `stamp-path.sh` | 9786 B | unchanged | already the kit's |
| `check-models.sh` | symlink → `serina-skills` | unchanged | content matches |
| `post-bash.sh` | 29220 B (learning) | unchanged | **still divergent** |
| `edit-tracker.sh` | 8480 B (learning) | unchanged | **still divergent** |

`announce.sh` was not optional. The kit's gate resolves its siblings with
`dirname "$(readlink -f "${BASH_SOURCE[0]}")"`, so without a copy beside the deployed gate the
library is simply missing and every announcement falls back to stderr — the channel `NOTE-0032`
measured as reaching nobody. The gate would have looked fixed and announced into the void.

## The two files still divergent, and which way they point

Both were checked line by line rather than by size, because size misleads here: the kit's
`post-bash.sh` is *smaller* while being *ahead*, since it extracts logic into
`classify-test-commands.sh` and `flake-ledger.sh`.

**The kit is ahead on every verification concern:**

- the `announce` channel, in both files — the deployed copies use `echo … >&2` throughout, which
  `NOTE-0032` measured as reaching nobody. These are the fail-open warnings: the messages that say
  a gate has stopped guarding you.
- `edit-tracker.sh` reads `notebook_path` as well as `file_path`. **This one is a live defect in the
  deployed copy**, not a missing nicety: a `NotebookEdit` falls through to the cwd fallback and
  clears the **wrong repository's** stamp — fail-open for the repository that was edited.
- `post-bash.sh` gains the flake ledger, which is documented in the kit's own README as **inert**
  (`INC-0024`: the harness sends no `PostToolUse` event for a failing command). Deploying it adds a
  layer that does not fire; it does not add one that misfires.

**The learning lineage is ahead on exactly one thing, and it was dropped on purpose:** session
elapsed-time reporting (`.session-tracker`, source lines 461–492). `trials/1-evidence-required-completion.md`
records the cut — *"unrelated to verification, touching only `.session-tracker`, and — checked
before cutting — covered by zero controls."* So it is an intentional scope decision, not an
oversight, and adopting the kit's copy loses a convenience feature rather than a control.

**A `post-bash.sh` deploy is a three-file deploy.** `classify-test-commands.sh` and `flake-ledger.sh`
are both **absent** from `~/.claude/hooks`. Deploying `post-bash.sh` alone would source neither, and
the kit's own code would announce that flake detection is not enforcing.

## The decision

Which repository owns the hooks under `~/.claude/hooks`?

**Option A — the kit owns them.** Finish the deployment: `post-bash.sh`, `edit-tracker.sh`,
`classify-test-commands.sh`, `flake-ledger.sh`. Retire the `.claude/hooks/global/` copies in
`serina-learning` so there is one source. Costs the session timer unless it is ported.

**Option B — the kit owns them, timer ported first.** As A, but the elapsed-time reporting moves
into the kit — as its own hook, not back inside `post-bash.sh`, since the trial cut it for mixing
concerns. Delays the `edit-tracker.sh` fix behind unrelated work.

**Option C — leave it split, deliberately.** `verify-gate.sh` from the kit, the rest from
`serina-learning`. This is the state as of today. It is the only option that requires writing down
which file comes from where, because nothing on disk records it and the next refresh reverts by
default.

**What none of these options may be:** silent. `INC-0031` and `INC-0014` are both open on deployed
copies drifting with nothing watching. Whichever is chosen needs a check that compares deployed
bytes against the owning repository and fails loudly — the kit gates commits, test edits and flaky
passes, and does not yet gate its own deployment.

### Decided 2026-09-17 — Option A, the kit owns them

Chosen by Serina. What decided it was not tidiness: the deployed `edit-tracker.sh` carried a live
fail-open defect, and the only thing the other lineage held uniquely was a convenience feature its
own trial had already cut on purpose. Weighing a stamp cleared on the wrong repository against
elapsed-time reporting is not a close call.

`post-bash.sh`, `edit-tracker.sh`, `classify-test-commands.sh` and `flake-ledger.sh` deployed the
same day, after enumerating the dependency closure first — the last two are libraries the first two
source, and deploying without them would have made the kit's own code announce that flake detection
was not enforcing. All eight files under `~/.claude/hooks` now match the kit's `main` byte for byte.

Verified end to end rather than by file comparison alone: the stamp was deleted and re-earned by the
newly deployed `post-bash.sh`, and the suite ran green against exactly these bytes.

**Open, and deliberately not done here:**

1. ~~**The deployment check.**~~ **Built 2026-09-17** — `check-deployment.sh`, 18 controls in
   `test-check-deployment.sh`, run by `make test` after the suites. It catches drift and the
   silent-degradation case of a sourced sibling that was never deployed. Verified against the real
   artefacts rather than fixtures alone: run against the deployment as it stood that morning,
   reconstructed from the backups, it reports all three drifted files; run against a
   `verify-gate.sh`-without-`announce.sh` layout, it names the missing sibling. `make test` exits
   non-zero in both cases, so the stamp is not earned and the commit is refused.

   Local only, deliberately: a CI runner deploys nothing and would exit 0 on an empty answer every
   time, which reads as coverage it does not have.

   What it does **not** do is check the plugin cache under `~/.claude/plugins/cache/`, which
   `INC-0034` observed also firing. Measured on 2026-09-17 before assuming that was a gap worth
   closing the same way: the cache holds **six** versions — 0.1.0, 0.4.0, 0.5.1, 0.5.2, 0.6.0,
   0.6.1 — and `main` ships 0.6.1, whose cached copy matches it byte for byte. The marketplace
   checkout matches too.

   So the active plugin copy is current, and the five older ones differ from `main` **correctly**:
   they are pinned releases, not deployments. Pointing this check at them reports four or five
   drifted files each, and every one of those is a false positive. A cache check is therefore a
   different mechanism, not a wider glob on this one — it would have to resolve which version is
   active and compare against **that version's tag**. Left undone deliberately rather than bolted
   on, because a check that cries wolf on correctly-pinned releases is the false-positive source
   the mutation trial already named as what decides a mechanism's verdict.
2. **Retiring `.claude/hooks/global/` in `serina-learning`.** Left standing on purpose. That
   repository has assessments due 2026-09-18 and three working copies open; a commit there this week
   buys nothing, because the copies are inert the moment nothing deploys from them. It is a tidy-up,
   and tidy-ups do not go in front of deadlines.

## The trap this leaves behind until it is decided

The refresh command in circulation for this workspace reads from `serina-learning`:

    git -C ~/Launchpad/serina-learning show origin/main:.claude/hooks/global/<name>.sh \
      > ~/.claude/hooks/<name>.sh

Run for `verify-gate.sh`, it silently reverts `INC-0033` and removes nothing visible. The correct
source for that one file is now:

    git -C ~/Launchpad/agent-verification-kit show \
      main:plugins/agent-verification-kit/hooks/verify-gate.sh > ~/.claude/hooks/verify-gate.sh
