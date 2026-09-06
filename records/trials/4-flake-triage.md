# Trial — flake triage

**Phase** 3 · **Started** 2026-09-04 · **Closed** — open
**Where** `serina-mcfall/agent-verification-kit`, branch `feat/flake-triage`
**Verdict** **`keep`** — both halves, as of Addendum 3. Was `blocked`, then `fix`; the history is kept below

---

## THE HEADLINE LIMITATION: command narrowing defeats this mechanism

This is first, before the description of what the mechanism does, because it is the thing most
likely to be forgotten by anyone who reads the good news and stops.

The flake ledger keys on the **exact command string**. So:

```
npm test                      → fails.  Recorded in the ledger.
npm test                      → passes. Stamp says FLAKY. Commit refused.

npm test                      → fails.  Recorded in the ledger.
npm test -- --grep auth       → passes. Ledger has no entry for THIS string.
                                        Stamp says clean. Commit ALLOWED.
```

**An agent that would rather not be stopped can narrow the command and walk straight through.** It
does not need to know the mechanism exists; narrowing after a broad failure is an ordinary and
often sensible debugging move, which is precisely what makes it a good bypass.

### Why it was not fixed

Both alternatives are worse, and the reasoning is recorded so it is not silently re-litigated:

| Option | Why not |
|---|---|
| **Prefix matching**, as the Stage 2 guard uses for paths | `npm test` is a strict prefix of `npm test -- --grep auth`. A failure of the whole suite would then mark a *narrower, different* run flaky. That is a false positive, and **the false-positive rule in `TEMPLATE.md` says a mechanism that cries wolf is `fix` or `drop` however correct it is in principle.** |
| **Normalising the command** — strip flags, canonicalise the runner | Guessing. `--grep auth` changes which tests run; `--reporter json` does not. Telling those apart requires knowing every runner's flag semantics, and being wrong in the permissive direction reintroduces the false positive above while being wrong in the strict direction reintroduces the bypass. |

So the ledger matches exactly, and **the deliberate consequence is that this mechanism raises the
cost of laundering a red suite rather than preventing it.** Narrowing is at least a visible act in
the transcript, which is a weaker claim than "prevented" and is the honest one.

Recorded as `NOTE-0010` (exact-vs-prefix, and why the two kit mechanisms deliberately differ) and
`NOTE-0011` (this bypass). **`NOTE-0011` must survive into the README.** A mechanism whose bypass is
documented only in its trial record is a mechanism whose bypass is undocumented.

---

## What this mechanism is meant to catch

An agent that hits a failing test suite, re-runs it until it goes green, and takes the resulting
verification stamp as evidence the code works.

**It ships only if it catches that thing at a cost people will tolerate.** Not if it is clever.

### Why the stamp was vulnerable to this

Stage 1's `post-bash.sh` writes `.claude/.verified` when a test command exits 0. It had no memory:
the second run of a command was indistinguishable from the first. Measured, not assumed — commit
`9212df9` on 2026-09-04 demonstrated a fail-then-pass sequence earning a clean stamp, and that
measurement is what justified building Stage 3 at all (`NOTE-0007`).

## What was set up

Four hooks and one library, all in `plugins/agent-verification-kit/hooks/`:

| File | Role | New? |
|---|---|---|
| `flake-ledger.sh` | sourced library — `flake_record`, `flake_seen`, `flake_clear` over `.claude/.failed-runs` | **new** |
| `post-bash.sh` | records a failing test command; on a later pass, stamps `flaky` instead of `clean` | modified |
| `edit-tracker.sh` | clears the ledger as well as the stamp when a file changes | modified |
| `verify-gate.sh` | refuses a flaky stamp unless declared **and** carried in the commit | modified |
| `check-flaky-trailers.sh` | CI: validates every `Flaky:` trailer and prints it in its own check | **new** |

The stamp gained a fourth field: `<ts>|<command>|<basis>|clean\|flaky`.

The declaration file is `<repo>/.claude/.flaky`, one entry per line:

```
<exact command> :: #<issue> <reason>
```

The ` :: ` delimiter is deliberate. Stage 2's declaration format is a prefix match over paths; this
one is an exact match over a command string that may itself contain almost anything, so it needs an
unambiguous separator rather than whitespace.

Reproducing the end-to-end run:

```bash
# from the worktree
bash plugins/agent-verification-kit/hooks/check-controls.sh     # 13 suites
bash /tmp/.../s3-e2e.sh                                         # four scenarios, real hooks
```

## What was thrown at it

| # | Input | Expected | Actual | ✅/❌ |
|---|---|---|---|---|
| 1 | fail → re-run → pass → commit, nothing declared | refused | **refused**, naming the command and both times | ✅ |
| 2 | fail → **edit** → pass → commit | allowed, `clean` | **allowed**, stamp reads `clean` | ✅ |
| 3 | first-run pass → commit | allowed, no ceremony | **allowed** | ✅ |
| 4 | **the obvious bypass — narrow the command after a failure** | **not caught** | **not caught** | ❌ **by design — see the headline above** |
| 5 | flaky stamp + declaration, **no commit trailer** | refused | **refused** — "would leave no trace in the record" | ✅ |
| 6 | flaky stamp + declaration + `--trailer "Flaky: …"` | allowed | **allowed**, gate names the issue that authorised it | ✅ |
| 7 | declaration with no `#issue` | does not authorise | **does not authorise** | ✅ |
| 8 | `Flaky:` typed in the commit **body**, not via `--trailer` | refused | **refused** by both halves | ✅ |
| 9 | a legacy three-field stamp, written before this field existed | reads `clean` | **reads `clean`** — degrades, does not error | ✅ |
| 10 | CI: unresolvable base ref / not a repo | exit 3 | **exit 3**, never 0 | ✅ |

**Row 4 is the honest failure and it is not a defect in the implementation** — it is the accepted
cost of the exact-match decision above. It is listed here rather than buried because
`TEMPLATE.md` requires the bypass row, and a bypass row that reads ✅ every time means nobody tried.

### The end-to-end run, verbatim

Real hooks, real stamp file, real declaration file, a genuinely flaky test script:

```
=== A. LAUNDERING — fail, re-run, pass, then try to commit ===
  stamp: 1788643985|python3 test_flaky.py|observed|flaky
COMMIT BLOCKED — the suite that unlocked this commit FAILED first and passed on a re-run.

  command: python3 test_flaky.py
  It failed at 09:33 and passed at 09:33, with no edit between.

=== B. DECLARED but no trailer — the record would not show it ===
COMMIT BLOCKED — this flake is declared locally but would leave no trace in the record.

  command:  python3 test_flaky.py
  declared: #412 races on the marker file

=== B2. DECLARED and carrying the trailer ===
Verified 0m ago, but FLAKY — 'python3 test_flaky.py' failed before it passed.
Declared: #412 races on the marker file, and recorded in the commit. Commit allowed.
    --> exit=0

=== C. HONEST FIX — fail, EDIT, pass, then commit ===
  stamp: 1788643985|python3 test_flaky.py|observed|clean
    --> exit=0
```

---

## What happened

### ✅ What was great

**The four states are genuinely distinguished, and the messages say which one you are in.** A first
pass, an honest fix, a laundered re-run and a declared flake produce four different outcomes with
four different explanations. Scenario C is the one that matters most for adoption: an edit between
the failure and the pass clears the ledger, so **fixing a bug the normal way costs nothing at all** —
no declaration, no trailer, no message. A mechanism that taxed ordinary work would be switched off.

**The gate names the issue that authorised the commit.** Not "allowed" but *"Declared: #412 races on
the marker file, and recorded in the commit."* Someone reading that knows what was waived and where
to go next.

**The `--trailer` requirement is enforced as `--trailer`, not as the word `Flaky:`.** Git parses
trailers only from the final paragraph, so a `Flaky:` line typed into the body records **zero**
trailers while looking perfect in `git log`. Both halves refuse that: the gate requires the flag
form, and CI compares what git *parsed* against what is literally *written*. This is not
hypothetical — it cost three attempts on one commit in `serina-learning`.

**`check-controls.sh` refused to run when I got it wrong.** I wrote
`test-check-flaky-trailers.sh` before its implementation, so the directory and `controls.list`
disagreed, and the runner exited 1 having run **nothing** rather than running twelve suites and
reporting green. That is `INC-0011` — a committed suite never added to CI — catching its own author
a day later. Logged as `NOTE-0014`. **A partial green is a wrong claim; an error is a correct one.**

**Stage 2's guard caught me too.** The `Test-change:` declaration for `f604d45` initially named two
existing controls whose expectation the trailer requirement flips. Running the suite showed
**four**. Corrected to four rather than left wrong (`NOTE-0013`). All four asserted an allow using a
bare commit, which the new behaviour refuses; each gained the trailer and goes on asserting the same
allow. **None was weakened.**

### ⚠️ What needs work

**`INC-0016` — the ledger's own fail-open warns on a channel that reaches nobody. OPEN.**
If `flake-ledger.sh` is unreadable, `post-bash.sh:66` prints *"flake detection is NOT enforcing"* to
stderr and exits 0. Per `INC-0013`, a non-blocking hook's output goes to the debug log. So the
warning announcing that verification has stopped enforcing is invisible, and every re-run pass would
stamp `clean`, identical to a first pass. The code is correct and loud; the channel is deaf.
**Closing this needs `INC-0013` solved, not a change here.**

**The same deafness applies to `verify-gate`'s empty-payload path**, and it bit me — see below.

**Two of six mutants were too weak to kill anything** (`NOTE-0016`). `test-check-flaky-trailers.sh`
went 15/15 on its first run, which in this project is a reason for suspicion rather than
satisfaction. Mutation testing found the suite sound — but only after two mutants that *looked*
like they removed behaviour turned out not to. A surviving mutant is ambiguous: either the control
cannot fail, or the mutant did not change anything. **Both readings must be checked**, and the
tempting one was wrong here. Eight mutants, all killed, after sharpening.

### ❌ What broke

**`INC-0018` (high) — I reported the allow path as proven from a run that never executed it.**

This is the most instructive thing in this trial and it is mine, not the mechanism's.

Scenario B2 built its JSON payload with shell quotes nested inside python nested inside shell. It
raised a `SyntaxError`. Python printed nothing. `verify-gate` received an **empty payload**, which it
treats as *"this hook cannot see the tool call and is not enforcing"* — and exits 0. The harness
printed `--> exit=0`, and I read `exit=0` as the allow path working and said so.

**The evidence was on screen and my filter removed it.** I had piped the run through
`grep -E "^===|exit=|stamp:|COMMIT BLOCKED|Verified"`. The `SyntaxError` and the hook's own
*"not enforcing"* warning both fell outside that pattern.

Three things are worth separating:

1. **The gate was correct.** It detected the condition and announced it precisely. This was not a
   hook defect.
2. **The harness was wrong**, and the false result it produced was a *pass*. Fixed by passing the
   command through the environment instead of interpolating it, and by showing the gate's own
   stdout so an allow has to *say* why it allowed.
3. **`verify-gate` fails OPEN on an unreadable payload**, on stderr, which per `INC-0013` reaches
   nobody in a live session. In a real session this false green would have been *silent*. Same
   family as `INC-0016`.

The pattern this belongs to has six prior instances in this project's record, all of them "I wrote a
check and it did not check". This is the first where the check was the **observation harness** rather
than a control suite, and the first caught by *reading full output instead of a filtered view*.

### 🗑️ What should go

Nothing yet. The mechanism has not been run in anger long enough to know what it costs, which is
itself the reason for the verdict below.

---

## The numbers

| Field | Value | Notes |
|---|---|---|
| `ci_seconds` | **0** | the workflow job exists; **no CI run has occurred on this branch** |
| `true_positives` | **0** | see the rule below — the mechanism has never fired at anything but fixtures I wrote |
| `false_positives` | **0** | and this number is close to meaningless: author-only, on fixtures, zero days of real use |
| runs observed | **0** | zero live sessions, zero CI runs |
| controls, this stage | **77** | verify-gate 20→41, post-bash 148→168, edit-tracker 12→16, flake-ledger +17, flaky-trailers +15 |
| controls, kit-wide | **512** | 13 suites, 0 failing (435 at `main`) |
| mutants run / killed | **8 / 8** | after two were sharpened; `NOTE-0016` |
| plugin installs of this stage | **0** | `NOTE-0015` — the installed plugin is still `0.1.0` |

**`true_positives: 0`, under the rule ruled 2026-09-04.** The field counts only what the mechanism
caught **by firing**. Stage 3's mechanism has refused fixtures and refused nothing else.

The two real catches recorded above — `check-controls` refusing my unlisted suite, and the Stage 2
guard proving my declaration wrong — were caught by *other stages' mechanisms*, firing correctly, at
their author. They are excellent evidence and they belong to `NOTE-0013` and `NOTE-0014`, not to this
number. Counting them here is exactly the inflation the rule exists to prevent.

**A `0` is not a failing grade** — Stage 1 scored `0` and holds `keep`. It is a statement that this
column cannot yet carry the verdict.

---

## What this trial could NOT determine

- **Whether any of this has ever constrained a real commit.** It has not. Every stamp earned while
  building Stage 3 was written by the **installed** hook at `~/.claude/plugins/cache/…/0.1.0`, which
  contains no `STAMP_FLAKE` — the three-field stamps prove it. `NOTE-0015`. **This is `REV-0001`'s
  finding wearing new clothes**: scripts proven, delivery never run. Stage 1 was rated `blocked` for
  exactly this and the rating was right.
- **Whether the CI half works in CI.** `check-flaky-trailers.sh` has only ever been invoked from an
  interactive shell. The `fetch-depth: 0` failure mode is the likeliest to bite and the least
  exercised — a shallow clone was simulated by passing a bad ref, which is not the same thing.
  Identical to Stage 2's position before its PR proof.
- **Whether the declaration and trailer friction is tolerable.** Author-tested only, by the person
  who designed both formats, on fixtures, over one day. The `false_positives: 0` is measured against
  controls I wrote. **A guard that fires correctly and annoys five people is a failure this trial
  would report as a success.**
- **How often real suites are flaky enough for this to fire.** Zero real flakes have been observed.
  If the true rate is high, the declaration friction compounds into exactly the ignored-gate problem
  this programme exists to solve; if it is near zero, the mechanism is cost with no return. **This
  is the question that decides whether Stage 3 is worth shipping, and nothing here touches it.**
- **Whether `flake_seen`'s 30-minute TTL is the right window.** Chosen to match the stamp's
  expiry, not measured. A long CI-bound debugging session could cross it and lose the memory of a
  failure legitimately.
- **Whether the messages read clearly to someone who did not build them.** Unchanged from Stages 1
  and 2, and unchangeable in a solo lab.

> Anything listed here that the verdict depends on makes the verdict `blocked`, not `keep`.
> "We could not check" must never become "it is fine" — that is `INC-0006`.

---

## Verdict

**`blocked`** — and deliberately so, on the same ground that blocked Stage 1, because the same
observation is missing.

The mechanism is built, its logic is covered by 77 new controls across 13 green suites, its
implementation survived eight mutants, and a four-scenario end-to-end run against the real hooks
distinguishes laundering from an honest fix from a declared flake. That is a good position. It is
not evidence that the thing works, because **the layer actually constraining this machine is
`0.1.0`, which has none of it** (`NOTE-0015`).

Two further facts make `keep` unavailable rather than merely premature:

1. **`true_positives` is `0` and `false_positives` is `0` from zero real runs.** The pair of numbers
   the template says decides most verdicts contains no information at all.
2. **`INC-0018` happened in this very trial.** My own end-to-end harness reported a pass on a path
   it never executed, and the failure mode was a *false green*. A verdict awarded on the strength of
   an e2e run, one day after that e2e run silently lied, should be awarded conservatively.

Three things close it, in order, and each is independent:

1. **Open the pull request** so the `declared flakes` and `controls` jobs run. This branch's own
   commits carry no `Flaky:` trailer, so the expected result is the vacuity case — *"checked N
   commit(s) … no Flaky: trailers declared"*, exit 0. **That is the weaker proof.** The stronger one
   is a deliberately malformed trailer on a throwaway branch, failing the check with exit 1, the way
   `trial/undeclared-test-change` did for Stage 2.
2. **Install the merged plugin and `/reload-plugins`**, then earn a genuinely flaky stamp in a live
   session and confirm the gate refuses the commit with the message above — attributed to
   `${CLAUDE_PLUGIN_ROOT}`, as Stage 1's Addendum 2 and Stage 2's Addendum 4 both did.
3. **Put `NOTE-0011` in the README.** Command narrowing is the headline limitation of this stage and
   it currently exists only in the record and in `flake-ledger.sh`'s header comment.

Step 1 is independent of the plugin question and can be done now — the same split that let Stage 2
reach `keep` on its CI half while its hook half was still `blocked`.

`INC-0016` does **not** block this. It is a real open defect in the transparency of a fail-open, it
is `INC-0013`'s channel problem in a new location, and it will not be closed by anything in Stage 3.

| Verdict | Then what |
|---|---|
| `blocked` | Names what would settle it. **Never ships.** |

## Record it

Not yet run — this trial has no `review` event, because a `blocked` verdict awarded before the
pull request exists would have to be superseded within the hour. It is recorded when step 1 above
returns a result:

```bash
<skill>/record.sh --kind review \
  --summary "flake triage: blocked — 77 controls green, zero runs in anger, installed plugin still 0.1.0" \
  --tags ci/hooks,process/verification \
  --field verdict=blocked --field mechanism=flake-triage \
  --field ci_seconds=0 --field false_positives=0 --field true_positives=0 \
  --doc trials/4-flake-triage.md
```

Findings already recorded, all referencing this document:

| ID | |
|---|---|
| `NOTE-0010` | exact matching, and why it is the deliberate opposite of Stage 2's prefix match |
| `NOTE-0011` | **command narrowing — the headline limitation** |
| `INC-0016` | the ledger's fail-open warns on a deaf channel — **open** |
| `INC-0017` | a declared flake left no trace a reviewer could see — fixed in `f604d45` |
| `INC-0018` | **the allow path was reported proven from a run that never executed it** |
| `NOTE-0012` | this CI half is structurally weaker than Stage 2's |
| `NOTE-0013` | Stage 2's guard caught its author: 2 declared, 4 actual |
| `NOTE-0014` | `check-controls` refused to run rather than run a subset |
| `NOTE-0015` | Stage 3 has never gated a real commit — installed plugin is `0.1.0` |
| `NOTE-0016` | two of six mutants were too weak to kill anything |

---

## Addendum 1 — the CI half fired, 2026-09-06

Written after the verdict above rather than folded into it, so the progression is legible.

### PR #5 went green, and that proved less than it looks

[PR #5](https://github.com/serina-mcfall/agent-verification-kit/pull/5), run `33994509698`:

| Job | Result |
|---|---|
| `controls` | **pass** — 13 suites on a clean runner |
| `undeclared test changes` | **pass** — *"9 files modified or deleted, 3 of them tests or test config"*, all declared |
| `declared flakes` | **pass** — `checked 8 commit(s) over origin/main..HEAD — no Flaky: trailers declared` |

**The third row is a vacuity pass and must never be cited as proof the check bites.** It passed by
finding nothing, because the branch declares no flakes. A green vacuity pass and a green
everything-was-fine are indistinguishable in the checks list, which is the exact confusion this kit
exists to name. Recorded as `NOTE-0017` so nobody later reads that row as evidence.

Two smaller things the run settled:

- **The step genuinely executed.** Confirmed from the raw job log, not from the green tick — the
  script's own output line is present. A job can pass with a step that produced nothing.
- **I predicted 6 commits; CI reported 8.** Both are right, and the gap is worth keeping. The local
  run predated the trial-record commit, and `pull_request` checks out the **merge commit** rather
  than the branch tip, adding one more. This is the same behaviour trial 2's Addendum 2 recorded: the
  job answers *"would `main` break if this merged"*, not *"is the branch tip clean"* — the more
  useful question, and not what a naive reading of the workflow predicts.

### So it was given something to find

[PR #6](https://github.com/serina-mcfall/agent-verification-kit/pull/6), branch
`trial/malformed-flaky-trailer`, **draft, DO NOT MERGE** — the Stage 3 counterpart of
`trial/undeclared-test-change`. Two commits, two distinct failure modes:

| Commit | Fixture | Malformed how |
|---|---|---|
| `cdf5310` | `Flaky: npm test it is just flaky sometimes` via `--trailer` | names a command and a reason, **no `#issue`** |
| `286caeb` | `Flaky: pytest tests/test_auth.py #99 races on the token clock` in the **body** | perfectly formed, and **git parsed zero trailers** |

Both fixtures were verified to *be* what they claimed before being pushed, rather than assumed:
`git log -1 --format='[%(trailers:key=Flaky,valueonly)]' 286caeb` returns `[]` while the same
message contains the line at line 3.

**Run `33994783542`:**

| Job | Result |
|---|---|
| `controls` | pass |
| `undeclared test changes` | pass — the fixtures are newly added non-test files, so nothing is confounded |
| `declared flakes` | **FAIL** |

```
FLAKY TRAILER MALFORMED — checked 10 commit(s) over origin/main..HEAD
  286caeb1  trial: a Flaky line git never parsed as a trailer (DO NOT MERGE)
      A Flaky: line is written in this message but git did NOT parse it as a
  cdf53105  trial: a Flaky trailer with no issue number (DO NOT MERGE)
      No issue number. A flake with no issue is a flake nobody has agreed to fix,
##[error]Process completed with exit code 1.
```

**Exit 1, not exit 3.** That distinction is the point: exit 3 is could-not-determine, and a job that
fails because it could not check is not a job that fails because it found something. Conflating them
is `INC-0006`. Both commits are named, each with its own reason, and the other two jobs passed — so
the failure is attributable to the flaky check and nothing else.

**The `286caeb` row is the one that mattered.** It is the only fail-open this CI half uniquely
closes, and until this run it was covered solely by a control suite written against the
implementation — which is precisely the failure mode that let the original `notebook_path` defect
survive 32 controls in Stage 2.

### Revised numbers

| Field | Was | Now | Why |
|---|---|---|---|
| CI runs observed | 0 | **2** | PR #5 all-green, PR #6 with `declared flakes` failing |
| CI refusals observed | 0 | **1** | run `33994783542`, exit 1, two commits named |
| `ci_seconds` | 0 | **4** | the `declared flakes` job |
| `false_positives` | 0 | **0** | `controls` and `undeclared test changes` both passed on the fixture branch — the check did not fire on anything it should not have |
| `true_positives` | 0 | **0** | unchanged, and deliberately. Both refusals were of fixtures **written to be refused.** Under the ruled definition that is a mechanism working, not a defect caught |
| plugin installs of this stage | 0 | **0** | unchanged |
| controls | 512 | 512 | none added here |

### Verdict, split

| Half | Verdict | Change |
|---|---|---|
| `check-flaky-trailers.sh` (CI) | **`keep`** | **`blocked` → `keep` 2026-09-06.** Failed a real pull request with exit 1, naming both malformed commits, while the sibling jobs passed |
| the hooks (`flake-ledger`, `post-bash`, `edit-tracker`, `verify-gate`) | **`blocked`** | unchanged. `NOTE-0015` — the installed plugin is still `0.1.0` and **none of this has ever constrained a real commit** |

This is the same split Stage 2 reached, for the same reason, and it is recorded the same way: the CI
half is independent of the plugin-delivery question and can be settled without it.

**Two things the `keep` does not mean.** It does not mean parity with Stage 2's CI half — this one
**cannot detect a missing trailer** and never will, because the stamp is gone by CI time
(`NOTE-0012`). And it does not touch the headline limitation at the top of this document: **command
narrowing is unaffected by anything in this addendum.**

`REV-0010` (CI half, `keep`) and `REV-0011` (hooks, `blocked`).

### What still closes the stage

Two of the three items in the verdict above remain, unchanged:

1. ~~Open the pull request so the jobs run.~~ **Done, both the vacuity case and the refusal.**
2. **Install the merged plugin and `/reload-plugins`**, earn a genuinely flaky stamp in a live
   session, confirm the refusal is attributed to `${CLAUDE_PLUGIN_ROOT}`.
3. **Put the command-narrowing limitation in the README.**

### Disposal — ruled 2026-09-06

**PR #6 stays open as a draft.** Serina's call, in her words: *"i will keep it for now if it start to
become a issue I'll close it"*. Recorded as `CHG-0006`, because it is a decision about how this
programme works rather than a detail of this stage.

It is the only live evidence of this check refusing anything, and closing it would leave this record
citing a run nobody can navigate to.

**The cost is real and is recorded rather than glossed.** A red tick sits in the repository's pull
request list looking like a failure to anyone who does not read the title. There are two now — this
one and Stage 2's `trial/undeclared-test-change` — and one per stage scales badly. **The trigger to
revisit is Serina judging the noise to outweigh the evidence, and it is her call, not an agent's.**

The fallback, if it comes to that, is proving refusals in control suites alone. That is **weaker**,
and the reason should be stated before anyone reaches for it as a tidy-up: it drops the claim that
the check *failed a real pull request*, which is the only claim a suite written against the
implementation cannot make.

**Neither trial PR may ever be merged** — each carries fixture files and deliberately malformed
commits.

---

## Addendum 2 — the hook half cannot fire, 2026-09-06

The plugin was updated to `0.4.0` and the hooks were finally run in a live session. They do not work.

### What was measured

One repository, two runs, each the sole command in its call, against the installed plugin:

| Run | Exit | Effect |
|---|---|---|
| `python3 test_always_fails.py` | 1 | **nothing at all** — no `.claude/` directory created |
| `python3 test_always_passes.py` | 0 | `.claude/` created, stamp `…|inferred|clean` |

And a full flaky sequence — fail, then pass, same command — produced:

```
stamp:  1788658586|python3 test_flaky.py|inferred|clean
ledger: (none)
```

**`clean`, not `flaky`.** The laundered pass earned exactly the stamp Stage 3 exists to prevent.

**The script is not at fault.** Fed a synthetic payload carrying `exitCode: 1`, the installed
`post-bash.sh` writes the ledger correctly:

```
1788658673|python3 test_always_fails.py
```

It is never called. **Claude Code does not fire `PostToolUse` for a Bash call that exits non-zero.**

### The contradiction was already written down

This kit's README, under *the harness currently sends no exit code*:

> An inferred stamp rests on a premise — that `PostToolUse` does not fire for a non-zero exit

**Stage 1 is safe because that premise is true. Stage 3 requires it to be false.** Two mechanisms in
one kit with mutually exclusive premises, and the conflict was documented in this repository before
Stage 3 was designed. Nobody checked. I did not check.

### Why 512 controls did not catch it

The loose version of this — "every control feeds a payload containing an exit code" — is **wrong**,
and a reviewer checked it. `test-post-bash.sh` explicitly exercises the real payload shape, asserting
that a payload with **no** exit code still stamps, on the stated grounds that *"the hook ran, so the
command passed"*. Interrupted payloads are covered too.

The actual gap is narrower and worse. **No control establishes which events the harness emits and
routes.** Every control supplies a payload; not one asks whether that payload ever arrives. A
mechanism can be completely covered against the input it was written for and never receive it.

That also means the premise was not merely unexamined — it was *written into a control's assertion
text* and relied upon, while a second mechanism was built one directory away requiring its opposite.

The end-to-end run in the main body of this trial shares the flaw: it drives the hooks with
hand-built payloads. It proved the scripts implement the design. It could not, and did not, prove the
design meets the harness.

### What this costs the earlier verdicts

- The `blocked` verdict in the main body was **right for the wrong reason.** It said the hooks had
  never been observed. They have now, and they do not work.
- **`REV-0011` is superseded.** `blocked` → `fix`: there is a named defect, not merely an unrun test.
- `REV-0010`, the CI half's `keep`, **stands.** `check-flaky-trailers.sh` validates trailers that
  exist and is unaffected. What the hook half's failure removes is the *automatic* pressure to add
  one — a human or an agent can still write a `Flaky:` trailer by hand, and PR #6 contains real
  ones. The validator is useful independently of whether anything compels its input.
- **Command narrowing, this trial's headline limitation, is currently moot.** It describes a bypass
  around a gate that does not close.

### The fix, identified after this addendum was first written

**Superseded correction.** This addendum originally proposed recording *command started* in
`PreToolUse` and *completed* in `PostToolUse`, inferring failure from a missing completion. A
cross-vendor review (Codex, 2026-09-06) refuted that design: permission denial, long-running and
concurrent commands, background execution, overlapping identical commands, multiple sessions sharing
a repository, and edits between the two events all look identical to a failure. Missing completion
means **unknown**, not **failed**. The proposal is not sound and is withdrawn.

The same review found what the diagnosis had missed. **Claude Code fires `PostToolUseFailure` after a
tool call fails.** The kit never registered for it. Confirmed against the documentation and against
the harness's own `/hooks` screen, which states the payload:

> Input to command is JSON with `tool_name`, `tool_input`, `tool_use_id`, `error`, `error_type`,
> `is_interrupt`, and `is_timeout`.

Two properties matter. There is **no exit code** — the event firing *is* the failure signal, so
nothing needs inferring. And `is_interrupt` and `is_timeout` are **separate fields**, which answers
the strongest objection to the withdrawn design: an interrupted or timed-out call is distinguishable
from a real test failure rather than guessed at.

So this is an **event-subscription mistake, not a limit of the harness**, and it is cheap to fix.

**Still not observed.** Hooks are fixed at session start, so a probe registered mid-session cannot
fire. The field list above is the harness describing its own contract, which is stronger than the
assumption that produced `INC-0024` but is **not a captured payload**. A probe is armed to capture
one, and no control should claim conformance to the real shape until it has.

### Revised numbers

| Field | Was | Now | Why |
|---|---|---|---|
| live sessions observed | 0 | **1** | and the mechanism did not fire |
| flaky stamps produced in anger | 0 | **0** | a real fail-then-pass produced `clean` |
| `true_positives` | 0 | **0** | unchanged |
| `false_positives` | 0 | **0** | it cannot fire, so it cannot misfire either |
| plugin installs of this stage | 0 | **1** | `0.4.0`, confirmed on disk |

### Verdict

| Half | Verdict | Change |
|---|---|---|
| `check-flaky-trailers.sh` (CI) | **`keep`** | unchanged, `REV-0010` |
| the hooks | **`fix`** | **`blocked` → `fix` 2026-09-06.** Named defect: `INC-0024` |

The hook half is shipped, public and inert, and the README now says so at the top rather than the
bottom. The CI half's `keep` is unaffected and is not being revoked by association.

---

## Addendum 3 — the whole chain, observed, 2026-09-07

**`INC-0024` is closed. Every link in Stage 3 has now been watched working in a live session**, from
the installed plugin at `0.5.2`, against a genuinely flaky suite — one that fails on first run and
passes on the second.

### The laundering path, refused

| Step | Observed |
|---|---|
| suite runs, **fails** | ledger written: `1788724796\|python3 test_flaky.py` |
| same suite runs, **passes** | stamp `…\|inferred\|**flaky**` — not `clean` |
| commit attempted | **REFUSED** |

The refusal, verbatim:

> COMMIT BLOCKED — the suite that unlocked this commit FAILED first and passed on a re-run.
> command: python3 test_flaky.py
> **It failed at 07:59 and passed at 08:00, with no edit between.**

That is the defect this stage was built for, caught in the act, naming the command and both times.

### The printed remedy was executed, not read

This kit's ancestor shipped a refusal whose documented escape hatch was wrong about the project it
described, and the wrong route became the trained one. So the remedy was not hand-written: the two
commands the gate printed were run **verbatim**, then the commit retried.

It was refused again — correctly — because a declaration alone is gitignored and expires:

> COMMIT BLOCKED — this flake is declared locally but would leave no trace in the record.
> `--trailer "Flaky: python3 test_flaky.py #412 races on the marker file"`

Running **that** printed line allowed the commit. Git parsed the trailer, and CI reads it back:

```
check-flaky-trailers: checked 1 commit(s) — 1 declared flake(s):
  872bafb9  python3 test_flaky.py #412 races on the marker file
```

**Both printed remedies work as printed.** Neither was reconstructed from what it was believed to say.

### An honest fix still costs nothing

The path that decides whether anyone keeps this installed:

| Step | Observed |
|---|---|
| suite fails | ledger written |
| **a file is edited** | stamp and ledger cleared |
| suite passes | stamp `…\|inferred\|**clean**` |
| commit | **allowed, silently** |

No declaration, no trailer, no message. A mechanism that taxed ordinary debugging would be switched
off, and this one does not.

### Revised numbers

| Field | Was | Now |
|---|---|---|
| live sessions observed | 1 | **2** |
| flaky stamps produced in anger | 0 | **1** |
| laundered commits refused | 0 | **1** |
| printed remedies executed verbatim | 0 | **2**, both worked |
| `true_positives` | 0 | **0** — the flake was a fixture written to be flaky, not a real defect caught |
| `false_positives` | 0 | **0** — the honest-fix path produced no ceremony |

### Verdict

| Half | Verdict | Change |
|---|---|---|
| `check-flaky-trailers.sh` (CI) | **`keep`** | unchanged, `REV-0010` |
| the hooks | **`keep`** | **`fix` → `keep` 2026-09-07.** `INC-0024` closed by observation |

**This is the first verdict awarded under the rule ruled in `CHG-0008`**, and the rule is what made
it wait: the same evidence a day earlier would have been controls and a scripted end-to-end, and
that combination has now been wrong three times in this project.

**Command narrowing remains the headline limitation** and is untouched by any of this. The mechanism
raises the cost of laundering a red suite. It does not prevent it.
