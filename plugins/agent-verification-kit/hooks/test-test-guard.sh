#!/usr/bin/env bash
# Controls for test-guard.sh.
#
# Row structure follows this kit's trial template: cases that SHOULD trip it, cases
# that SHOULD NOT, and cases that try to walk around it on purpose. The last group
# is not optional — every guard here is meant to survive an agent that would rather
# not be stopped, and a suite with no bypass attempts has not tested the guard.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
GUARD="$HOOKS/test-guard.sh"
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

payload() {
    jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p}}'
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

echo "$pass passed, $fail failed"
exit 0  # <-- the weakening: the suite can no longer fail
