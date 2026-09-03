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

**Row 4 is not optional.** Every guard in this programme is meant to survive an agent that would
rather not be stopped. If nobody tried to walk around it, the trial did not test it.

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
| `true_positives` | | real problems caught |
| `false_positives` | | false alarms — **this field decides most verdicts** |
| runs observed | | a verdict from one run is a guess |

**The false-positive rule:** a mechanism that cries wolf is `fix` or `drop` *however correct it is in
principle*. A gate people learn to ignore is the problem this programme exists to solve — shipping a
noisy one makes things worse, not better.

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
| `keep` | Ships to `launchpad-26/buzz`, this log travelling with it as evidence |
| `fix` | Named defect + owner, then re-trial. Does not ship on a promise |
| `drop` | Removed. Reason recorded above so it is not silently re-proposed |
| `blocked` | Names what would settle it. **Never ships.** |

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
