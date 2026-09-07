# Design — `announce`, the channel that reaches a human

**Closes** `INC-0013`, `INC-0016` · **Branch** `fix/announce-channel` · **Started** 2026-09-06 (UTC)
**Status** designed, not built

> Not a stage. A cross-cutting fix to every shipped hook, which is why it is riskier than its
> diff size suggests: 26 of the 66 announcement sites in this kit currently work, and the change
> must not touch any of them.

---

## Why this exists, measured rather than assumed

`NOTE-0032` measured which channel a hook can speak on. Six nonces, three channels, both
`PreToolUse` and `PostToolUse`, reported by a human who could not see the tokens in advance:

| Channel | Reaches a human |
|---|---|
| `systemMessage` (JSON on stdout) | **yes**, on both events |
| plain stdout, exit 0 | no |
| stderr, exit 0 | no |
| stderr, **exit 2** | **yes** — verbatim, and already relied upon |

Every announcement in this kit is on one of the two dead channels unless it is a refusal.

### What is actually silent

**25 stderr sites, all fail-open warnings.** Their text is the point:

- `verify-gate.sh:19` — *"empty payload — this hook cannot see the tool call and is not enforcing"*
- `guard-test-changes.sh:65` — *"jq is not installed... this hook is NOT enforcing"*
- `post-bash.sh:66` — *"flake ledger missing... flake detection is NOT enforcing"*

**The kit can stop guarding, say so correctly and loudly in code, and nobody learns of it.**
`INC-0016` records this of one site. It is true of all 25.

**15 stdout sites, all allow-path disclosures.** Including, at `verify-gate.sh:521-529`, under a
comment that reads `# SAY WHAT AUTHORISED IT, at the moment it is relied upon`:

    echo "Verified 4m ago, exit code INFERRED (the payload carried none). Commit allowed."

That is `INC-0013`'s summary sentence, sitting in the code it describes.

It also makes the README wrong. It claims `verify-gate.sh` *"reports this to you at the moment it
unlocks a commit, rather than hiding it."* It reports it to nobody. **The README must be corrected
in the same change**, or this fix leaves a false claim standing.

## Searched before prescribing

`research/claude-code-hook-output-channels.md` (2026-09-04) predicted all three results from
documentation and left one question open — whether `PreToolUse` honours `systemMessage`. That
question is what `NOTE-0032` answered. No new research is needed; this design is downstream of a
completed measurement.

## The decisions

1. **A shared library, not five copies.** `announce.sh`, sourced like `stamp-path.sh` and
   `classify-test-commands.sh` already are. The kit's own convention exists because two copies of a
   rule are two things that can disagree.

2. **Buffer, then flush exactly once.** A hook may emit **one** JSON object on stdout. Several
   sites announce and then continue, so `announce` appends to a buffer and an `EXIT` trap emits a
   single `systemMessage`. There are no existing `EXIT` traps in any hook — verified, not assumed.

3. **Refusals are not touched.** Every `exit 2` path keeps writing raw text to stderr. It works, it
   is observed working, and converting it would trade a fixed defect for a new one — the shape of
   `INC-0025`. The library must be *unusable* on a blocking path by construction, not by discipline.

4. **The announcer fails open, loudly, to the old behaviour.** If `announce.sh` is missing or
   unreadable, hooks fall back to `>&2` and keep working. A verification kit whose hooks break
   because a *message formatter* is absent would be a worse defect than the one being fixed.

5. **Escaping is delegated, never hand-rolled.** Messages carry quotes, newlines, `$` expansions
   and paths. JSON built by string concatenation is a defect generator. `jq` where available;
   `python3` as the fallback; raw stderr if neither — see concern 2.

6. **Silence stays silent.** A hook with nothing to announce emits nothing on stdout. No empty
   `{"systemMessage":""}`, which is output where there was none and changes behaviour we measured.

## The mechanism

    # in each hook, once, near the top
    ANNOUNCE_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/announce.sh"
    if [ -r "$ANNOUNCE_LIB" ]; then . "$ANNOUNCE_LIB"; else announce() { printf '%s\n' "$*" >&2; }; fi

    # at a site that used to be:  echo "..." >&2   or   echo "..."
    announce "post-bash: flake ledger missing at $FLAKE_LIB — flake detection is NOT enforcing."

`announce.sh` appends to `_ANNOUNCE_BUF`, installs the `EXIT` trap on first use, and on flush emits
one JSON object — preserving the exit status, which a careless trap silently rewrites.

## Controls — each red first, each with a distinct killing mutation

| # | Asserts | Killing mutation |
|---|---|---|
| 1 | three `announce` calls produce exactly **one** JSON object | flush per call instead of buffering |
| 2 | output is valid JSON when the message holds `"`, `\`, a newline and a `$` | swap the escaper for string concatenation |
| 3 | the `EXIT` trap **preserves** exit status: 0 stays 0, 2 stays 2 | drop the saved `$?` and let the trap's own status win |
| 4 | a blocking path still writes raw text to **stderr** and exits 2 | route a refusal through `announce` |
| 5 | `announce.sh` missing → the hook still runs, still exits correctly, message on stderr | make the fallback `exit 1` |
| 6 | a hook with nothing to announce writes **nothing** to stdout | flush unconditionally |
| 7 | neither `jq` nor `python3` → message reaches stderr, hook still exits correctly | let the escaper's failure propagate |

Control 4 is the one that matters most. It is the only control standing between this fix and
breaking every working refusal in the kit.

## My concerns, unresolved — read these before building

### 1. Two hooks on one event, both announcing — unmeasured

`PreToolUse` runs `verify-gate` and `guard-test-changes`. If both announce, do both messages
surface, or does one win? `NOTE-0032` measured one hook at a time.

This matters to the design, not just to expectations. Hooks are separate processes, so a per-hook
buffer cannot merge with another hook's. If the harness surfaces only one `systemMessage` per event,
the buffer has to become a shared file keyed by `tool_use_id` — a materially different mechanism,
and one with its own concurrency problem.

**It does not need its own spike.** The trial's Run 2 installs this kit from a local marketplace and
exercises it live, at which point both `PreToolUse` hooks announce on the same call. That run answers
it. **What must not happen is building the shared-file version speculatively, or calling this `keep`
before a call has fired both hooks at once.**

### 2. `jq` is a dependency the kit already fails open on

`guard-test-changes.sh:65` stops enforcing when `jq` is absent. If `announce` also needs `jq`, then
in exactly the situation the warning exists for, the warning cannot be delivered. The `python3`
fallback exists for this, but it means the message about a missing dependency depends on a second
one. There may be no clean answer; it should at least be a deliberate choice.

### 3. This could make the kit noisy

40 sites become visible at once. Some fire on ordinary calls — `edit-tracker`'s `REMINDER` fires per
edit. A gate people mute is worse than a gate people cannot hear, and nothing here measures the
volume. **Consider building it, running it for a day, and counting** before calling it `keep`.

### 4. `systemMessage` is documented as "some platforms"

The measurement covers one terminal on one machine. The documentation's hedge suggests it may not
render everywhere. Nothing here should *remove* the stderr write; ideally a message goes to both, so
the debug log keeps what it always had.

## Not in this change

`INC-0026`'s resolver, and the fourth field of the stamp. Both are separately open, and bundling
them would make control 4's failure impossible to isolate.
