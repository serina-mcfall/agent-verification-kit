# Design — closing `INC-0033`, the commit that the gate never sees

**Addresses** `INC-0033` (high) · **Branch** `design/inc-0033-commit-gate-layer`
**Status** designed, not built. **Recommends fixing the CAUSE before the CAPABILITY.**

---

## The defect, measured

`verify-gate.sh` matches on `.tool_input.command`. Against a repository with **no stamp at all**:

| Command shape | Result |
|---|---|
| `git commit -m x` | exit 2 — blocked |
| `git -C PATH commit -m x` | exit 2 — blocked |
| `sh -c "git commit -m x"` | exit 2 — blocked |
| **`bash ./do-commit.sh`** | **exit 0 — allowed** |

The trigger never fires, so the stamp is never checked.

## Two problems, and they are separable

This is the whole of the design, and getting it backwards would build the expensive thing first.

**1. The MOTIVE.** `verify-gate` blocks any Bash call whose text *mentions* `git commit` — including a
`--field` value describing one, or a commit message quoted into a command. There is no way to write
about a commit without being refused. So wrapping in a script became routine: first for writing
records, then for committing. **The workaround for the false positive disables the true positive.**

**2. The CAPABILITY.** Even with no motive, a script-wrapped commit *can* evade the gate.

This kit is documented as **accident prevention inside one harness, not a security boundary**.
Against accident, removing the motive is worth more than removing the capability — nobody wraps a
commit in a script by accident. Against a determined agent, neither layer holds: `--no-verify`
exists, and so does `git` from a shell the harness never sees.

**So the recommendation is to fix 1 first, cheaply, and treat 2 as a separate decision.**

## Fixing the motive

The trigger asks "does this text contain a git commit?" when it should ask "**is this call
invoking git commit?**". Those differ exactly where the false positives live: quoted text, a
`--field` value, a heredoc, a commit message.

That is a narrowing of an over-broad match, and it is the *opposite* of the six bypasses in the
README, every one of which was a trigger too narrow. **This one is too wide**, and the cost of being
too wide is not a missed block — it is a workaround that becomes the practice.

Cost: it must not narrow so far that `git -C PATH commit` or `git --no-pager commit` slip through.
Those regressions are already covered by `test-verify-gate.sh`, which is why this is a small change
with an existing safety net rather than a rewrite.

## Fixing the capability — measured, with real costs

A git `pre-commit` hook sees every commit regardless of how the tool call was shaped. Measured:

| Probe | `pre-commit` fires | commit created |
|---|---|---|
| direct `git commit` | yes | yes |
| script-wrapped commit | **yes** | yes |
| script-wrapped, hook exits 1 | yes | **no — refused** |

**It closes the gap this incident is about.** And it brings four costs:

1. **`--no-verify` skips it.** One flag. In this workspace `git-safety.sh` requires explicit human
   permission for that flag, which is a real mitigation — but it is a *different* hook's doing, not
   this kit's, and it does not travel with the plugin.
2. **`.git/hooks/` is not version controlled and not installable by a plugin.** A fresh clone has no
   hook. The kit ships as a Claude Code plugin; git hooks are outside what a plugin can place. This
   needs `core.hooksPath` or an explicit install step, and an install step someone forgets is a gate
   that is absent exactly where it was never set up.
3. **It gates ALL commits, not just an agent's.** A human committing by hand would be refused for
   want of an agent's stamp. That is a different product.
4. **It duplicates the gate.** Two gates disagreeing is a bug generator — the README's own fourth-row
   lesson is about a fix applied to one file and not its twin.

## Recommendation

1. **Narrow the trigger to an invocation rather than a mention.** Small, covered by existing
   controls, and it removes the reason the wrapper exists.
2. **Then re-measure whether wrappers still appear in practice.** If the motive is gone and the
   practice stops, the capability is an accepted, documented gap — which is what this repository
   already does honestly for command-narrowing in Stage 3.
3. **Do not ship a `pre-commit` hook yet.** It is the right answer to a question this kit has not
   decided it is asking: whether it guards a harness or a repository.

## Controls this will need

| # | Asserts | Killing mutation |
|---|---|---|
| 1 | `git commit -m "..."` still blocks without a stamp | narrow the trigger to nothing |
| 2 | `git -C PATH commit` still blocks | drop the `-C` handling while narrowing |
| 3 | `git --no-pager commit` still blocks | re-enumerate options instead of matching generally |
| 4 | a command that merely **mentions** `git commit` in a quoted value is NOT blocked | keep the substring match |
| 5 | a commit message containing the words `git commit` is NOT blocked | as above |
| 6 | `bash ./x.sh` is still allowed, and the README still says so | pretend the bypass is closed |

**Control 6 is deliberately an admission.** This design does not close `INC-0033`; it removes the
reason anyone reaches for it. The incident stays open, and the README must keep saying so.

## My concerns, unresolved

### 1. Narrowing a trigger is how five of the six documented bypasses were created

Every one of those was a trigger that failed to match a real invocation. This change moves in that
direction on purpose, which is uncomfortable and should be. The mitigation is that `test-verify-gate.sh`
already encodes each of those five as a control — they were written *because* of those bypasses. Any
narrowing that breaks one is caught. **Run them red first by mutating the new trigger, rather than
trusting that they still pass.**

### 2. "Mention" and "invocation" are not cleanly separable in shell

`git commit` inside `$(...)`, inside an alias, behind a variable. A parser would be the honest tool
and is far more than this is worth. Wherever the two cannot be told apart, **prefer blocking** — a
false positive is an annoyance, a false negative is this incident.

### 3. This leaves the kit's headline claim qualified

Stage 1 is the flagship. After this change it still does not enforce against a wrapper. The README
says so now, and it must keep saying so, however much better the fix makes the day-to-day.
