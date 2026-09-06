#!/usr/bin/env bash
# PostToolUseFailure · Bash — the hook that learns a test run FAILED.
#
# Closes two shipped defects with one event:
#
#   INC-0025  a failing test run did not clear the verification stamp, so a commit
#             was permitted after a red suite. HIGH; the flagship mechanism.
#   INC-0024  a failing test run was never recorded, so a re-run pass could not be
#             distinguished from a first pass and flake triage could not fire.
#
# ---------------------------------------------------------------------------
# WHY THERE IS A SECOND HOOK AND NOT A FIX IN post-bash.sh
#
# post-bash.sh contains, at line 501, "Tests/build FAILED or unreadable. Stamp
# cleared." That branch has never executed. Claude Code does not fire `PostToolUse`
# for a Bash call that exits non-zero — it fires `PostToolUseFailure`, and this kit
# never registered for it. The failure handling was written, covered by controls,
# reviewed, shipped, and was dead code in the real harness for the whole time.
#
# So this is an event-subscription fix. Nothing about the old branch was wrong
# except that nothing ever called it.
#
# ---------------------------------------------------------------------------
# THE DIRECTION OF STRICTNESS IS THE OPPOSITE OF post-bash.sh, ON PURPOSE
#
#   STAMPING is strict. post-bash refuses to stamp unless it can show the exit code
#   belongs to the test command — no pipes, no chains, no ambiguity. A wrong stamp
#   unlocks a commit.
#
#   CLEARING is liberal. If a failing command looks like a test run at all, the
#   stamp goes. A wrong clear costs one re-run of the suite. A wrong keep costs a
#   commit on a red suite.
#
# Same goal, opposite thresholds, because the two errors do not cost the same
# thing. Do not "fix" this into symmetry — a control asserts the asymmetry.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT A TEST FAILURE
#
# `is_interrupt` and `is_timeout` arrive as their own fields on this event, and
# both mean "we learned nothing about the code". An interrupted suite is a
# cancelled suite. A timed-out suite that cleared the stamp would train people to
# re-run until the timeout stops — precisely the behaviour flake triage exists to
# discourage. Neither clears; neither is recorded.
#
# That those are separate fields is also what makes this design sound where the
# withdrawn alternative was not. The earlier proposal inferred failure from a
# `PreToolUse` "started" with no matching completion, and a review refuted it:
# permission denial, background execution, concurrency and cancellation all look
# identical to a failure under that scheme. Here the harness says which is which.
#
# ---------------------------------------------------------------------------
# THE PAYLOAD CONTRACT, AND HOW MUCH IT IS TRUSTED
#
# From the harness's own /hooks screen:
#
#   Input to command is JSON with tool_name, tool_input, tool_use_id, error,
#   error_type, is_interrupt, and is_timeout.
#
# There is no exit code, and none is needed: THE EVENT FIRING IS THE FAILURE.
#
# This is the harness describing its own contract, which is a stronger basis than
# the assumption that produced INC-0024 — but it is still not a captured payload.
# Every read below is defensive: a missing field is treated as absent rather than
# false, and an unreadable payload announces itself instead of passing quietly.
# ---------------------------------------------------------------------------

set -u

INPUT=$(cat)

# An empty payload means this hook cannot see the tool call. Say so. The failure
# mode of a silent no-op here is indistinguishable from "no test failed", which is
# the confusion this entire kit exists to prevent.
if [ -z "${INPUT//[[:space:]]/}" ]; then
    echo "post-bash-failure: empty payload — this hook cannot see the tool call, so a failing test run will not clear the stamp." >&2
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "post-bash-failure: jq not found — cannot read the payload, so a failing test run will NOT clear the stamp and is NOT being recorded." >&2
    exit 0
fi

# PARSE STATUS IS CHECKED SEPARATELY FROM THE VALUE. An earlier draft read the
# command with `jq -r ... 2>/dev/null` and exited quietly when it came back empty,
# so INVALID JSON and "this call had no command" were indistinguishable — and both
# silently preserved a stamp that a red suite should have cleared. The header of
# this file promises an unreadable payload announces itself; it did not.
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "post-bash-failure: payload is not a JSON object — cannot tell whether a test run failed, so the stamp is left standing. It may now outlive a red suite." >&2
    exit 0
fi
COMMAND=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.command | type) == "string" then .tool_input.command else empty end' 2>/dev/null)
if [ -z "$COMMAND" ]; then
    echo "post-bash-failure: no string .tool_input.command in the payload — this hook cannot tell what failed. If the harness has changed shape, INC-0024 is repeating." >&2
    exit 0
fi

# `== true` rather than truthiness: a missing field must read as absent, and jq's
# `//` would fall through on a literal false anyway. Both flags are checked
# independently because a call can be interrupted without timing out.
IS_INTERRUPT=$(printf '%s' "$INPUT" | jq -r '(.is_interrupt // false) == true' 2>/dev/null)
IS_TIMEOUT=$(printf '%s' "$INPUT" | jq -r '(.is_timeout // false) == true' 2>/dev/null)
if [ "$IS_INTERRUPT" = true ] || [ "$IS_TIMEOUT" = true ]; then
    exit 0
fi

# --- Is this a test run at all? -------------------------------------------------
# The pattern and the wrapper rule are shared with post-bash.sh rather than copied.
# Two copies would drift the first time a runner was added to one of them, and one
# hook would then act on a suite the other did not recognise — the fourth row of the
# README's bypass table.
COMMANDS_LIB="${COMMANDS_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/classify-test-commands.sh}"
if [ ! -r "$COMMANDS_LIB" ]; then
    # FAIL CLOSED, WHICH IS THE OPPOSITE OF WHAT post-bash DOES HERE, and the
    # asymmetry is the point. Without the classifier post-bash cannot tell a test
    # from anything else, so it declines to WRITE a stamp — safe. If this hook
    # likewise declined to CLEAR, a classifier that went missing after a green run
    # would reopen INC-0025 in silence. So: clear, and say why. The cost is that a
    # broken install wipes the stamp on any failed command, which is loud and
    # correct for a broken install.
    echo "post-bash-failure: command classifier missing at $COMMANDS_LIB — clearing the stamp anyway, because a failure occurred and this hook cannot rule out that it was a test run." >&2
    CLEAR_ANYWAY=yes
else
    CLEAR_ANYWAY=no
    # shellcheck source=/dev/null
    . "$COMMANDS_LIB"
fi

if [ "$CLEAR_ANYWAY" = no ]; then
    # ONE OPTIONAL LEADING `cd`, AND NOTHING ELSE COMPOUND. Exactly the shape
    # post-bash normalises, and the restriction is load-bearing rather than tidy.
    #
    # An earlier draft matched the pattern anywhere in the failing line. A review
    # showed two ways that breaks, both reproduced:
    #
    #   WRONG REPOSITORY. stamp_target_dir_from_command takes the FIRST textual
    #   `cd`, so `npm test; cd /repo-B; false` resolves to /repo-B — clearing an
    #   innocent repository's stamp while the one that actually went red keeps its
    #   green one. Fail-open AND collateral damage from a single line.
    #
    #   QUOTED TEXT. `echo "text; npm test"` and heredoc bodies read as executions
    #   once you start splitting on separators.
    #
    # Deciding which repository each command in an arbitrary chain ran in needs a
    # shell parser. Refusing chains needs one line. A failing suite inside a longer
    # chain therefore does NOT clear the stamp — a stated limitation, and the same
    # one post-bash already has for stamping, so the two stay consistent.
    CMD_CORE=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^&]*&&[[:space:]]*//')
    case $CMD_CORE in
        *';'*|*'|'*|*'&'*|*$'\n'*) exit 0 ;;
    esac

    # Anchored, not searching. `cat test-hooks.sh`, `ls test_foo.py`,
    # `grep -r "npm test" .` and `echo npm test` all NAME a suite without running
    # one; an unanchored match cleared the stamp on every one of them. A failed `ls`
    # silently wiping verification is how a gate gets switched off.
    printf '%s' "$CMD_CORE" | grep -qEi "${RUN_LEAD}${TEST_PATTERN}" || exit 0
fi

# --- Which repository's stamp? --------------------------------------------------
STAMP_LIB="${STAMP_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stamp-path.sh}"
if [ -r "$STAMP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$STAMP_LIB"
    VERIFIED=$(stamp_path_for "$(stamp_target_dir_from_command "$COMMAND")")
else
    echo "post-bash-failure: stamp resolver missing at $STAMP_LIB — clearing the shared path, which may not be the repository that was tested." >&2
    VERIFIED="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/.verified"
fi
REPO="${VERIFIED%/.claude/.verified}"

# --- INC-0025: clear the stamp. This must not depend on anything below it. ------
# Ordered first deliberately. If clearing waited on the flake ledger loading, one
# missing file would reopen the fail-open this hook exists to close.
if [ -f "$VERIFIED" ]; then
    rm -f "$VERIFIED"
    echo "VERIFICATION: '$COMMAND' FAILED. Stamp cleared — the commit gate will ask for a passing run."
fi

# --- INC-0024: record it, so a later pass on the same command reads as flaky ----
# RECORDING IS STRICTER THAN CLEARING, and that is the honest form of the asymmetry
# in this file's header. Clearing costs one re-run. A flake record costs a
# DECLARATION AND A COMMIT TRAILER on the next pass, which is far more than a
# re-run — so it is only written when the command is unambiguous.
#
# `cd /somewhere-missing && npm test` fails because the directory is absent; no
# suite ran. Clearing is still right, because verification is now in doubt. Calling
# the next successful `npm test` FLAKY would be wrong, and would tax an innocent
# commit. So a command with a `cd` prefix clears but is not recorded.
if [ "$CLEAR_ANYWAY" = no ] && [ "$CMD_CORE" = "$COMMAND" ]; then
    FLAKE_LIB="${FLAKE_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/flake-ledger.sh}"
    if [ -r "$FLAKE_LIB" ]; then
        # shellcheck source=/dev/null
        if . "$FLAKE_LIB"; then
            # CMD_CORE, not COMMAND: post-bash records and looks up LAST_SEGMENT,
            # which is this same normalised string. A different key here would mean
            # the ledger never matched on the later pass and flake triage would be
            # inert for a second, quieter reason.
            flake_record "$REPO" "$CMD_CORE"
        fi
    else
        echo "post-bash-failure: flake ledger missing at $FLAKE_LIB — the stamp was cleared, but this failure is NOT recorded, so a later re-run pass will read as a first pass." >&2
    fi
fi

exit 0
