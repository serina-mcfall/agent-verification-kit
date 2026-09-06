# How the defects actually surfaced

## In brief

**What this is.** A classification of every defect recorded in this repository's event log by *how
it was first noticed* — running the software, reading it, reviewing it, a mechanism firing, or
someone asking a question.

**Why it exists.** This project's whole claim is that automated mechanisms catch what instructions
and good intentions do not. That claim is testable against its own record, and nobody had tested it.
The log said *what* went wrong; it did not say *what found it*. Without that, "we found 24 defects"
is a number with no argument attached.

**What it found.** Not one defect was discovered by one of the kit's own mechanisms. Two thirds of
the severe ones were found by **running the software** — usually within minutes of it executing, and
always while a large control suite was green.

**How to read the count.** **24 defects is not a measure of how broken this code is.** It is a
measure of how hard it was looked at, and of a project that logs the mistakes made *while building
it* as carefully as the ones found *in it*. Several entries are the agent's own errors, not the
code's: a merged conflict marker, a self-inflicted regression, a diagnosis that turned out wrong.
A project recording less would look better and be worse. Read the *proportions*, not the total.

**What it cannot tell you.** Anything about other people, other machines, or whether any of this
stops reward hacking — which is what the kit is for, and which no event here tests. The limits are
set out in full at the end, and they are not boilerplate.

---

**Reconstructed 2026-09-07. This is not contemporaneous evidence.**

`events.jsonl` is append-only, so a field cannot be added to a line after the fact — and a
classification made today is a judgement, not an observation. This file is therefore kept separate
and labelled, rather than retrofitted into the record as if it had been written at the time.

**Method.** Every `kind: incident` event was classified by how it was *first noticed*, using the
event's own `found_by` / `found_when` fields where they exist, and the surrounding commit messages
and trial records where they do not. Where the honest answer was ambiguous the more flattering
option was **not** chosen. Closure events (`INC-0021`, `-0022`, `-0023`, `-0029`) are excluded — they
record a fix, not a discovery. `INC-0012` is excluded as a re-record of `INC-0010`.

**24 discoveries classified.**

---

## The headline

**Not one defect in this record was discovered by one of the kit's own mechanisms.**

The mechanisms did fire, repeatedly, and they were right every time — but what they caught were
*process slips*, not defects: an undeclared test change, a control suite missing from the runner, a
version that had not been bumped. Those are recorded as notes (`NOTE-0013`, `NOTE-0014`,
`NOTE-0019`), and `NOTE-0019` is the only true positive in the programme under the ruled definition.

Every **defect** was found by a person or a process looking at the thing: reading it, reviewing it,
or running it.

That is not an argument against the mechanisms. They are designed to stop an agent taking the
cheapest route to green, and there is no evidence here that they failed at that. It *is* an argument
against the assumption that a large green suite is evidence the thing works.

## By how it surfaced

| How | Count | Which |
|---|---|---|
| **Running it** | **8** | `INC-0003` `INC-0014` `INC-0018` `INC-0019` `INC-0020` `INC-0024` `INC-0025` `INC-0027` |
| **Reading** — code, output or CI logs, no mechanism involved | **8** | `INC-0001` `INC-0002` `INC-0004` `INC-0011` `INC-0015` `INC-0016` `INC-0017` `INC-0028` |
| **Adversarial review** — including cross-vendor | **6** | `INC-0005` `INC-0007` `INC-0008` `INC-0009` `INC-0010` `INC-0026` |
| **Mutation testing** | **1** | `INC-0006` |
| **A human asking a question** | **1** | `INC-0013` — *"I didn't see any of that text"* |
| **A mechanism firing** | **0** | — |

## Severity against how it surfaced

Running it and adversarial review found the serious ones.

| How | high | medium | low |
|---|---|---|---|
| Running it | **6** | 2 | 0 |
| Reading | 0 | 6 | 2 |
| Adversarial review | 2 | 3 | 1 |
| Mutation | 1 | 0 | 0 |
| Human question | 0 | 1 | 0 |
| **total** | **9** | **12** | **3** |

*(These figures are computed from the record, not counted by hand. The first draft of this table was
hand-counted and wrong in five of fifteen cells — which is its own small argument for deriving
numbers rather than typing them, and the same defect this repository has already recorded twice as
a stale count printed with authority.)*

**Two thirds of the high-severity defects came from running it.** Eight of the nine came from
running it or reviewing it; the ninth came from mutation testing. **Reading found eight real
defects and not one severe one** — it is a good net for small things and no substitute for
execution.

## The three that matter most

All found on 2026-09-06, all within minutes of the thing executing, all green against 512 controls:

| | What | Why controls could not find it |
|---|---|---|
| `INC-0024` | Stage 3 subscribed to an event that never fires for failures | Every control supplied a payload; none asked whether that payload ever arrives |
| `INC-0025` | The stamp survived a red suite — commits permitted after failure | Every probe tested *refuse* and *release*; none made the verified thing fail |
| `INC-0027` | Recording was inert for `cd /repo && npm test` | Every control fed `npm test`; a fixture is the command shape you already imagined |

`INC-0025` is the one to lead a report with. It was in the flagship mechanism, it was public, and
the trial that rated it `keep` was thorough, honest and asked the wrong question.

## What this evidence supports

- **A live run is worth more per minute than any other check here.** One four-minute run on
  2026-09-06 confirmed one high-severity fix and discovered another defect (`NOTE-0024`). That is
  the direct justification for the rule ruled in `CHG-0008`.
- **Adversarial review is the second-best source and is not redundant with it.** Cross-vendor review
  found three High findings a live run would not have reached, because they were reasoning defects
  in code paths that had not been exercised.
- **The two disagree usefully.** On 2026-09-06 a reviewer's suggested fix was refuted by the local
  controls, which encoded a decision the reviewer could not see (`NOTE-0021`). Neither source is
  sufficient alone.

## What this evidence does NOT support

- **Any claim about how the mechanisms perform in other people's hands.** Every event here comes
  from one author on one machine over five days. A defect count of 24 says more about how hard this
  repository was looked at than about how defective it was.
- **A comparison between the categories as *detectors*.** They were not applied equally. Adversarial
  review ran on some branches and not others; a live run happened three times in five days. Counts
  reflect opportunity as much as effectiveness.
- **Anything about whether the mechanisms stop reward hacking**, which is what they exist for.
  Nothing in this record tests that. The one true positive was a version bump.
