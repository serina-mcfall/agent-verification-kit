#!/bin/bash
# PostToolUse hook on Bash: creates verification stamp on test/build pass, tracks elapsed time

INPUT=$(cat)
# Claude Code delivers the hook payload on a SOCKET. `cat /dev/stdin` opens fd 0
# BY PATH, and a socket cannot be opened by path — it fails with ENXIO ("No such
# device or address"), writes to stderr, and $(...) captures only stdout. The
# result was an empty INPUT, which this script's own logic read as "not a git
# command" and allowed. Verified 2026-08-03: /proc/self/fd/0 -> socket:[...].
#
# Plain `cat` reads the already-open descriptor and works on a socket.
#
# The warning below exists because the original failure was SILENT for months.
# An empty payload is never normal; say so on stderr, which is visible without
# blocking the tool.
if [ -z "$INPUT" ]; then
  echo "post-bash: empty payload — this hook cannot see the tool call and is not enforcing." >&2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# WHERE THE STAMP GOES — the repository the tests ran in, not the session root.
# verify-gate.sh reads the same path from the same resolver; if these two ever
# disagree, the writer stamps one file and the reader checks another and no commit
# is possible. That is why the resolution is sourced rather than restated here.
#
# `readlink -f` because BASH_SOURCE[0] is the SYMLINK this hook is invoked by
# (~/.claude/hooks/), not the file it points at.
#
# FAILS SOFT, unlike verify-gate. This hook runs AFTER the tool and cannot block
# anything; the worst it can do is stamp the wrong place. If the resolver is
# missing it keeps the old container-wide path and says so — which leaves the gate
# unable to find a stamp, so commits are refused. Annoying, but refused is the
# safe direction, and verify-gate names the same missing file in its own message.
STAMP_LIB="${STAMP_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stamp-path.sh}"
if [ -r "$STAMP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$STAMP_LIB"
    # A test command reaches another repository by `cd`, not by `git -C`, so no
    # verb is passed — see stamp-path.sh on why the -C form requires one.
    VERIFIED=$(stamp_path_for "$(stamp_target_dir_from_command "$COMMAND")")
else
    echo "post-bash: stamp resolver missing at $STAMP_LIB — stamping the old shared path; the commit gate will not find it." >&2
    VERIFIED="$PROJECT_DIR/.claude/.verified"
fi
mkdir -p "$PROJECT_DIR/.claude"

# --- Flake ledger: the memory that makes a RE-RUN distinguishable -------------
#
# Stage 3. A suite that failed and was re-run until it passed, with no code
# change between, used to write an ordinary stamp and unlock a commit — measured
# 2026-09-04, commit 9212df9. Stage 1 sees only the final pass and Stage 2 never
# fires, because no test file was touched.
#
# SOFT, like the resolver above and for the same reason: this hook runs AFTER the
# tool and cannot block anything. Failing closed here would strand commits
# without preventing a single flake, so a missing library announces itself and
# the stamp is written as before — visibly unenforced rather than silently so.
FLAKE_LIB="${FLAKE_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/flake-ledger.sh}"
FLAKE_OK=no
if [ -r "$FLAKE_LIB" ]; then
    # shellcheck source=/dev/null
    . "$FLAKE_LIB" && FLAKE_OK=yes
fi
[ "$FLAKE_OK" = yes ] || echo "post-bash: flake ledger missing at $FLAKE_LIB — a re-run after a failure cannot be told from a first pass, so flake detection is NOT enforcing." >&2

# The repository whose ledger is at stake is the one whose stamp is at stake, so
# it is derived from VERIFIED rather than resolved a second time. Two resolutions
# of the same question are two things that can disagree.
FLAKE_REPO="${VERIFIED%/.claude/.verified}"

# --- Verification stamp: detect test/build commands ---
#
# THE PATTERN LIVES IN classify-test-commands.sh, not here. It moved 2026-09-06,
# when post-bash-failure.sh arrived needing the identical question answered: a
# FAILING test must clear the stamp (INC-0025) and be recorded in the flake ledger
# (INC-0024), while a failing `grep` must do neither. Two copies of that regex
# would drift the first time a runner was added to one of them, silently, and one
# hook would then stamp a suite the other did not recognise. That is the fourth row
# of this kit's own bypass table.
#
# The reasoning behind every clause — the basename signal, why position decides,
# why the extension must end the token — travelled with it. Read it there.
COMMANDS_LIB="${COMMANDS_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/classify-test-commands.sh}"
if [ -r "$COMMANDS_LIB" ]; then
    # shellcheck source=/dev/null
    . "$COMMANDS_LIB"
else
    # FAIL LOUD AND STAMP NOTHING. Without the pattern this hook cannot tell a test
    # run from any other command, and the safe direction is to write no stamp at
    # all rather than to guess in either direction.
    echo "post-bash: command classifier missing at $COMMANDS_LIB — no stamp can be written, because nothing here can tell a test run from any other command." >&2
    exit 0
fi

if echo "$COMMAND" | grep -qEi "$TEST_PATTERN"; then
    # WHAT THE PAYLOAD ACTUALLY CARRIES — re-measured 2026-08-12, and it is not
    # what the note below this one recorded on 2026-08-06.
    #
    # A captured live payload's `tool_response` holds exactly `interrupted`,
    # `isImage`, `noOutputExpected`, `stderr`, `stdout`. A search of EVERY path in
    # the payload for exit|code|status returns nothing. So all four paths here
    # resolved to "unknown", every matched run took the clear branch below, and
    # THE STAMP WAS NEVER WRITTEN ON A LIVE RUN, in any repository. The commit
    # gate was satisfiable only by its own escape hatch.
    #
    # THE EARLIER MEASUREMENT IS NOT SIMPLY WRONG. "A bare failing suite is
    # correctly refused" is equally explained by this hook never running, which is
    # what actually happens — from outside, no-stamp-because-refused and
    # no-stamp-because-never-invoked look identical. It was under-determined, and
    # test-post-bash.sh could not catch the difference because its helper INJECTS
    # an exitCode into every synthetic payload. The controls describe a payload
    # shape the harness does not send. See the real-shape control added alongside
    # this change.
    #
    # THE SIGNAL THAT REPLACES THE EXIT CODE. PostToolUse does not fire when a
    # Bash command exits non-zero — verified by clearing a probe file, running a
    # failing command as the only command, and finding the probe still holding the
    # previous successful call. So reaching this hook at all IS the evidence that
    # the command succeeded, and an ABSENT exit code can be read as 0 rather than
    # as "unknown".
    #
    # A REAL CODE STILL WINS. If a harness ever sends one it is authoritative, and
    # a non-zero value still clears exactly as before. Only genuine absence falls
    # back. An interrupted call never does — it is routed to the clear branch.
    #
    # RESIDUAL RISK, stated rather than hidden. Because a failing run does not
    # reach this hook, it can no longer CLEAR a stamp: a pass followed by a
    # failure leaves the earlier stamp standing. edit-tracker.sh clears on any file
    # edit, and verify-gate treats a stamp over 30 minutes old as stale, so the
    # window is bounded — but it is a window, and it did not exist while the code
    # below believed it was reading a real exit status.
    EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exitCode // .tool_response.exit_code // .tool_result.exitCode // .tool_result.exit_code // empty' 2>/dev/null)
    STAMP_BASIS=observed
    if [ -z "$EXIT_CODE" ]; then
        STAMP_BASIS=inferred
        if [ "$(echo "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ]; then
            EXIT_CODE=interrupted
        else
            EXIT_CODE=0
        fi
    fi

    # THE EXIT CODE BELONGS TO THE WHOLE TOOL CALL, NOT TO THE TEST INSIDE IT.
    #
    # Measured 2026-08-06, and it is the defect that matters here. A review claimed
    # the payload carries no exit code at all; it does — a bare failing suite is
    # correctly refused. What it does NOT carry is an exit code per command, so a
    # test that is one part of a longer line is judged by whatever ran last:
    #
    #   python3 -m unittest discover -s tests          -> no stamp   (correct)
    #   ... ; python3 -m unittest ... | tail -3 ; echo -> STAMPED    (suite was RED)
    #
    # Piping test output through `tail` or following it with `echo` is completely
    # ordinary — the second line above is a real command from the session that found
    # this, written without thinking. So the stamp is now only written when the
    # matched test command is demonstrably the one the exit code describes: it must
    # appear in the FINAL segment of the line, and that segment must not pipe its
    # result into something else whose status would be reported instead.
    #
    # Refusing to stamp is the safe direction. The cost is re-running the suite on
    # its own; the cost the other way is a red suite unlocking the commit gate.
    # TWO FURTHER DEFECTS, both found by a cross-vendor review of the version
    # directly above, which had already been hand-tested.
    #
    # ONE: A MENTION IS NOT A RUN. The pattern was searched with no notion of
    # command POSITION, so merely naming a test runner unlocked the gate for
    # thirty minutes:
    #
    #   echo pytest                     -> STAMPED
    #   grep -r pytest .                -> STAMPED
    #   cat notes.md # npm test         -> STAMPED
    #
    # Searching a codebase for `pytest` is an ordinary read-only act. This is the
    # worst of the set because nothing about it looks like a commit-gate operation.
    # The test command must now START the final segment, not merely appear in it.
    #
    # TWO: THE SEGMENT SPLIT MISSED `&` AND NEWLINE. It handled `;`, `&&`, `||`
    # and `|`, so those were closed and these were not:
    #
    #   pytest &                        -> STAMPED   (backgrounded; exit is the shell's)
    #   python3 -m unittest ... ⏎ echo  -> STAMPED   (exit is echo's)
    #
    # A multi-line Bash call is routine, not deliberate. Both are the same class as
    # the pipe case already handled — the exit code describes something other than
    # the test — so they belong in the same split.
    #
    # Refusing to stamp is the safe direction. The cost is re-running the suite on
    # its own; the cost the other way is a red suite unlocking the commit gate.
    #
    # DO NOT PARSE THE SHELL. REFUSE ANYTHING THAT WOULD NEED PARSING.
    #
    # Five rounds of review found five fail-opens in this one place, in order:
    # quote parity, a newline round trip, backslash escapes, ANSI-C $'...'
    # quoting, and a separator inside $( ). Each fix was correct and each was
    # followed by another hole, because deciding "which command owns the exit
    # code" from a string means writing a shell parser, and a hand-written one is
    # never finished — heredocs and a quote-blind pipe check were queued behind
    # the fifth.
    #
    # So the question is abandoned rather than answered again. A command is
    # attributable only if it contains NO character that could change what the
    # exit code describes. Quoting stops mattering: a `;` inside a quoted string
    # is refused exactly like a bare one, so nothing can hide one. That is the
    # whole point — the refusal is on RAW PRESENCE, which needs no model of the
    # shell at all.
    #
    # WHAT THIS COSTS, stated plainly. `npm ci && npm test` no longer stamps, and
    # neither does a suite on the second line of a two-line call. Both need two
    # tool calls now. Every shape this refuses fails CLOSED — one re-run, never an
    # unearned unlock — which is the trade the previous five rounds did not have.
    #
    # `cd <path> &&` is the one exemption, because it is how a suite is reached in
    # another repository and it cannot affect attribution: if the `cd` fails, `&&`
    # short-circuits, the suite never runs, the call exits non-zero, and this hook
    # is not invoked at all.
    #
    # Redirects are NOT metacharacters here. `>` and `<` leave the exit status of
    # the command untouched, so `make test > out.log` still stamps. `2>&1` does
    # not, because it contains `&` — fail-closed, and long documented.
    CMD_CORE=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^&]*&&[[:space:]]*//')

    ATTRIBUTABLE=yes
    case $CMD_CORE in
        *';'*|*'&'*|*'|'*|*'`'*|*'$('*) ATTRIBUTABLE=no ;;
    esac
    # `$'\n'`, and NOT `"$(printf '\n')"`: command substitution strips trailing
    # newlines, so the latter is an EMPTY pattern, which matches everything and
    # refuses every command. Written that way first and caught immediately by the
    # suite — the same trailing-newline trap the deleted splitter hit from the
    # other side, which is a fair warning about how easily this recurs.
    case $CMD_CORE in
        *$'\n'*) ATTRIBUTABLE=no ;;
    esac

    # The stamp's provenance field records what was actually judged.
    LAST_SEGMENT=$CMD_CORE

    # Anchored at the start of the segment, after optional VAR=value assignments,
    # a wrapper word, and a directory prefix — `env FOO=1 /usr/bin/pytest` is a run,
    # `echo pytest` is not.
    # AN INTERPRETER IS A WRAPPER WORD, added 2026-08-13 alongside SUITE_SCRIPT.
    # `bash check-plan.sh` and `python3 test_thing.py` are runs in exactly the sense
    # `env FOO=1 /usr/bin/pytest` already was, and the list held only the wrappers
    # that take no program name of their own. `echo` is deliberately NOT here: that
    # is the line between running a suite and naming one, and the mention controls
    # rest on it.
    # NO FLAGS BETWEEN THE WRAPPER AND THE PROGRAM. NONE.
    #
    # There was an allow-list here, and it was wrong four rounds running. Each round
    # closed the instances a review named and left the class:
    #
    #   -r / --require   the flag's argument was read as the program
    #   -e / -O          same, for `node -e`, `ruby -e`, `perl -e`, `bash -O`
    #   -u               same, for `env -u NAME cmd` and `sudo -u USER cmd`
    #   -X -U -Q -b      never audited at all: both greps below are `-i`, so the
    #                    six spellings on the list were TWELVE at match time
    #
    # The last one is the tell. The list being audited was not the list being
    # matched, so no amount of care about the written list could have been enough.
    #
    # The root cause is that "does this flag take a value" is PER-WRAPPER knowledge:
    # `-u` is unbuffered for python3 and a username for sudo. One list cannot serve
    # `env` and `sudo` and the interpreters at once, and a wrapper-aware table is
    # exactly the open-ended model that the metacharacter refusal was adopted to
    # escape — removed from the tail of the decision, and left in the head.
    #
    # So the head is closed the same way the tail was: refuse rather than model. A
    # flag between the wrapper and the program means no stamp, with no list to audit,
    # no case-sensitivity trap, and nothing per-wrapper to know.
    #
    # THE COST, and it is the same trade already taken for metacharacters:
    #   bash -x test-hooks.sh      python3 -u test_x.py      node --test test-foo.js
    # no longer stamp. Two calls, or drop the flag. Every one of them fails CLOSED.
    RUN_LEAD='^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|time|nohup|sudo|command|exec|bash|sh|zsh|python3?|node|bun|deno|ruby|perl)[[:space:]]+)*["'"'"']?([^[:space:]]*/)?'

    # ASKING A RUNNER ABOUT ITSELF IS NOT RUNNING IT, AND IT EXITS 0.
    #
    # A THIRD DEFECT of the same family as the two above: the pattern established
    # that the runner was NAMED and that the exit code BELONGED to it, and never
    # that a suite was actually executed. `--help` satisfies both — it is the
    # runner, it is the final segment, it is unpiped, and it succeeds.
    #
    # Measured 2026-08-06 against this file. EIGHT of eight stamped a green gate:
    #
    #   python3 -m unittest --help      pytest --help        npm test --help
    #   python3 -m unittest -h          pytest --version     cargo test --help
    #   pytest --collect-only           go test -h
    #
    # The adjudication named only `python3 -m unittest --help`, which reads as a
    # gap in the unittest alternative added a few commits ago. It is not: every
    # runner in TEST_PATTERN has a help flag, so a fix scoped to unittest would
    # have closed one door in a corridor. This guard is therefore written against
    # the FLAG rather than against any runner.
    #
    # Refusing to stamp is the safe direction, so this list errs toward catching
    # more: a `--dry-run` that really did run a suite costs one re-run, while a
    # `--help` that stamps unlocks the commit gate on a suite nobody executed.
    # `-list` IS SINGLE-DASH, and the first version of this list assumed every
    # interrogation flag wore two. A cross-vendor review of this very guard found it:
    # `go test -list .` matches TEST_PATTERN, misses NOT_A_RUN and stamps, and Go's
    # own documentation for `-list` says it runs no tests, benchmarks, fuzz targets
    # or examples. Go spells all of its test flags with one dash, so this is a whole
    # runner's worth of hole, not one flag's.
    NOT_A_RUN='(^|[[:space:]])(--help|-h|-\?|--usage|--version|-V|--collect-only|--co|--dry-run|--list|--list-tests|-list|--fixtures|--markers|--noexec|--check)([[:space:]]|=|$)'

    # The core must still BE a run: the suite has to lead it, after the wrappers
    # and flags RUN_LEAD allows. The pipe test that used to sit here is gone —
    # `|` is refused above, along with everything else that could reassign the
    # exit code, so there is nothing left for it to catch.
    echo "$CMD_CORE" | grep -qEi "${RUN_LEAD}${TEST_PATTERN}" || ATTRIBUTABLE=no

    # Checked separately from ATTRIBUTABLE so the message can say which of the two
    # very different things went wrong. "Your suite was not the last command" and
    # "you did not run a suite" need different corrections from the reader.
    INTERROGATION=no
    printf '%s' "$LAST_SEGMENT" | grep -qE "$NOT_A_RUN" && INTERROGATION=yes

    # A SUITE MUST HAVE ACTUALLY RUN SOMEWHERE BEFORE WE SAY ONE DID.
    #
    # The message below states "a test command ran". That was safe while a match
    # could only be a runner incantation — `pytest`, `npm test` — because naming
    # one of those on a line was rare. SUITE_SCRIPT widened a match to a FILENAME,
    # and filenames are named by ordinary commands constantly:
    #
    #   git add test-hooks.sh      -> "a test command ran"   FALSE
    #   cat check-plan.sh          -> "a test command ran"   FALSE
    #   ls test_thing.py           -> "a test command ran"   FALSE
    #
    # On main these are silent. This branch made them talk, and what they say is
    # untrue and unactionable — there is no suite to re-run as the only command.
    # A gate that cries wolf on `git add` teaches the reader to stop reading gate
    # output, which is the same harm as the bypass this branch exists to close,
    # arriving from the other side. Found by review-final before merge.
    #
    # The discriminator is whether ANY segment of the line is a run, rather than
    # whether the LAST one is. `npm test | tail -3` still speaks — a suite really
    # did run, just not where the exit code could describe it, which is exactly
    # what the message is for. `git add test-hooks.sh` goes back to silence.
    #
    # IT READS THE SAME SEGMENTS THE STAMP DOES, and the first version did not. It
    # split the raw command with `tr ';&|'`, which has no notion of quoting, so a
    # quoted mention counted as a run here even after the stamp path learned to
    # refuse it — and the false "a test command ran" line came back on exactly the
    # commands the previous round had silenced. Two splitters, two answers, one of
    # them wrong: the same twin-drift this repository keeps recording. One splitter
    # now, used by both. Pipes are still split here, because for MESSAGING a piped
    # suite genuinely did run.
    # A SUITE MUST LEAD THE LINE BEFORE WE SAY ONE RAN.
    #
    # This used to ask whether any SEGMENT was a run, which needed the splitter
    # that has now been deleted — and which lied on a heredoc body, because a
    # document naming a suite looked like a segment that ran one.
    #
    # The honest question a string can answer is narrower: did the command BEGIN
    # with a run? `npm test | tail -3` did, and the message is exactly right for
    # it. `git add test-hooks.sh`, `cat notes.md`, an `echo` of a multi-line body
    # and a heredoc did not, and stay silent. `npm ci && npm test` also stays
    # silent, which is the cost: a true case gets no advice rather than a false
    # case getting some.
    # FLATTENED, AND THE TIP COMMIT CLAIMED THIS WITHOUT IT. `grep` anchors `^` at
    # every line, so any line of a quoted body beginning with a suite read as a
    # command that began with a run — and a heredoc or a multi-line PR body printed
    # "a test command ran" when nothing had. The flatten step that prevented this
    # was deleted along with the splitter it belonged to.
    #
    # c5375de's message states in writing that heredocs and multi-line bodies are
    # silent. That was FALSE WHEN WRITTEN and is true now. Recorded here rather than
    # quietly corrected, because a commit message asserting something untrue about
    # its own change is worse than the defect: the next reader trusts it instead of
    # checking.
    RAN_SOMEWHERE=no
    printf '%s' "${CMD_CORE//$'\n'/ }" \
      | grep -qEi "${RUN_LEAD}${TEST_PATTERN}" && RAN_SOMEWHERE=yes

    if [ "$ATTRIBUTABLE" = no ] && [ "$RAN_SOMEWHERE" = no ]; then
        # Named a suite, ran nothing. Silence is right: this is an ordinary file
        # command that happens to mention a filename, and it is none of our business.
        :
    elif [ "$ATTRIBUTABLE" = no ]; then
        # Deliberately neither stamps nor clears: this run says nothing about the
        # suite either way, and destroying a good stamp because someone piped a
        # command would be its own annoyance.
        echo "VERIFICATION: a test command ran, but the exit code describes the whole line, not the test."
        echo "  Not stamping. Run the suite as the only command (no pipe, nothing after it) to verify."
    elif [ "$EXIT_CODE" = "0" ] && [ "$INTERROGATION" = yes ]; then
        # ORDER IS THE WHOLE CORRECTNESS OF THIS BRANCH, and the first draft had it
        # wrong. Testing INTERROGATION before the exit code made "not a run" swallow
        # FAILURES too: `pytest --collect-only` exiting 4 is a collection error, and
        # the pristine hook cleared the stamp for it. Placing the check above the
        # exit test made a stale green stamp SURVIVE that — a fail-open introduced by
        # a fix whose entire purpose was closing one. Found by a cross-vendor review
        # of this guard, an hour after it was written and hand-tested.
        #
        # So this branch is reached only when the command SUCCEEDED. A non-zero exit
        # falls through to the clear below exactly as it always did, and the message
        # can now say "it exits 0" because reaching here proves it.
        echo "VERIFICATION: that command asks the runner ABOUT itself (--help, --version, --collect-only, -list and similar). It is not a run, and it exits 0."
        echo "  Not stamping, and not clearing: a help screen is not evidence about the suite in either direction. Run the suite itself to verify."
    elif [ "$EXIT_CODE" = "0" ]; then
        # mkdir here, not at the top: $VERIFIED may live in another repository's
        # .claude/, which need not exist yet. Creating it only on a real pass keeps
        # this hook from scattering empty .claude dirs through every repo it sees.
        mkdir -p "$(dirname "$VERIFIED")"

        # THE STAMP RECORDS HOW IT WAS EARNED, not merely that it was.
        #
        # A review raised the asymmetry this fallback creates, and it is the
        # sharpest objection to this change: before it, an unreadable exit code
        # always CLEARED, so the failure direction was closed. Now absence is read
        # as success, so if the premise underneath — that PostToolUse does not fire
        # when a Bash command exits non-zero — is ever wrong, a RED suite writes a
        # PASS stamp. That is worse than what it replaced.
        #
        # The premise is tested, not assumed: a failing suite, and a missing make
        # target in a second repository, neither of which fired this hook. But two
        # observations on one harness version do not cover a timeout, a killed
        # process, or a future revision that starts delivering failing calls here.
        #
        # So the provenance is written into the stamp. `observed` means a real zero
        # was read; `inferred` means the field was absent and this hook concluded
        # success from its own invocation. verify-gate prints it when it unlocks, so
        # an inferred unlock is legible rather than silent — which is what
        # serina-learning#22 asked for in its own second suggestion:
        #
        #   "Make the stamp record what was verified, and when. An empty file
        #    cannot distinguish a real run from a touch."
        #
        # THIS MITIGATES; IT DOES NOT ELIMINATE. If the premise breaks, a red suite
        # still unlocks the gate — it just leaves evidence that it did. The stricter
        # alternative is to refuse to stamp on absence at all, which closes the
        # failure direction and returns the gate to being satisfiable only by its
        # own escape hatch. That trade is recorded here so it can be revisited
        # deliberately rather than rediscovered.
        # FOURTH FIELD: clean or flaky — Stage 3.
        #
        # `flaky` means this exact command failed within the ledger's window and
        # no edit has happened since, so the pass is a re-run rather than a fix.
        # verify-gate.sh refuses a flaky stamp unless the command is declared.
        #
        # The comparison is against LAST_SEGMENT, the same string the ledger was
        # written with — NOT the truncated form recorded below. Truncation is for
        # the stamp's readability; comparing a truncated command against a full
        # one would silently miss every command over 100 characters, which is
        # most real CI invocations.
        STAMP_FLAKE=clean
        if [ "$FLAKE_OK" = yes ] && flake_seen "$FLAKE_REPO" "$LAST_SEGMENT"; then
            STAMP_FLAKE=flaky
        fi
        echo "$(date +%s)|$(printf '%s' "$LAST_SEGMENT" | head -c 100)|$STAMP_BASIS|$STAMP_FLAKE" > "$VERIFIED"
        if [ "$STAMP_BASIS" = inferred ]; then
            echo "VERIFICATION STAMP: Tests/build passed (exit code INFERRED — the payload carried none). Commit gate unlocked."
        else
            echo "VERIFICATION STAMP: Tests/build passed. Commit gate unlocked."
        fi
    else
        # "unknown" lands here on purpose. An exit code this hook cannot read is not
        # evidence of success, and treating it as success was the original fail-open:
        # `[ "$EXIT_CODE" = "unknown" ]` used to sit in the branch above.
        rm -f "$VERIFIED"
        # REMEMBER THE FAILURE — Stage 3. Without this the next pass of the same
        # command is indistinguishable from a first-time pass, which is the whole
        # of run-until-green. Recorded here rather than anywhere earlier because
        # this is the one branch that knows the run actually failed.
        [ "$FLAKE_OK" = yes ] && flake_record "$FLAKE_REPO" "$LAST_SEGMENT"
        echo "VERIFICATION: Tests/build FAILED or unreadable (exit $EXIT_CODE). Stamp cleared. Fix issues before committing."
    fi
fi

exit 0
