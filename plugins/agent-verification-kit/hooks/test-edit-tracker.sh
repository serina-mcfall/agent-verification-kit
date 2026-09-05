#!/usr/bin/env bash
# Controls for edit-tracker.sh.
#
# WHY THIS FILE DID NOT EXIST UNTIL NOW, AND WHAT THAT COST. PR #67 added 34 lines
# to edit-tracker.sh resolving a per-repository stamp, claimed "three suites
# passing", and none of the three touched this hook. A reviewer proved it by
# reverting the entire new block to the single pre-fix line and re-running all
# three: 0 failures. The hook carrying the live bug was the one hook with no
# controls at all.
#
# The bug those absent controls would have caught: `git -C <dir>` does not return
# empty for a directory that does not exist, it FAILS — so a Write creating
# `alpha/newdir/new.py` fell through to the cwd fallback and cleared whatever
# repository the hook happened to be standing in. Control 1 is that case.
#
# EVERY CONTROL HERE HAS A MUTATION THAT TURNS IT RED, verified rather than
# asserted. A control whose guard can be deleted while it stays green is not a
# control, and this project has shipped several.
set -uo pipefail

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
HOOK="$HOOK_DIR/edit-tracker.sh"
LIB="${STAMP_LIB_UNDER_TEST:-$HOOK_DIR/stamp-path.sh}"

PASSED=0; FAILED=0
ok()  { printf 'ok    %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL  %s\n     %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT

# Two sibling repositories inside a container that is NOT itself a repository.
# That is the real shape of ~/Launchpad, and it is the shape in which the shared
# stamp fails — a container session root with many repositories under it.
for r in alpha beta "spaced dir"; do
    mkdir -p "$BOX/$r/.claude"
    git -C "$BOX/$r" init -q
done
mkdir -p "$BOX/notarepo/.claude"

stamps() { for r in alpha beta "spaced dir"; do touch "$BOX/$r/.claude/.verified"; done
           mkdir -p "$BOX/.claude"; touch "$BOX/.claude/.verified"; }

present() { [ -f "$BOX/$1/.claude/.verified" ] && printf PRESENT || printf CLEARED; }

# fire <cwd> <tool> <file_path> [extra-env...]
# Runs the hook exactly as the host does: payload on stdin, CLAUDE_PROJECT_DIR
# set to the CONTAINER, cwd somewhere that may not be the edited repository.
fire() {
    local cwd="$1" tool="$2" path="$3"; shift 3
    ( cd "$cwd" && printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path" \
        | env CLAUDE_PROJECT_DIR="$BOX" STAMP_LIB="$LIB" "$@" bash "$HOOK" ) 2>"$BOX/err" >/dev/null
}

# ---------------------------------------------------------------------------
# 1. THE LIVE BUG. A Write naming a directory that does not exist yet, from a cwd
#    inside a DIFFERENT repository.
#
#    Both halves are asserted and both matter. Clearing alpha is the job; leaving
#    beta alone is the defect. A control asserting only "alpha cleared" would have
#    passed against the buggy code on a day when cwd happened to be alpha.
# ---------------------------------------------------------------------------
stamps; fire "$BOX/beta" Write "$BOX/alpha/newdir/new.py"
if [ "$(present alpha)" = CLEARED ] && [ "$(present beta)" = PRESENT ]; then
    ok "a write into a not-yet-existing directory clears the edited repo, not the cwd repo"
else
    bad "a write into a not-yet-existing directory clears the edited repo, not the cwd repo" \
        "alpha=$(present alpha) beta=$(present beta)"
fi

# 2. The same, several levels deep. `dirname` must walk up more than one step.
stamps; fire "$BOX/beta" Write "$BOX/alpha/a/b/c/d/deep.py"
if [ "$(present alpha)" = CLEARED ] && [ "$(present beta)" = PRESENT ]; then
    ok "the ancestor walk climbs several missing levels, not one"
else
    bad "the ancestor walk climbs several missing levels, not one" \
        "alpha=$(present alpha) beta=$(present beta)"
fi

# 3. The ordinary case must not regress: an existing directory still resolves.
stamps; touch "$BOX/alpha/existing.py"; fire "$BOX/beta" Edit "$BOX/alpha/existing.py"
if [ "$(present alpha)" = CLEARED ] && [ "$(present beta)" = PRESENT ]; then
    ok "an edit to an existing file still clears its own repository"
else
    bad "an edit to an existing file still clears its own repository" \
        "alpha=$(present alpha) beta=$(present beta)"
fi

# 4. Editing the cwd repository must still work. Guarding against a fix that
#    breaks the common case in order to fix the rare one.
stamps; fire "$BOX/beta" Edit "$BOX/beta/own.py"
if [ "$(present beta)" = CLEARED ] && [ "$(present alpha)" = PRESENT ]; then
    ok "an edit inside the cwd repository clears that repository"
else
    bad "an edit inside the cwd repository clears that repository" \
        "alpha=$(present alpha) beta=$(present beta)"
fi

# 5. A path containing a space. Quoting bugs in path handling are silent and
#    this repository's own working tree sits under a path that could acquire one.
stamps; fire "$BOX/beta" Write "$BOX/spaced dir/newdir/x.py"
if [ "$(present 'spaced dir')" = CLEARED ] && [ "$(present beta)" = PRESENT ]; then
    ok "a repository path containing a space resolves correctly"
else
    bad "a repository path containing a space resolves correctly" \
        "spaced=$(present 'spaced dir') beta=$(present beta)"
fi

# 6. A file in no repository at all falls back to the container stamp, and must
#    NOT reach into a sibling repository to find something to clear.
stamps; fire "$BOX/beta" Write "$BOX/notarepo/newdir/x.py"
if [ ! -f "$BOX/.claude/.verified" ] \
   && [ "$(present alpha)" = PRESENT ] && [ "$(present beta)" = PRESENT ]; then
    ok "a file outside any repository clears the container stamp and no repository's"
else
    bad "a file outside any repository clears the container stamp and no repository's" \
        "container=$([ -f "$BOX/.claude/.verified" ] && echo PRESENT || echo CLEARED) alpha=$(present alpha) beta=$(present beta)"
fi

# 7. A payload with no file_path is abnormal. It must SAY so, not silently pick a
#    repository. The message is asserted, not just the exit status — a hook that
#    degrades quietly is how the original shared-stamp bug survived so long.
stamps
( cd "$BOX/beta" && printf '{"tool_name":"Write","tool_input":{}}' \
    | env CLAUDE_PROJECT_DIR="$BOX" STAMP_LIB="$LIB" bash "$HOOK" ) 2>"$BOX/err" >/dev/null
if grep -q 'no file_path' "$BOX/err"; then
    ok "an empty payload path is reported on stderr, not silently absorbed"
else
    bad "an empty payload path is reported on stderr, not silently absorbed" \
        "stderr: $(head -1 "$BOX/err")"
fi

# 8. A missing resolver must announce itself. It falls back to the old shared
#    path, which is the pre-fix behaviour, so it must never be silent.
stamps
( cd "$BOX/beta" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$BOX/alpha/x.py" \
    | env CLAUDE_PROJECT_DIR="$BOX" STAMP_LIB="$BOX/does-not-exist.sh" bash "$HOOK" ) 2>"$BOX/err" >/dev/null
if grep -q 'stamp resolver missing' "$BOX/err"; then
    ok "a missing stamp resolver is announced on stderr"
else
    bad "a missing stamp resolver is announced on stderr" "stderr: $(head -1 "$BOX/err")"
fi

# ---------------------------------------------------------------------------
# 9-11. stamp_repo_root's contract, exercised directly. These are the guards the
#       hook depends on, and testing them only through the hook would leave the
#       failure mode ambiguous when one goes red.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$LIB"

got=$(stamp_repo_root "$BOX/alpha/nope/nope" nofallback)
[ "$got" = "$(cd "$BOX/alpha" && pwd -P)" ] \
    && ok "nofallback resolves a missing directory to its real repository" \
    || bad "nofallback resolves a missing directory to its real repository" "got [$got]"

# THE POINT OF nofallback. From inside beta, an unresolvable hint must yield
# NOTHING rather than beta. Under `fallback` the same call yields beta, and that
# difference is the entire bug.
got=$( cd "$BOX/beta" && stamp_repo_root "$BOX/notarepo/nope" nofallback )
[ -z "$got" ] \
    && ok "nofallback yields nothing rather than substituting the cwd repository" \
    || bad "nofallback yields nothing rather than substituting the cwd repository" "got [$got]"

got=$( cd "$BOX/beta" && stamp_repo_root "$BOX/notarepo/nope" fallback )
[ "$got" = "$(cd "$BOX/beta" && pwd -P)" ] \
    && ok "fallback still returns the cwd repository, as post-bash and verify-gate need" \
    || bad "fallback still returns the cwd repository, as post-bash and verify-gate need" "got [$got]"

# 12. An unrecognised mode must take the SAFE branch and say so. Defaulting a
#     typo to the permissive option is how a guard gets quietly disabled.
got=$( cd "$BOX/beta" && stamp_repo_root "$BOX/notarepo/nope" typo 2>"$BOX/err" )
if [ -z "$got" ] && grep -q 'unknown mode' "$BOX/err"; then
    ok "an unrecognised mode falls to nofallback and warns"
else
    bad "an unrecognised mode falls to nofallback and warns" "got [$got] stderr: $(head -1 "$BOX/err")"
fi

# ---------------------------------------------------------------------------
# AN EDIT CLEARS THE FLAKE LEDGER TOO — Stage 3.
#
# This hook already clears the verification stamp of the edited file's
# repository. It now clears that repository's flake ledger in the same call, and
# the reason is not tidiness: it is what stops the flake detector firing on
# ordinary work.
#
# Write a failing test -> implement -> pass is ALSO fail-then-pass. Without this,
# every legitimate red-green cycle would be reported as a flake, and this kit's
# own false-positive rule says a mechanism that cries wolf is `fix` or `drop`
# however correct it is in principle. Measured end to end on 2026-09-05 BEFORE
# this landed: with the ledger uncleared, a fail, an edit, then a pass produced
# a stamp reading `flaky` — a false positive on the most common workflow there is.
#
# The bypass it creates is real and stated rather than hidden: touch any file and
# the memory is gone. It is not cheaper than compliance, though — an edit lands
# in the diff where a reviewer sees it, and the declaration is one line.
# ---------------------------------------------------------------------------
ledger() { [ -f "$BOX/$1/.claude/.failed-runs" ] && printf PRESENT || printf CLEARED; }

echo
echo "an edit clears the flake ledger of the edited repository:"

stamps
printf '%s|npm test\n' "$(date +%s)" > "$BOX/beta/.claude/.failed-runs"
printf '%s|npm test\n' "$(date +%s)" > "$BOX/alpha/.claude/.failed-runs"
fire "$BOX/alpha" Edit "$BOX/beta/tests/test_b.py"
if [ "$(ledger beta)" = CLEARED ]; then
    ok "an edit in beta clears BETA's flake ledger"
else
    bad "an edit in beta clears BETA's flake ledger" "beta ledger=$(ledger beta)"
fi
# The same scoping the stamp has, for the same reason: clearing the wrong
# repository's memory is a silent false negative in the repository that was
# edited and a silent false positive in the one that was not.
if [ "$(ledger alpha)" = PRESENT ]; then
    ok "and it leaves ALPHA's flake ledger alone"
else
    bad "and it leaves ALPHA's flake ledger alone" "alpha ledger=$(ledger alpha)"
fi

# Non-vacuity: clearing must be driven by the edit, not by the helper. If the
# ledger were absent to begin with, the assertions above would pass against a
# hook that did nothing at all.
stamps
printf '%s|npm test\n' "$(date +%s)" > "$BOX/beta/.claude/.failed-runs"
if [ "$(ledger beta)" = PRESENT ]; then
    ok "the ledger really was there before the edit"
else
    bad "the ledger really was there before the edit" "beta ledger=$(ledger beta)"
fi

# A missing ledger must not turn an ordinary edit into an error.
stamps
rm -f "$BOX/beta/.claude/.failed-runs"
fire "$BOX/alpha" Edit "$BOX/beta/tests/test_b.py"
if [ "$(present beta)" = CLEARED ]; then
    ok "an edit with no ledger present still clears the stamp, without erroring"
else
    bad "an edit with no ledger present still clears the stamp, without erroring" \
        "beta stamp=$(present beta)"
fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
