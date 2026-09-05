#!/usr/bin/env bash
# Run every control suite in this kit, and refuse to report success unless the
# list of them is honest.
#
# WHY THIS EXISTS AT ALL
#
# The kit had ten suites and no single command that ran them. That gap bit from
# both directions within two days:
#
#   - Earning a verification stamp meant picking one suite arbitrarily, so the
#     stamp attested to that suite rather than to the set. `verify-gate.sh` then
#     unlocked a commit on evidence narrower than it appeared.
#   - `review-final`'s verdict.sh refused to record READY because it could not
#     resolve a test command for this repository, and correctly refused rather
#     than waiving the check.
#
# WHY IT OWNS THE LIST, IN A FILE
#
# `.github/workflows/verification.yml` used to carry the suite list TWICE — once
# in its staleness guard and once in the step that ran them. Two copies of one
# list, in one file, is the drift this repository's README names as its most
# recurrent defect, and nothing would have caught them diverging. The list now
# lives in `controls.list` beside this script, and the workflow calls this
# script, so there is exactly one copy.
#
# A FILE RATHER THAN A HEREDOC, so this script can be pointed at a fixture
# directory with a different list. A runner whose list is baked in cannot be
# tested except against the repository it ships in, and a control suite that can
# only run against real data is one this kit would reject anywhere else.
#
# THE LIST IS EXPLICIT AND THEREFORE GOES STALE. That is the trade, and it is the
# right way round: a glob cannot tell you a suite has gone MISSING. This list has
# already gone stale once — `test-edit-tracker-notebook.sh` was written,
# committed, and left out of CI for a commit, so nine suites ran while ten
# existed. Both directions are checked below.
#
# EVERY `test-*.sh` IS A CONTROL SUITE AND NOTHING ELSE. Implementations are
# named for what they do, which is why this file is `check-controls.sh` and not
# `test-runner.sh`. An unlisted `test-*.sh` fails the run rather than being
# quietly skipped or quietly globbed in.
#
# Usage:  check-controls.sh [hooks-directory]
# Exit:   0 every suite listed, present and green
#         1 anything else — including a missing or empty list

set -uo pipefail

DIR="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
LIST="$DIR/controls.list"
status=0

# ABSENT IS NOT EMPTY AND NEITHER IS CLEAN.
#
# Without this, a missing or empty list would iterate zero suites, report no
# failures, and exit 0 — a green run that tested nothing. That is the exact
# fail-open shape this kit exists to close, and it would be especially poor here.
if [ ! -f "$LIST" ]; then
    echo "check-controls: no controls.list at $LIST — cannot tell which suites should exist, so this is a failure, not an empty run." >&2
    exit 1
fi

suites=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%[[:space:]]}"
    case "$line" in ''|\#*) continue ;; esac
    suites+=("$line")
done < "$LIST"

if [ "${#suites[@]}" -eq 0 ]; then
    echo "check-controls: controls.list at $LIST names no suites — zero suites run must never read as green." >&2
    exit 1
fi

in_list() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# Both directions, because they catch different mistakes: an unlisted file is a
# suite that never runs, and a listed-but-absent file is a suite someone deleted
# or renamed without saying so.
for f in "$DIR"/test-*.sh; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    in_list "$b" "${suites[@]}" || {
        echo "check-controls: $b matches test-*.sh but is not in controls.list. Every test-* file is a control suite; add it, or name the implementation for what it does." >&2
        status=1
    }
done
for s in "${suites[@]}"; do
    [ -f "$DIR/$s" ] || {
        echo "check-controls: $s is listed in controls.list but does not exist." >&2
        status=1
    }
done

[ "$status" = 0 ] || { echo "check-controls: the suite list and the directory disagree — nothing was run." >&2; exit 1; }

# ONE FAILING SUITE MUST NOT HIDE THE REST. A run that stops at the first red
# tells you about one defect when there may be four, and the next run then finds
# the second one, which reads as a regression rather than as pre-existing.
ran=0; failed=0
for s in "${suites[@]}"; do
    if bash "$DIR/$s" > /tmp/check-controls.$$.out 2>&1; then
        printf 'PASS  %s\n' "$s"
    else
        printf 'FAIL  %s\n' "$s"
        sed 's/^/      /' /tmp/check-controls.$$.out | tail -20
        failed=$((failed + 1))
    fi
    ran=$((ran + 1))
done
rm -f /tmp/check-controls.$$.out

printf '\n%d suites run, %d failing\n' "$ran" "$failed"
[ "$failed" -eq 0 ]
