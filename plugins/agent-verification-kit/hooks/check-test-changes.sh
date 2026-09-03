#!/usr/bin/env bash
# The CI half of the test-modification guard. Reads a branch diff and refuses it
# if a test or test configuration changed without a `Test-change:` trailer naming
# that path.
#
#   bash check-test-changes.sh [BASE_REF]      default: origin/main
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS ALONGSIDE test-guard.sh
#
# test-guard.sh is a Claude Code hook. It sees Claude Code's Edit and Write calls
# and nothing else — not Codex, not an IDE, not a human, and not `rm`. It also
# checks a file the agent it constrains can write.
#
# This script reads git. A diff shows that a test changed however it changed: by
# Edit, by a different harness, by hand, or by deletion. And a commit trailer is in
# the permanent record, visible in the pull request, where a reviewer sees it and
# the author cannot quietly withdraw it.
#
# THAT IS STILL NOT AN INTEGRITY CONTROL, and the distinction has been got wrong in
# this programme's history, so it is spelled out. An agent writes commit messages
# too, so it can write the trailer. What changes is WHO ELSE SEES IT: a trailer is
# reviewable, a working-tree file is not. This buys visibility, not prevention.
# Prevention is a required status check plus a human, and that needs repo admin.
#
# ---------------------------------------------------------------------------
# EVERY FAILURE MODE HERE FAILS LOUD, FOR ONE RECORDED REASON
#
# The natural defect in a diff-based checker is that ALL of its failure modes
# produce an empty list, and an empty list looks exactly like "no test files were
# touched". A missing base ref, a shallow clone, a detached HEAD, a `git diff` that
# errored — all of them return nothing, and nothing reads as a pass.
#
# That is not hypothetical. It is INC-0006 in this kit's own record: a 404 from
# insufficient permission was read as proof that a configuration did not exist, and
# it produced a wrong headline finding. The rule that came out of it is three
# states, never two — found, absent, or COULD-NOT-DETERMINE — and this script
# implements it by exiting non-zero on could-not-determine rather than reporting a
# clean run.
# ---------------------------------------------------------------------------

set -u

BASE="${1:-${AVK_BASE_REF:-origin/main}}"
PATTERNS_LIB="${PATTERNS_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/test-patterns.sh}"

die() { printf 'check-test-changes: CANNOT DETERMINE — %s\n' "$1" >&2; exit 3; }

[ -r "$PATTERNS_LIB" ] || die "classifier not readable at $PATTERNS_LIB. Without it no path can be classified, and reporting a clean run would be a guess."
# shellcheck source=/dev/null
. "$PATTERNS_LIB"

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository (cwd $(pwd))."
[ -n "$REPO" ] || die "not inside a git repository (cwd $(pwd))."

git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
    || die "base ref '$BASE' does not resolve. In CI this usually means a shallow clone: fetch the base branch, or pass an explicit ref. An unresolvable base yields an empty diff, which would otherwise look exactly like a clean run."

MERGE_BASE=$(git merge-base "$BASE" HEAD 2>/dev/null) \
    || die "no merge base between '$BASE' and HEAD. Unrelated histories cannot produce a meaningful diff."

# ---------------------------------------------------------------------------
# `--diff-filter=MD --no-renames`, and every part of that is load-bearing.
#
# ADDED FILES ARE EXCLUDED (no `A`) BECAUSE THE TWO HALVES MUST AGREE.
# test-guard.sh never blocks creating a test — taxing new tests would train agents
# to avoid writing them, which is worse than anything this guard prevents. An
# earlier draft of this script used a bare `--name-only`, which includes additions,
# so the CI half would have demanded a trailer for every new test file the hook had
# just waved through. Two layers of one mechanism disagreeing about the same act is
# worse than either alone: whichever fires second looks like a bug, and the fix
# people reach for is to switch the check off.
#
# Found by asking what this script would say about the very commit that adds it —
# nine new test files, none of them a weakening, all of them flagged.
#
# `D` IS THE WHOLE POINT. A deleted test is the most direct form of the behaviour
# this exists to catch; EvilGenie (Nov 2025) caught agents deleting test files
# outright, and deletion is also the bypass test-guard.sh cannot see, because `rm`
# arrives as a Bash call rather than an Edit.
#
# `--no-renames` CLOSES THE GAP THAT OPENS WHEN ADDITIONS ARE FREE. With rename
# detection on, `git mv tests/test_a.py tests/renamed.py` reports as a single `R`,
# which `MD` would drop — so moving a test out of the way would need no
# declaration. Without it, the same act reports as one `D` and one `A`: the
# deletion is caught, the addition is free. That is exactly the right reading —
# moving a test away from the path that covered something IS the removal of that
# coverage.
# ---------------------------------------------------------------------------
CHANGED=$(git diff --no-renames --name-only --diff-filter=MD "$MERGE_BASE" HEAD 2>/dev/null) \
    || die "'git diff --no-renames --name-only --diff-filter=MD $MERGE_BASE HEAD' failed. An errored diff is not an empty diff."

# Trailers across the whole range, one per line, value only.
TRAILERS=$(git log --format='%(trailers:key=Test-change,valueonly)' "$MERGE_BASE..HEAD" 2>/dev/null) \
    || die "'git log' failed reading Test-change trailers over $MERGE_BASE..HEAD."

declared_reason() {
    local target="$1" line field
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        # Exact match on the first field, for the reason given in test-guard.sh:
        # a path appearing inside someone else's REASON text must not authorise it.
        field=${line%%[[:space:]]*}
        if [ "$field" = "$target" ]; then
            local reason=${line#"$field"}
            printf '%s' "${reason#"${reason%%[![:space:]]*}"}"
            return 0
        fi
    done <<< "$TRAILERS"
    return 1
}

n_changed=0; n_test=0; n_declared=0; n_missing=0
missing=()
missing_paths=()   # paths alone, for the copy-pasteable remedy at the bottom
declared=()

while IFS= read -r path; do
    [ -n "$path" ] || continue
    n_changed=$((n_changed + 1))
    class=$(avk_classify_path "$path" "$REPO")
    case "$class" in other) continue ;; esac
    n_test=$((n_test + 1))
    if reason=$(declared_reason "$path"); then
        n_declared=$((n_declared + 1))
        declared+=("$class  $path  — ${reason:-(no reason given)}")
    else
        n_missing=$((n_missing + 1))
        missing+=("$class  $path")
        missing_paths+=("$path")
    fi
done <<< "$CHANGED"

printf 'check-test-changes: base %s (merge-base %s)\n' "$BASE" "${MERGE_BASE:0:12}"
printf '  %d files modified or deleted, %d of them tests or test config\n' "$n_changed" "$n_test"
printf '  (newly ADDED files are not gated — creating a test never needs a declaration)\n'

# A CHECK THAT EXAMINED NOTHING SAYS SO. It is a pass — a branch touching no tests
# genuinely has nothing to declare — but reported as "0 examined" rather than as a
# clean bill of health, because those are different facts and the second one is the
# claim that gets quoted later.
if [ "$n_test" -eq 0 ]; then
    if [ "$n_changed" -eq 0 ]; then
        printf '  nothing was modified or deleted in this range — 0 paths examined, nothing verified.\n'
    else
        printf '  no test or test-config path was modified or deleted — 0 to declare.\n'
    fi
    exit 0
fi

if [ "$n_declared" -gt 0 ]; then
    printf '\n  declared:\n'
    for d in "${declared[@]}"; do printf '    %s\n' "$d"; done
fi

if [ "$n_missing" -eq 0 ]; then
    printf '\n  all %d declared. OK.\n' "$n_declared"
    exit 0
fi

printf '\n  UNDECLARED — this branch changes tests without saying why:\n' >&2
for m in "${missing[@]}"; do printf '    %s\n' "$m" >&2; done
cat >&2 << EOF

A test is the signal that says whether the code works, and test configuration can
make a failing test pass without touching an assertion. Either change may be
correct — but it has to be said out loud, in the permanent record, where a
reviewer sees it.

Add one trailer per path to any commit in this range:

    Test-change: <path> <why this had to change>

For example:

    git commit -s --amend --trailer "Test-change: ${missing_paths[0]} <reason>"

Amending is fine while the branch is unreviewed. If it has already been reviewed,
add a new commit carrying the trailers rather than rewriting what was approved.
EOF
exit 1
