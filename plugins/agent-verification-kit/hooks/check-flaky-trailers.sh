#!/usr/bin/env bash
# The CI half of flake triage. Validates every `Flaky:` trailer on the branch and
# prints it, so a declared flake is visible to a reviewer instead of living in a
# gitignored file that expires in thirty minutes.
#
#   bash check-flaky-trailers.sh [BASE_REF]      default: origin/main
#
# ---------------------------------------------------------------------------
# THIS HALF IS WEAKER THAN STAGE 2's, AND THE DIFFERENCE IS STRUCTURAL
#
# check-test-changes.sh can catch an UNDECLARED test change, because the change
# itself is in the diff. There is no equivalent here. The stamp that knew a run
# was flaky is gitignored and expires; by the time CI runs, NOTHING in the
# repository records that a commit was made under one. So this script cannot
# detect a MISSING trailer. Only verify-gate can, because only verify-gate is
# standing there while the stamp still exists — and it does.
#
# What this buys is therefore narrower, and the README must say so: the trailers
# that ARE here are well-formed, and they are visible in the pull request.
#
# ---------------------------------------------------------------------------
# THE ONE FAIL-OPEN IT DOES CLOSE: the trailer that is not a trailer
#
# Git parses trailers only from the FINAL paragraph of a message. A `Flaky:` line
# written into the body — above a Signed-off-by, or with any paragraph after it —
# parses as ZERO trailers while looking completely correct in `git log`. A checker
# that read only parsed trailers would report that commit clean, and the author
# would believe they had declared something they had not. That cost three attempts
# on a single commit in serina-learning. So this script compares what git PARSED
# against what is literally written, and treats a discrepancy as a failure.
#
# ---------------------------------------------------------------------------
# EVERY FAILURE MODE FAILS LOUD — three states, never two
#
# As in check-test-changes.sh: a bad base ref, a shallow clone or a non-repo all
# produce an empty commit list, and an empty list looks exactly like "no flakes
# were declared". That confusion is INC-0006 in this kit's own record. Exit 3 for
# could-not-determine, never 0.
#
#   0  every Flaky: trailer found is well-formed (including: none were found)
#   1  at least one is malformed, or is not where git can parse it
#   3  could not check
# ---------------------------------------------------------------------------

set -u

BASE="${1:-${AVK_BASE_REF:-origin/main}}"

die() { printf 'check-flaky-trailers: CANNOT DETERMINE — %s\n' "$1" >&2; exit 3; }

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository (cwd $(pwd))."
[ -n "$REPO" ] || die "not inside a git repository (cwd $(pwd))."

git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
    || die "base ref '$BASE' does not resolve. In CI this usually means a shallow clone: fetch the base branch, or pass an explicit ref. An unresolvable base yields an empty commit list, which would otherwise look exactly like a branch declaring no flakes."

MERGE_BASE=$(git merge-base "$BASE" HEAD 2>/dev/null) \
    || die "no merge base between '$BASE' and HEAD. Unrelated histories, or a clone too shallow to reach the fork point."

COMMITS=$(git rev-list "$MERGE_BASE..HEAD" 2>/dev/null) \
    || die "git rev-list failed over $MERGE_BASE..HEAD."

n_commits=0
n_ok=0
problems=""
report=""

for sha in $COMMITS; do
    n_commits=$((n_commits + 1))
    subject=$(git log -1 --format='%s' "$sha")
    short="${sha:0:8}"

    # What git ACTUALLY parsed. NUL-separated so a value can hold anything but NUL.
    parsed=$(git log -1 --format='%(trailers:key=Flaky,valueonly,separator=%x00)' "$sha")
    # What is literally written anywhere in the message, trailer block or not.
    written=$(git log -1 --format='%B' "$sha" | grep -c '^[Ff]laky:[[:space:]]*[^[:space:]]')

    n_parsed=0
    if [ -n "$parsed" ]; then
        # Count NUL-separated fields without a subshell losing the count.
        n_parsed=$(printf '%s' "$parsed" | tr -cd '\000' | wc -c)
        n_parsed=$((n_parsed + 1))
    fi

    if [ "$written" -gt "$n_parsed" ]; then
        problems="$problems
  $short  $subject
      A Flaky: line is written in this message but git did NOT parse it as a
      trailer ($written written, $n_parsed parsed). Git reads trailers only from
      the FINAL paragraph, so a line with any paragraph after it records nothing.
      Rewrite the commit using --trailer \"Flaky: <command> #<issue> <reason>\",
      which puts it in the trailer block for you."
        continue
    fi

    [ "$n_parsed" -eq 0 ] && continue

    while IFS= read -r -d '' value; do
        # Format: <command> #<issue> <reason>
        case "$value" in
            *'#'[0-9]*) ;;
            *)
                problems="$problems
  $short  $subject
      Flaky: $value
      No issue number. A flake with no issue is a flake nobody has agreed to fix,
      which is the state this mechanism exists to make impossible to reach
      quietly. Use: --trailer \"Flaky: <command> #<issue> <reason>\"."
                continue ;;
        esac
        command="${value%%#[0-9]*}"
        # Trim trailing whitespace to test for an empty command.
        command="${command%"${command##*[![:space:]]}"}"
        if [ -z "$command" ]; then
            problems="$problems
  $short  $subject
      Flaky: $value
      Names no command. The issue is here but not WHICH suite is flaky, so nobody
      reading this can tell what to re-run. Put the command first:
      --trailer \"Flaky: <command> #<issue> <reason>\"."
            continue
        fi
        n_ok=$((n_ok + 1))
        report="$report
  $short  $value"
    done < <(printf '%s\000' "$parsed")
done

if [ -n "$problems" ]; then
    printf 'FLAKY TRAILER MALFORMED — checked %d commit(s) over %s..HEAD\n' \
        "$n_commits" "$BASE" >&2
    printf '%s\n' "$problems" >&2
    printf '\nA Flaky: trailer is the only durable record that a commit'\''s suite passed\non a re-run — .claude/.flaky is gitignored and expires. If it is malformed,\nthe commit reads as clean forever.\n' >&2
    exit 1
fi

# Say it CHECKED. Every failure mode of this script produces no findings, so an
# empty report and a skipped run must never look alike.
if [ "$n_ok" -eq 0 ]; then
    printf 'check-flaky-trailers: checked %d commit(s) over %s..HEAD — no Flaky: trailers declared.\n' \
        "$n_commits" "$BASE"
else
    printf 'check-flaky-trailers: checked %d commit(s) over %s..HEAD — %d declared flake(s):\n%s\n' \
        "$n_commits" "$BASE" "$n_ok" "$report"
    printf '\nEach names a suite that passed only on a re-run. They are recorded here so a\nreviewer sees them; the gate that required them cannot make anyone read them.\n'
fi
exit 0
