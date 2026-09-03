#!/usr/bin/env bash
# Controls for check-test-changes.sh.
#
# The controls that matter most here are section 5. Every failure mode of a
# diff-based checker produces an empty result, and an empty result looks identical
# to "nothing to report". If a broken base ref, a missing classifier or a
# non-repository exits 0, this script is a green light with no measurement behind
# it — which is the exact defect recorded as INC-0006. Those cases must exit 3.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
CHECK="$HOOKS/check-test-changes.sh"
pass=0; fail=0

[ -r "$CHECK" ] || { echo "FAIL  cannot read $CHECK — nothing was tested"; exit 1; }

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT

GIT() { git -C "$REPO" -c user.name=T -c user.email=t@example.invalid "$@"; }

# fresh_repo — a repo with a `base` branch holding two tests and a source file,
# then a working branch off it. Every control starts from this shape.
fresh_repo() {
    REPO="$box/r$RANDOM$RANDOM"
    mkdir -p "$REPO/tests" "$REPO/src" "$REPO/my tests"
    git -C "$REPO" init -q -b base
    echo "def test_a(): assert 1" > "$REPO/tests/test_a.py"
    echo "def test_b(): assert 1" > "$REPO/tests/test_b.py"
    # A tracked test under a directory whose name contains a space. Present in
    # every fixture so section 12 can MODIFY it rather than add it — an addition
    # is not gated, so it could not exercise the declaration path at all.
    echo "def test_s(): assert 1" > "$REPO/my tests/test_s.py"
    echo "print(1)"               > "$REPO/src/main.py"
    echo "export default {}"      > "$REPO/playwright.config.ts"
    GIT add -A >/dev/null
    GIT commit -q -m "base"
    GIT checkout -q -b work
}

# run [args...] -> RC, OUT
run() {
    OUT=$( cd "$REPO" && bash "$CHECK" "${@:-base}" 2>&1 )
    RC=$?
}

check_rc() {
    local label="$1" want="$2"
    if [ "$RC" = "$want" ]; then
        echo "ok    $label"; pass=$((pass + 1))
    else
        echo "FAIL  $label (exit $RC, wanted $want)"
        printf '        %s\n' "$(printf '%s' "$OUT" | head -3)"
        fail=$((fail + 1))
    fi
}
check_says() {
    local label="$1" needle="$2"
    if printf '%s' "$OUT" | grep -q -- "$needle"; then
        echo "ok    $label"; pass=$((pass + 1))
    else
        echo "FAIL  $label (no '$needle' in output)"
        printf '        %s\n' "$(printf '%s' "$OUT" | head -3)"
        fail=$((fail + 1))
    fi
}

echo "0. the suite is not vacuous:"
fresh_repo
echo "print(2)" > "$REPO/src/main.py"
GIT commit -qam "change source only"
run
check_rc "a branch touching no tests passes" 0
check_says "and it reports that it had 0 to declare" "0 to declare"

fresh_repo
run
check_rc "an empty range passes" 0
check_says "but says plainly that it verified nothing" "nothing verified"
echo

echo "1. an undeclared test change is refused:"
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "weaken the assertion"
run
check_rc "a modified test with no trailer fails" 1
check_says "the failure names the path" "tests/test_a.py"
check_says "it shows the trailer to add" "Test-change:"
echo

echo "2. a DELETED test is caught — the bypass the hook cannot see:"
fresh_repo
GIT rm -q "$REPO/tests/test_a.py"
GIT commit -qm "remove the failing test"
run
check_rc "deleting a test with no trailer fails" 1
check_says "and the deleted path is named" "tests/test_a.py"
echo

echo "3. a trailer naming the path allows it:"
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "fix the assertion" --trailer "Test-change: tests/test_a.py the assertion asserted the bug"
run
check_rc "a declared test change passes" 0
check_says "and the reason is echoed back" "asserted the bug"
echo

echo "4. BYPASS ATTEMPTS:"
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "x" --trailer "Test-change: tests/test_b.py a different file"
run
check_rc "a trailer for another path does not authorise this one" 1

fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "x" --trailer "Test-change: tests/test_b.py while here I touched tests/test_a.py"
run
check_rc "a path inside someone else's reason does not authorise it" 1

fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "x" --trailer "Test-change: * everything"
run
check_rc "a blanket * trailer does not match" 1

fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
echo "def test_b(): pass" > "$REPO/tests/test_b.py"
GIT commit -qam "x" --trailer "Test-change: tests/test_a.py declared"
run
check_rc "declaring one of two changed tests still fails" 1
check_says "the declared one is listed as declared" "declared:"
check_says "and only the undeclared one is reported missing" "tests/test_b.py"
echo

echo "5. COULD-NOT-DETERMINE must exit 3, never 0 — the INC-0006 rule:"
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "weaken"
run "no-such-ref"
check_rc "an unresolvable base ref exits 3, not 0" 3
check_says "and says an empty diff would have looked like a clean run" "would otherwise look exactly like a clean run"

OUT=$( cd "$REPO" && PATTERNS_LIB="$box/gone.sh" bash "$CHECK" base 2>&1 ); RC=$?
check_rc "a missing classifier exits 3" 3
check_says "and refuses to guess" "would be a guess"

notrepo="$box/plain"; mkdir -p "$notrepo"
OUT=$( cd "$notrepo" && bash "$CHECK" base 2>&1 ); RC=$?
check_rc "running outside a git repository exits 3" 3
check_says "and says so" "not inside a git repository"
echo

echo "6. test configuration is covered too:"
fresh_repo
echo "export default { retries: 2 }" > "$REPO/playwright.config.ts"
GIT commit -qam "add retries"
run
check_rc "an undeclared config change fails" 1
check_says "it is classified as test-config" "test-config"
fresh_repo
echo "export default { retries: 2 }" > "$REPO/playwright.config.ts"
GIT commit -qam "x" --trailer "Test-change: playwright.config.ts CI hardware is slower than dev"
run
check_rc "a declared config change passes" 0
echo

echo "7. the trailer may live on any commit in the range, not just the last:"
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "x" --trailer "Test-change: tests/test_a.py declared early"
echo "print(3)" > "$REPO/src/main.py"
GIT commit -qam "later, unrelated commit"
run
check_rc "a trailer on an earlier commit still counts" 0
echo

echo "8. the two halves must AGREE about creation — added tests are not gated:"
fresh_repo
echo "def test_new(): assert 1" > "$REPO/tests/test_new.py"
GIT add -A >/dev/null
GIT commit -qm "add a new test, no trailer"
run
check_rc "adding a brand-new test needs no declaration" 0
check_says "and the output says so explicitly" "creating a test never needs a declaration"

fresh_repo
echo "def test_new(): assert 1" > "$REPO/tests/test_new.py"
echo "def test_a(): pass"      > "$REPO/tests/test_a.py"
GIT add -A >/dev/null
GIT commit -qm "add one test, weaken another"
run
check_rc "adding one test does not excuse weakening another" 1
check_says "only the modified path is reported" "tests/test_a.py"
if printf '%s' "$OUT" | grep -q 'tests/test_new.py'; then
    echo "FAIL  the newly added test was wrongly reported"; fail=$((fail + 1))
else
    echo "ok    the newly added test is not reported"; pass=$((pass + 1))
fi
echo

echo "9. moving a test away is a REMOVAL of coverage, not a free rename:"
fresh_repo
GIT mv tests/test_a.py tests/test_a_moved.py >/dev/null
GIT commit -qm "move it, no trailer"
run
check_rc "renaming a test requires a declaration for the old path" 1
check_says "the OLD path is what is reported" "tests/test_a.py"

fresh_repo
GIT mv tests/test_a.py tests/test_a_moved.py >/dev/null
GIT commit -qm "move it" --trailer "Test-change: tests/test_a.py moved into the integration directory"
run
check_rc "a declaration for the old path allows the move" 0

# The sharp case: renaming a test to a NON-test name removes coverage entirely and
# must not slip through just because the new name is no longer classified as a test.
fresh_repo
GIT mv tests/test_a.py src/retired_a.py >/dev/null
GIT commit -qm "retire it quietly"
run
check_rc "renaming a test to a non-test name still requires a declaration" 1
check_says "and names the test path that disappeared" "tests/test_a.py"
echo

echo "10. THE PRINTED REMEDY MUST ACTUALLY WORK:"
#
# This control exists because of a defect in this kit's ancestor, recorded as its
# issue #22: verify-gate.sh's refusal message documented an escape hatch, the
# message was wrong about the runners the project had, and the escape hatch became
# the trained route. The lesson was that a gate's message IS its user interface,
# and an untested instruction is a guess printed with authority.
#
# So this does not check the wording. It extracts the command the script tells you
# to run, runs it, and asserts the check then passes.
fresh_repo
echo "def test_a(): pass" > "$REPO/tests/test_a.py"
GIT commit -qam "weaken"
run
check_rc "undeclared, as set up" 1

suggested=$(printf '%s\n' "$OUT" | sed -n 's/.*--trailer "Test-change: \(.*\) <reason>".*/\1/p' | head -1)
if [ -n "$suggested" ]; then
    echo "ok    the message prints a suggested path: [$suggested]"; pass=$((pass + 1))
else
    echo "FAIL  the message printed no extractable suggestion"; fail=$((fail + 1))
fi
# No stray leading or trailing whitespace in what it tells you to paste. git
# happens to normalise a leading space out of a trailer value, so this is
# cosmetic rather than load-bearing — asserted anyway, because relying on another
# tool to clean up after your output is how a cosmetic defect becomes a real one
# the day the other tool stops doing it.
if [ "$suggested" = "$(printf '%s' "$suggested" | tr -d '[:space:]')" ]; then
    echo "ok    the suggested path carries no stray whitespace"; pass=$((pass + 1))
else
    echo "FAIL  the suggested path has stray whitespace: [$suggested]"; fail=$((fail + 1))
fi

GIT commit -q --amend --no-edit --trailer "Test-change: $suggested the assertion asserted the bug"
run
check_rc "running exactly what it told you to run makes the check pass" 0
check_says "and the reason is reported back" "asserted the bug"
echo

echo "11. A TYPE CHANGE IS A CHANGE — swapping a test file for a symlink:"
#
# WHY THIS CONTROL EXISTS. `--diff-filter=MD` covers Modified and Deleted, and git
# has a third status this mechanism cares about: `T`, type change. Replacing a
# tracked regular file with a symlink at the SAME PATH is one `T` entry, neither
# `M` nor `D`, so the filter dropped it entirely and this script reported
# "0 to declare" and exited 0.
#
# The content a test runner would read had been replaced wholesale — point the
# symlink at /dev/null and the suite collects nothing — with no declaration and a
# clean CI result. test-guard.sh cannot see it either, because the swap arrives as
# Bash rather than as an Edit. So NEITHER HALF saw it, which contradicts this
# file's own stated reason for existing: a diff shows that a test changed however
# it changed.
#
# Every fixture above modifies, deletes, adds or renames. Not one changes a file's
# TYPE, which is why 42 controls all passed over a hole this size. Found by an
# adversarial reviewer, not by this suite.
fresh_repo
rm "$REPO/tests/test_a.py"
ln -s /dev/null "$REPO/tests/test_a.py"
GIT add -A >/dev/null
GIT commit -qm "swap the test for a symlink to /dev/null"
# Confirm git really recorded a type change, so a green result below cannot be
# mistaken for "git did something else and the control tested nothing".
status=$(GIT diff --no-renames --name-status base HEAD | awk '{print $1}')
if [ "$status" = "T" ]; then
    echo "ok    git records the swap as a type change (T), as this control assumes"; pass=$((pass + 1))
else
    echo "FAIL  git recorded '$status', not 'T' — this control is testing the wrong thing"; fail=$((fail + 1))
fi
run
check_rc "a test swapped for a symlink, undeclared, fails" 1
check_says "and the path is named" "tests/test_a.py"

# The declared case must still pass, or the fix above would just be a blanket
# refusal of type changes rather than a declaration requirement.
fresh_repo
rm "$REPO/tests/test_a.py"
ln -s /dev/null "$REPO/tests/test_a.py"
GIT add -A >/dev/null
GIT commit -qm "swap it" --trailer "Test-change: tests/test_a.py replaced by a generated fixture symlink"
run
check_rc "the same swap, declared, passes" 0
echo

echo "12. A PATH CONTAINING A SPACE must be declarable here too:"
#
# Same defect as section 11 of test-test-guard.sh, in the trailer matcher rather
# than the declaration matcher: "the path" was `${line%%[[:space:]]*}`, so
# `my tests/test_s.py` extracted `my` and no trailer could ever satisfy it.
# Fail-closed — a legitimate change with no route to green, and the remedy the
# script prints reproduced the same un-matchable line.
#
# Every fixture above used space-free paths, which is why 46 controls passed over
# it.
fresh_repo
echo "def test_s(): pass" > "$REPO/my tests/test_s.py"
GIT commit -qam "weaken the spaced-path test"
run
check_rc "undeclared, as set up" 1
check_says "the spaced path is named" "my tests/test_s.py"

fresh_repo
echo "def test_s(): pass" > "$REPO/my tests/test_s.py"
GIT commit -qam "x" --trailer "Test-change: my tests/test_s.py the fixture path has a space"
run
check_rc "a trailer naming the spaced path allows it" 0
check_says "and the reason is reported back" "has a space"

# NEGATIVE — prefix matching must not degrade into substring matching.
fresh_repo
echo "def test_s(): pass" > "$REPO/my tests/test_s.py"
GIT commit -qam "x" --trailer "Test-change: my a first field that is a prefix"
run
check_rc "declaring just the first word does not authorise the whole path" 1

fresh_repo
echo "def test_s(): pass" > "$REPO/my tests/test_s.py"
GIT commit -qam "x" --trailer "Test-change: my tests/ the directory, not the file"
run
check_rc "declaring the directory prefix does not authorise the file" 1

# AND THE PRINTED REMEDY MUST WORK FOR IT — the section 10 discipline, applied to
# the case where the printed line is most likely to be wrong.
fresh_repo
echo "def test_s(): pass" > "$REPO/my tests/test_s.py"
GIT commit -qam "weaken it"
run
suggested=$(printf '%s\n' "$OUT" | sed -n 's/.*--trailer "Test-change: \(.*\) <reason>".*/\1/p' | head -1)
if [ "$suggested" = "my tests/test_s.py" ]; then
    echo "ok    the printed remedy names the spaced path in full: [$suggested]"; pass=$((pass + 1))
else
    echo "FAIL  the printed remedy mangled the spaced path: [$suggested]"; fail=$((fail + 1))
fi
GIT commit -q --amend --no-edit --trailer "Test-change: $suggested a reason"
run
check_rc "running exactly what it printed clears the check" 0
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
