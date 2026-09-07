#!/usr/bin/env bash
# announce.sh — say something a human will actually receive.
#
# SOURCED, never executed. Controls: test-announce.sh.
#
# WHY THIS EXISTS, MEASURED RATHER THAN ASSUMED.
#
# NOTE-0032, 2026-09-06: six nonces across three channels and two events,
# reported by a human who could not see the tokens in advance.
#
#   systemMessage (JSON on stdout)  reaches a person on PreToolUse AND PostToolUse
#   plain stdout, exit 0            reaches nobody
#   stderr, exit 0                  reaches nobody
#   stderr, exit 2                  reaches a person, verbatim — refusals rely on it
#
# 40 of this kit's 66 announcement sites were on the two dead channels. 25 of
# those are fail-open warnings: the messages that say a gate has stopped
# guarding you. They were correct, loud, and delivered to nothing.
#
# WHAT THIS LIBRARY MUST NEVER DO.
#
# Touch a refusal. Refusals write raw text to stderr and exit 2. That path works
# and is observed working. Routing one through here would turn a working gate
# silent and manufacture the very defect this fixes — INC-0025's shape. Control
# 4 exists for that and nothing else.
#
# Sourcing this file emits nothing, changes no exit status, and sets no trap
# until announce() is actually called. A hook that never announces behaves
# exactly as it did before this library existed.

# Buffer, because a hook may emit only ONE JSON object on stdout and several
# sites announce before continuing. Prefixed names: hooks source this, and a
# collision with a hook's own variable would be a silent corruption.
_ANNOUNCE_BUF=""
_ANNOUNCE_TRAP_SET=no

announce() {
    [ $# -gt 0 ] || return 0
    _announce_msg="$*"
    [ -n "$_announce_msg" ] || return 0

    # The debug-log copy stays. systemMessage is documented only for "some
    # platforms", and this kit has always written stderr; removing it would
    # trade a channel nobody reads for one that might not render.
    printf '%s\n' "$_announce_msg" >&2

    if [ -n "$_ANNOUNCE_BUF" ]; then
        _ANNOUNCE_BUF="$_ANNOUNCE_BUF
$_announce_msg"
    else
        _ANNOUNCE_BUF="$_announce_msg"
    fi

    if [ "$_ANNOUNCE_TRAP_SET" = no ]; then
        trap '_announce_flush' EXIT
        _ANNOUNCE_TRAP_SET=yes
    fi
    return 0
}

# Encoding is DELEGATED. JSON assembled by string concatenation breaks on the
# first quote, backslash or newline, and every message here interpolates paths
# and command text. jq first because the kit already depends on it; python3
# because guard-test-changes fails open when jq is absent, and a warning about a
# missing dependency must not itself require that dependency.
_announce_emit() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg m "$1" '{systemMessage: $m}'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c \
            'import json,sys; print(json.dumps({"systemMessage": sys.stdin.read()}))'
    fi
    # Neither available: the message already went to stderr. Silence here is
    # correct — a broken half-written JSON object would be worse than none.
}

# EXIT STATUS IS THE ENTIRE CONTRACT WITH THE HARNESS.
#
# The first draft of this comment claimed a trap ending on a failing command
# rewrites the exit status. MEASURED 2026-09-06, and it is not true in bash:
#
#   trap 'false' EXIT; exit 2   ->  2
#   trap 'true'  EXIT; exit 2   ->  2
#
# bash preserves the status either way. The explicit save-and-restore below is
# therefore DEFENCE, not the load-bearing thing the comment first said it was —
# it guards against this function being changed later to end in an explicit
# `exit 0`, which is the mutation that does break it and which control 3 kills.
# Kept, because verify-gate turning a refusal into permission is the worst
# failure this kit could have, and the cost of keeping it is two lines.
#
# Bash does not re-enter an EXIT trap, so exiting from inside it is safe.
_announce_flush() {
    _announce_rc=$?
    if [ -n "$_ANNOUNCE_BUF" ]; then
        _announce_emit "$_ANNOUNCE_BUF"
        _ANNOUNCE_BUF=""
    fi
    exit "$_announce_rc"
}
