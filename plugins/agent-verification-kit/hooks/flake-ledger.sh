#!/usr/bin/env bash
# Sourced library: remember which test commands FAILED, so a later pass of the
# same command can be told apart from a first-time pass.
#
# Not a hook. Sourced by post-bash.sh and edit-tracker.sh, exactly as
# stamp-path.sh is. verify-gate.sh does NOT source it — it reads a field from the
# stamp and greps a declaration file, so there is one less thing that can fail
# closed at the wrong scope.
#
# ---------------------------------------------------------------------------
# WHAT THIS CLOSES — Stage 3, and it was measured before it was designed.
#
# On 2026-09-04, in a scratch repository: a suite failed, was re-run with no code
# change, passed, wrote a verification stamp and unlocked a commit.
#
#     run 1:  python3 test_flaky.py  ->  exit 1, "FAILED: intermittent"
#     run 2:  python3 test_flaky.py  ->  exit 0, "1 passed"
#     stamp:  1788489511|python3 test_flaky.py|inferred
#     commit 9212df9: ALLOWED
#
# Both shipped stages miss it, for different reasons. Stage 1 sees only the final
# pass — the stamp protocol has no memory of the failure. Stage 2 never fires
# because no test file was touched, so guard-test-changes.sh has nothing to
# refuse. RUN-UNTIL-GREEN COSTS AN AGENT ONE EXTRA TOOL CALL AND DEFEATS BOTH.
#
# ---------------------------------------------------------------------------
# WHY AN EDIT CLEARS THE LEDGER, AND WHY THAT IS NOT A WEAKNESS
#
# Write a failing test -> implement -> pass is ALSO fail-then-pass. A detector
# that did not clear on edit would fire on every legitimate red-green cycle, and
# this kit's own false-positive rule says a mechanism that cries wolf is `fix` or
# `drop` however correct it is in principle. So edit-tracker.sh clears the ledger
# in the same call it already clears the stamp — no new machinery, and the
# clearing is driven by the same signal that already means "the tree changed".
#
# The bypass this creates is real and is stated rather than hidden: touch any
# file and the memory is gone. It is not, however, CHEAPER than compliance. An
# edit lands in the diff where a reviewer sees it; the declaration is one line.
# A bypass more expensive than the sanctioned route is the design working.
#
# ---------------------------------------------------------------------------
# THE BIGGER LIMITATION, STATED AT THE TOP RATHER THAN IN A FOOTNOTE
#
# NARROWING THE COMMAND DEFEATS THIS ENTIRELY. `pytest` fails, `pytest -k
# test_auth` passes, the command strings differ, no flake is seen. That is not
# evasion — narrowing to the failing test is correct debugging, for a person or
# an agent — which means the MOST NATURAL honest workflow also happens to be the
# bypass. No normalisation fixes it reliably across eight ecosystems.
#
# Matching is therefore EXACT, never by prefix. Stage 2's declaration file
# matches paths by prefix because a path is a token; a command is not. `npm test`
# is a strict prefix of `npm test -- --grep auth`, so prefix matching would make
# a narrowed command silently inherit the broader one's flake record and refuse a
# commit nobody could account for. Control 6 holds that line.
#
# ---------------------------------------------------------------------------
# Ledger format:  <epoch>|<command>   one line per distinct command
# Location:       <repo>/.claude/.failed-runs
# TTL:            30 minutes, matching the verification stamp for consistency of
#                 expectation. Asserted, not measured — nobody has established
#                 that 30 minutes is right for a long build.

FLAKE_LEDGER_TTL="${FLAKE_LEDGER_TTL:-1800}"

_flake_ledger_path() { printf '%s/.claude/.failed-runs' "$1"; }

# flake_record <repo-root> <command>
# Remember that <command> failed. Never fails the caller: this runs inside a
# PostToolUse hook, and a hook that aborts a tool call because it could not write
# a bookkeeping file is worse than one that forgets.
flake_record() {
    local repo="$1" cmd="$2" ledger
    [ -n "$repo" ] && [ -n "$cmd" ] || return 0
    ledger=$(_flake_ledger_path "$repo")
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || return 0

    # Rewrite rather than append, so recording the same command twice keeps one
    # entry and the file cannot grow without bound in a long session.
    local tmp="$ledger.$$"
    if [ -f "$ledger" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ "${line#*|}" = "$cmd" ] && continue
            printf '%s\n' "$line"
        done < "$ledger" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    else
        : > "$tmp" 2>/dev/null || return 0
    fi
    printf '%s|%s\n' "$(date +%s)" "$cmd" >> "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv "$tmp" "$ledger" 2>/dev/null || rm -f "$tmp"
    return 0
}

# flake_seen <repo-root> <command>
# 0 if this exact command failed within the TTL. EXACT, never prefix — see above.
flake_seen() {
    local repo="$1" cmd="$2" ledger now age
    [ -n "$repo" ] && [ -n "$cmd" ] || return 1
    ledger=$(_flake_ledger_path "$repo")
    [ -r "$ledger" ] || return 1
    now=$(date +%s)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *'|'*) ;; *) continue ;; esac   # malformed: ignore, never match
        [ "${line#*|}" = "$cmd" ] || continue
        age=$(( now - ${line%%|*} )) 2>/dev/null || continue
        [ "$age" -le "$FLAKE_LEDGER_TTL" ] && return 0
    done < "$ledger"
    return 1
}

# flake_clear <repo-root>
# Forget every failure for this repository. Called by edit-tracker.sh whenever
# the tree changes, because a pass after an edit is a fix, not a flake.
flake_clear() {
    local repo="$1"
    [ -n "$repo" ] || return 0
    rm -f "$(_flake_ledger_path "$repo")" 2>/dev/null
    return 0
}
