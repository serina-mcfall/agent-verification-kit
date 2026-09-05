#!/usr/bin/env bash
# Controls for guard-test-changes.sh.
#
# Row structure follows this kit's trial template: cases that SHOULD trip it, cases
# that SHOULD NOT, and cases that try to walk around it on purpose. The last group
# is not optional — every guard here is meant to survive an agent that would rather
# not be stopped, and a suite with no bypass attempts has not tested the guard.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
GUARD="$HOOKS/guard-test-changes.sh"
pass=0; fail=0

if [ ! -r "$GUARD" ]; then
    echo "FAIL  cannot read $GUARD — nothing was tested"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL  jq is required to build the payloads these controls send"; exit 1
fi

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
REPO="$box/proj"
mkdir -p "$REPO/tests" "$REPO/src" "$REPO/.claude"
git -C "$REPO" init -q
echo "def test_a(): assert 1" > "$REPO/tests/test_a.py"
echo "def test_b(): assert 1" > "$REPO/tests/test_b.py"
echo "print(1)"               > "$REPO/src/main.py"
echo "export default {}"      > "$REPO/playwright.config.ts"

echo "{}"                     > "$REPO/tests/test_n.ipynb"

payload() {
    jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p}}'
}

# payload_raw <tool> <raw tool_input JSON> — for values a --arg cannot express.
# `--arg` makes everything a string, so there is no way to send a JSON `false`
# through the helper above, and `false` is exactly the value section 13 needs.
payload_raw() {
    jq -nc --arg t "$1" --argjson ti "$2" '{tool_name:$t, tool_input:$ti}'
}

# run_raw <tool> <raw tool_input JSON> -> sets RC and OUT, as `run` does.
run_raw() {
    OUT=$(payload_raw "$1" "$2" | ( cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1 ))
    RC=$?
}

# run <tool> <path> -> sets RC and OUT
run() {
    OUT=$(payload "$1" "$2" | ( cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1 ))
    RC=$?
}

check_rc() {
    local label="$1" want="$2"
    if [ "$RC" = "$want" ]; then
        echo "ok    $label"; pass=$((pass + 1))
    else
        echo "FAIL  $label (exit $RC, wanted $want)"
        printf '        %s\n' "$(printf '%s' "$OUT" | head -2)"
        fail=$((fail + 1))
    fi
}

check_says() {
    local label="$1" needle="$2"
    if printf '%s' "$OUT" | grep -q -- "$needle"; then
        echo "ok    $label"; pass=$((pass + 1))
    else
        echo "FAIL  $label (no '$needle' in output)"
        printf '        %s\n' "$(printf '%s' "$OUT" | head -2)"
        fail=$((fail + 1))
    fi
}

decl() { printf '%s\n' "$@" > "$REPO/.claude/.test-change"; }
nodecl() { rm -f "$REPO/.claude/.test-change"; }

echo "0. the suite is not vacuous — ordinary edits must pass:"
nodecl
run Edit "$REPO/src/main.py"
check_rc "an Edit to src/main.py is allowed" 0
run Bash "$REPO/tests/test_a.py"
check_rc "a non-edit tool is not this hook's business" 0
echo

echo "1. an undeclared change to an existing test is refused:"
nodecl
run Edit "$REPO/tests/test_a.py"
check_rc "Edit to tests/test_a.py is blocked" 2
check_says "the refusal names the exact path" "tests/test_a.py is a test file"
check_says "the refusal shows the line to write" "test-change"
check_says "the refusal says creating a new test is never blocked" "never blocked"
run Write "$REPO/tests/test_a.py"
check_rc "Write over an existing test is blocked too" 2
echo

echo "2. a declaration naming that exact path allows it:"
decl 'tests/test_a.py  the assertion was wrong, not the code'
run Edit "$REPO/tests/test_a.py"
check_rc "the declared path is allowed" 0
check_says "and it reports what authorised it" "the assertion was wrong"
echo

echo "3. BYPASS ATTEMPTS — each of these must still be refused:"
decl 'tests/test_b.py  a different file entirely'
run Edit "$REPO/tests/test_a.py"
check_rc "a declaration for another path does not authorise this one" 2

decl '*  everything, please'
run Edit "$REPO/tests/test_a.py"
check_rc "a blanket * does not match" 2

decl 'tests/*  the whole directory'
run Edit "$REPO/tests/test_a.py"
check_rc "a glob does not match — the path must be exact" 2

# The path appears in the line, but as part of the REASON, not as the field.
# Matching the path ANYWHERE in the line would wrongly authorise this.
decl 'tests/test_b.py  while here I also touched tests/test_a.py'
run Edit "$REPO/tests/test_a.py"
check_rc "a path mentioned inside someone else's reason does not authorise it" 2

decl '# tests/test_a.py  commented out'
run Edit "$REPO/tests/test_a.py"
check_rc "a commented-out declaration does not count" 2
echo

echo "4. a stale declaration is treated as absent:"
decl 'tests/test_a.py  declared two hours ago'
touch -d '2 hours ago' "$REPO/.claude/.test-change"
run Edit "$REPO/tests/test_a.py"
check_rc "a 2-hour-old declaration is blocked" 2
check_says "and it says the declaration was stale" "stale after 30m"
echo

echo "5. creating a new test is never blocked:"
nodecl
run Write "$REPO/tests/test_brand_new.py"
check_rc "a Write to a path that does not exist yet is allowed" 0
run Write "$REPO/tests/nested/deep/test_new.py"
check_rc "so is one in a directory that does not exist yet" 0
echo

echo "6. test CONFIGURATION is guarded separately, with its own reason:"
nodecl
run Edit "$REPO/playwright.config.ts"
check_rc "an undeclared config change is blocked" 2
check_says "it is named as configuration, not as a test file" "is test configuration"
check_says "and the message names the retry attack specifically" "adding retries hides a real race"
decl 'playwright.config.ts  raising the global timeout for CI hardware'
run Edit "$REPO/playwright.config.ts"
check_rc "a declared config change is allowed" 0
echo

echo "7. repository scoping — one repo's declaration is not another's:"
OTHER="$box/other"
mkdir -p "$OTHER/tests" "$OTHER/.claude"
git -C "$OTHER" init -q
echo "def test_c(): assert 1" > "$OTHER/tests/test_c.py"
decl 'tests/test_c.py  declared in the WRONG repository'
run Edit "$OTHER/tests/test_c.py"
check_rc "a declaration in repo A does not authorise an edit in repo B" 2
printf '%s\n' 'tests/test_c.py  declared in its own repository' > "$OTHER/.claude/.test-change"
run Edit "$OTHER/tests/test_c.py"
check_rc "the same declaration in its own repository does authorise it" 0
echo

echo "8. visible non-enforcement — a hook that cannot check must SAY so, not pass silently:"
OUT=$(printf '' | ( cd "$REPO" && bash "$GUARD" 2>&1 )); RC=$?
check_rc "an empty payload does not block" 0
check_says "an empty payload is announced as non-enforcement" "NOT enforcing"

OUT=$(jq -nc '{tool_name:"Edit",tool_input:{}}' | ( cd "$REPO" && bash "$GUARD" 2>&1 )); RC=$?
check_rc "a payload with no file_path does not block" 0
check_says "a missing file_path is announced" "NOT enforcing"
echo

echo "9. a missing classifier fails CLOSED for test-shaped paths and stands aside otherwise:"
nodecl
OUT=$(payload Edit "$REPO/tests/test_a.py" | ( cd "$REPO" && PATTERNS_LIB="$box/gone.sh" \
    CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1 )); RC=$?
check_rc "a test-shaped path is refused when the classifier is missing" 2
check_says "and it says why it refused rather than guessing" "would be the fail-open"

OUT=$(payload Edit "$REPO/src/main.py" | ( cd "$REPO" && PATTERNS_LIB="$box/gone.sh" \
    CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1 )); RC=$?
check_rc "an ordinary path is NOT refused when the classifier is missing" 0
check_says "but the non-enforcement is announced" "NOT enforcing"
echo

echo "10. NotebookEdit — a tool this hook CLAIMS to cover:"
#
# WHY THIS CONTROL EXISTS. `hooks.json` matches `Edit|Write|MultiEdit|NotebookEdit`
# and the `case "$TOOL"` allow-list names all four. But the target was read only
# from `.tool_input.file_path`, and NotebookEdit does not use that key — its
# parameter is `notebook_path`. Verified against this harness's own tool schema,
# not inferred.
#
# So every NotebookEdit call produced an empty TARGET, took the "carried no
# file_path — cannot classify it, so this call is allowed" branch, and exited 0.
# Every time, for every notebook, regardless of what it was. An entire tool the
# hook advertises was unguarded, and the message blamed a malformed payload rather
# than naming the real cause, so it read as ordinary noise instead of a total miss.
#
# The controls above could not have caught it: all 32 of them build payloads with
# `file_path`, because that is the key the implementation reads. A suite written
# against the implementation tests the implementation's assumptions back to itself.
nb_payload() {
    jq -nc --arg p "$1" '{tool_name:"NotebookEdit", tool_input:{notebook_path:$p, new_source:"x"}}'
}
nb_run() {
    OUT=$(nb_payload "$1" | ( cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1 ))
    RC=$?
}

mkdir -p "$REPO/tests"
echo '{"cells":[]}' > "$REPO/tests/test_analysis.ipynb"
echo '{"cells":[]}' > "$REPO/src/explore.ipynb"

nodecl
nb_run "$REPO/tests/test_analysis.ipynb"
check_rc "an undeclared NotebookEdit to an existing test notebook is blocked" 2
check_says "the refusal names the notebook" "tests/test_analysis.ipynb"

decl 'tests/test_analysis.ipynb  the fixture cell had the wrong expected frame'
nb_run "$REPO/tests/test_analysis.ipynb"
check_rc "a declared NotebookEdit is allowed" 0
check_says "and it reports what authorised it" "wrong expected frame"

# Vacuity: an ordinary notebook must NOT be blocked, or the fix is just a blanket
# refusal of NotebookEdit rather than a classification.
nodecl
nb_run "$REPO/src/explore.ipynb"
check_rc "a NotebookEdit to a non-test notebook is allowed" 0

# Creation stays free for notebooks too, matching the Edit/Write behaviour.
nb_run "$REPO/tests/test_brand_new.ipynb"
check_rc "creating a new test notebook is not blocked" 0

# A payload carrying NEITHER key must still be visible non-enforcement, not a block.
OUT=$(jq -nc '{tool_name:"NotebookEdit",tool_input:{new_source:"x"}}' \
    | ( cd "$REPO" && bash "$GUARD" 2>&1 )); RC=$?
check_rc "a NotebookEdit with no path at all does not block" 0
check_says "and says it is not enforcing on that call" "NOT enforcing"
echo

echo "11. A PATH CONTAINING A SPACE must be declarable:"
#
# WHY THIS CONTROL EXISTS. The declaration matcher took "the path" to be
# `${line%%[[:space:]]*}` — everything up to the first whitespace — and compared it
# for equality with the full relative path. For `my tests/test_a.py` that extracted
# `my`, which never equals the target, so there was NO WAY to declare such a path.
# The remedy the hook printed reproduced the same un-matchable line, so following
# the tool's own instructions could never clear the block.
#
# This one fails CLOSED — a permanent lockout on a legitimate change rather than a
# silent pass — which makes it less dangerous than the other findings and more
# annoying, and annoying is what gets a guard switched off. Every control above
# used space-free paths, so nothing caught it.
#
# The fix is prefix matching: a line declares a path if it IS that path, or is that
# path followed by whitespace. That handles spaces without quoting rules, and the
# negative controls below are what stop it becoming a substring match.
mkdir -p "$REPO/my tests"
echo "def test_s(): assert 1" > "$REPO/my tests/test_a.py"
echo "def test_sx(): assert 1" > "$REPO/my tests/test_a.pyx"

decl 'my tests/test_a.py  the fixture path has a space in it'
run Edit "$REPO/my tests/test_a.py"
check_rc "a spaced path can be declared and is allowed" 0
check_says "and the reason is reported" "space in it"

nodecl
run Edit "$REPO/my tests/test_a.py"
check_rc "the same spaced path, undeclared, is still blocked" 2

# NEGATIVE CONTROLS — prefix matching must not become substring matching.
decl 'my tests/test_a.pyx  a different, longer path'
run Edit "$REPO/my tests/test_a.py"
check_rc "a LONGER path declared does not authorise the shorter one" 2

decl 'my  a first field that is a prefix of the real path'
run Edit "$REPO/my tests/test_a.py"
check_rc "declaring just the first word does not authorise the whole path" 2

decl 'my tests/  the directory, not the file'
run Edit "$REPO/my tests/test_a.py"
check_rc "declaring the directory prefix does not authorise the file" 2
echo

# ---------------------------------------------------------------------------
# 13. A BLANK OR FALSE file_path MUST NOT MASK A POPULATED notebook_path.
#
#     jq's `//` falls through on null and false ONLY. An empty string is TRUTHY
#     in jq, so `.tool_input.file_path // .tool_input.notebook_path` returns ""
#     for a payload carrying both keys with a blank first one, and the notebook
#     path is never reached. TARGET is then empty, the hook takes its
#     "carried neither key" branch, and the edit is ALLOWED — a fail-open in the
#     one place this guard exists to hold.
#
#     kit#2. The identical defect was fixed in edit-tracker.sh's ancestor by
#     serina-learning PR #143 and NOT ported here, which is this repository's own
#     most-recorded pattern: a fix applied where the defect was reported and not
#     to its twin. Both twins are fixed in the same commit as this control lands.
#
#     Not reachable from Claude Code's own NotebookEdit — a real call was observed
#     resolving correctly through this very expression on 2026-09-04. This is
#     hardening against a future or third-party payload producer, which matters
#     because this ships as a plugin other people install.
# ---------------------------------------------------------------------------
echo "13. a blank or false file_path must not mask notebook_path:"

run_raw NotebookEdit "$(jq -nc --arg n "$REPO/tests/test_n.ipynb" '{file_path:"", notebook_path:$n}')"
check_rc "a BLANK file_path does not mask a populated notebook_path" 2

# 13b. THE REGRESSION GUARD, and it is not decoration.
#
#      The first attempt at this fix elsewhere used
#      `map(select(. != null and . != "")) | .[0] // empty`, which REGRESSED a
#      case the old `//` chain got right: `false` survives that select, lands in
#      slot 0, and `.[0] // empty` then re-applies jq's truthiness — where false
#      IS falsy — collapsing the pipeline to empty. The old expression returned
#      the notebook path correctly. So this control is GREEN before the fix and
#      must STAY green after it; it exists to kill the naive fix, not the bug.
run_raw NotebookEdit "$(jq -nc --arg n "$REPO/tests/test_n.ipynb" '{file_path:false, notebook_path:$n}')"
check_rc "a FALSE file_path does not mask a populated notebook_path" 2

# 13c. Precedence is pinned. With both keys populated and pointing at different
#      files, file_path wins — the documented choice, because three of the four
#      wired tools use it. Both paths here are test files, so the guard blocks
#      either way; the assertion is on WHICH path the refusal names.
run_raw NotebookEdit "$(jq -nc --arg f "$REPO/tests/test_a.py" --arg n "$REPO/tests/test_n.ipynb" '{file_path:$f, notebook_path:$n}')"
check_rc "with both keys populated the call is still refused" 2
if printf '%s' "$OUT" | grep -q "tests/test_a.py"; then
    echo "ok    and the refusal names file_path's target, not notebook_path's"; pass=$((pass + 1))
else
    echo "FAIL  and the refusal names file_path's target, not notebook_path's"
    printf '        %s\n' "$(printf '%s' "$OUT" | head -2)"; fail=$((fail + 1))
fi

# 13d. BOTH BLANK must still stand aside, or 13 could be satisfied by a change
#      that made every empty payload resolve to something — trading a masked
#      notebook path for a confidently wrong one.
run_raw NotebookEdit '{"file_path":"", "notebook_path":""}'
check_rc "both keys blank still stands aside rather than guessing" 0

# 13e. Non-vacuity for this section: a non-test path with the same shape must
#      still be allowed, or 13 would pass under a guard that blocks everything.
run_raw NotebookEdit "$(jq -nc --arg n "$REPO/src/main.py" '{file_path:"", notebook_path:$n}')"
check_rc "a blank file_path with a NON-test notebook_path is still allowed" 0
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
