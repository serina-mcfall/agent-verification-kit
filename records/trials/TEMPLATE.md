# Trial — <mechanism name>

**Phase** <1–5> · **Started** YYYY-MM-DD · **Closed** YYYY-MM-DD
**Where** `serina-mcfall/buzz-verification-lab` (lab fork) · **Verdict** `keep` | `fix` | `drop` | `blocked`

> Copy this file to `records/trials/<phase>-<mechanism>.md` and fill it as you go, not afterwards.
> A trial written from memory is a story; one written as it happens is evidence.
>
> Trials run in the **lab fork**. When a mechanism ships to `launchpad-26/buzz`, its completed trial
> log travels with it as the evidence for the change.

---

## What this mechanism is meant to catch

<One sentence. If it takes three, the mechanism is doing more than one thing and should be split.>

**It ships only if it catches that thing at a cost people will tolerate.** Not if it is clever.

## What was set up

<Enough that someone else could rerun it. Commands, config, file paths, versions.>

```
<the actual commands>
```

## What was thrown at it

The trial is only as good as the hostility of its inputs. List them — including the ones that
*should* pass, because a guard that fires on good input is worse than no guard.

| # | Input | Expected | Actual | ✅/❌ |
|---|---|---|---|---|
| 1 | <a case that SHOULD trip it> | fails | | |
| 2 | <a case that SHOULD NOT trip it> | passes | | |
| 3 | <an edge case> | | | |
| 4 | <the obvious bypass — try to defeat it on purpose> | | | |
| 5 | <**the thing being verified FAILS** — not the guard, the subject> | | | |

**Row 4 is not optional.** Every guard in this programme is meant to survive an agent that would
rather not be stopped. If nobody tried to walk around it, the trial did not test it.

**Row 5 is not optional either, and it was added on 2026-09-06 because its absence shipped a
fail-open to a public plugin.** Stage 1 was rated `keep` on a four-probe install trial that asked
*does the gate refuse* and *does the gate release*. Not one probe ran a **failing** test and then
attempted a commit. The code that clears the stamp on failure had never executed — `INC-0025` —
and a commit was permitted after a red suite for as long as the kit had existed.

A mechanism has three paths, not two: it refuses, it releases, and it reacts to the subject of
verification going wrong. The third is the one written from imagination and never exercised.

---

## What was observed LIVE

<**Required. A trial with this section empty cannot reach `keep`.** Added 2026-09-06.>

Control suites and fixtures establish that the code implements the design. **Only a live run
establishes that the design meets the harness.** Three defects in one day were correct against 512
controls and wrong against Claude Code: `INC-0024` (subscribed to an event that never fires for
failures), `INC-0025` (the stamp survived a red suite), `INC-0027` (recording was inert for the
command shape agents actually produce). Every one surfaced within minutes of the thing executing.

### Run 1 — the measurement spike, BEFORE the design exists

Not *"does my mechanism work"*. There is no mechanism yet. It is *"what does the harness actually
send, and when?"* A throwaway hook that dumps its raw payload, triggered once, read.

| | |
|---|---|
| What was measured | |
| How | |
| What the harness actually sends | |
| Which design assumption this **changed** | |

**This run is cheap and it is the one most likely to be skipped.** Stage 3 was designed on the
assumption that `PostToolUse` fires for a failing command. It does not. Twenty minutes here would
have replaced two days of building on a false premise — and the contradiction was already written in
this repository's own README, under a heading about inferred stamps.

### Run 2 — the live exercise, BEFORE the pull request leaves draft

Install the working tree as a local marketplace and drive the mechanism for real:

```
/plugin marketplace add <absolute path to the worktree>
/plugin install <plugin>@<local marketplace>
/reload-plugins
```

A local directory is a valid marketplace source, so **this does not require merging first.** Both
2026-09-06 defects were found by a live run that happened *after* publication; nothing about them
required it to.

Hooks reload on `/reload-plugins` — the count in `/hooks` should change. Hooks added to
`settings.json` do **not** reload mid-session, which is a different thing and was once mistaken for
a rule about all hooks (`NOTE-0023`).

| # | What was driven | Expected | Observed | ✅/❌ |
|---|---|---|---|---|
| 1 | the happy path | | | |
| 2 | the refusal path | | | |
| 3 | **the subject of verification failing** — row 5 above, for real | | | |
| 4 | the command shape an agent actually produces, not a tidy one | | | |

**Row 4 is there because of `INC-0027`.** Every control fed `npm test`; every real invocation was
`cd /repo && npm test`. The mechanism was correct for the shape its author imagined and inert for the
shape the harness makes. No fixture can find that, because a fixture *is* the shape you imagined.

### What the live run could not reach

<Say it plainly. A live run in one repository on one machine is not a fleet.>

---

## What happened

### ✅ What was great
<Kept behaviour. Be specific: which case, what it caught, how clear the failure message was.>

### ⚠️ What needs work
<Right idea, wrong implementation. Name the defect, not the feeling.>

### ❌ What broke
<Misfires, crashes, blocked the wrong thing, false alarms. Each one gets an `incident` event —
put the ID here.>

### 🗑️ What should go
<Anything that cost more than it returned. Say WHY — a dropped mechanism with no recorded reason
reads as an oversight six months later.>

---

## The numbers

| Field | Value | Notes |
|---|---|---|
| `ci_seconds` | | wall-clock added to the run |
| `true_positives` | | real problems **the mechanism itself caught** — see the rule below |
| `false_positives` | | false alarms — **this field decides most verdicts** |
| runs observed | | a verdict from one run is a guess |

**The false-positive rule:** a mechanism that cries wolf is `fix` or `drop` *however correct it is in
principle*. A gate people learn to ignore is the problem this programme exists to solve — shipping a
noisy one makes things worse, not better.

**The true-positive rule, ruled 2026-09-04 and written down here so it stops being re-litigated:**
`true_positives` counts **only what the mechanism caught by firing.** A defect found by reading the
code, by reviewing the diff, by eye while scrolling CI output, or by a human asking a good question
is a **real finding and does not belong in this field.** Record it in the prose; leave the number
alone.

The reason is narrow and it is the reason this field exists at all. `true_positives` is read as
evidence that *the mechanism works*, and it is weighed against `false_positives` to decide `keep`
versus `fix` or `drop`. A finding the mechanism did not produce is evidence that **review** works —
which is worth knowing, and is a different claim. Mixing the two inflates exactly the number a
future stage will use as its baseline, and it inflates it in the flattering direction.

Stages 1 and 2 were both scored against the looser reading, disputed for three consecutive records,
and corrected under this rule: Stage 1 from `1` to `0`, Stage 2 from `5` to `3`. **A `0` here is not
a failing grade.** Stage 1's mechanism was never given anything to catch — it was trialled, not run
in anger — and its verdict is `keep` on other evidence entirely.

---

## What this trial could NOT determine

<**Required section. Do not delete it, and "nothing" is almost never the honest answer.**>

The lab fork has no fleet, no concurrent agents, no cohort CI queue and no colleagues, so by
construction it cannot tell you:

- whether this is tolerable at fleet scale
- whether the failure message reads clearly to someone who did not build it
- whether it holds up under load or contention

Add anything else this specific trial could not reach.

> Anything listed here that the verdict depends on makes the verdict `blocked`, not `keep`.
> "We could not check" must never become "it is fine" — that is INC-0006, recorded because it
> happened three times in one day.

---

## Verdict

**`keep` | `fix` | `drop` | `blocked`** — <one paragraph of reasoning, referencing the numbers above>

| Verdict | Then what |
|---|---|
| `keep` | Ships, this log travelling with it as evidence. **Requires a live observation — see below** |
| `fix` | Named defect + owner, then re-trial. Does not ship on a promise |
| `drop` | Removed. Reason recorded above so it is not silently re-proposed |
| `blocked` | Names what would settle it. **Never ships.** |

### `keep` requires a live observation — ruled 2026-09-06

**A mechanism reaches `keep` only when *What was observed LIVE* records it doing its job in a real
session against real input, including the failure path.** Green control suites are not sufficient
and never were.

`blocked` already covers *"we could not check"*. This closes the gap next to it: **"we checked the
wrong thing."** Stage 1 held `keep` for days on evidence that was entirely real — hooks firing from
`${CLAUDE_PLUGIN_ROOT}`, a refusal, a release — and entirely beside the point, because nothing had
ever made the verified thing fail.

**The friction is the whole cost and it should be stated.** A live run needs slash commands, so it
needs a human, so it cannot be done by an agent working alone. That friction is exactly why three
stages shipped without one. If this rule is going to be aspirational, it is better deleted than left
here to be quoted.

## Record it

```bash
<skill>/record.sh --kind review \
  --summary "<mechanism>: <verdict> — <one line why>" \
  --tags ci/<area> \
  --field verdict=<keep|fix|drop|blocked> \
  --field mechanism=<name> \
  --field ci_seconds=<n> \
  --field false_positives=<n> \
  --field true_positives=<n> \
  --doc trials/<phase>-<mechanism>.md
```

Breakages get their own `incident` events; reference their IDs in *What broke* above.
