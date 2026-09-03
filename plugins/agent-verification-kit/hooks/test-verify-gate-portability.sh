#!/usr/bin/env bash
# Does verify-gate.sh find check-models.sh as a SIBLING, with no CHECK_MODELS override?
#
# WHY THIS CONTROL EXISTS — added 2026-09-03, on adoption into this plugin.
#
# verify-gate.sh's CHECK_MODELS default was `$HOME/.claude/hooks/check-models.sh`: the
# original author's personal symlink layout. No adopter has that path, and the branch
# that consumes it FAILS CLOSED when the checker is missing — so an adopter's first
# commit touching `.claude/agents/*.md` would have been refused, citing a file they had
# never heard of. The default is now a sibling lookup.
#
# ---------------------------------------------------------------------------
# THIS FILE'S FIRST VERSION COULD NOT FAIL. Found 2026-09-04 by an adversarial
# review of the controls, and confirmed by mutation: the fix was reverted in a copy,
# this suite was run against it, and it reported 3 passed / 0 failed.
#
# The reason is specific and worth stating, because the same trap is one line away
# in any hook test. The control asserted that "the checker was found and enforced".
# On the AUTHOR'S machine `$HOME/.claude/hooks/check-models.sh` exists and is
# executable — it is the very symlink the plugin was extracted from. So BOTH the old
# and the new expression resolved to a working checker, both produced the same
# message, and the assertion held either way. The control was measuring "some
# checker was found", never "the SIBLING was found".
#
# A test that passes against the bug it exists to catch is worse than no test: it is
# a green light with nothing behind it, and it is exactly what this whole kit is
# about. The author had written a comment in this file warning that two outcomes
# sharing an exit code make an exit-code assertion meaningless — and then made the
# same error one level up, asserting on the message instead of on the file.
#
# TWO CHANGES CLOSE IT:
#
#   1. HOME IS ISOLATED. Every gate invocation below runs with HOME pointed at an
#      empty temp directory, so the old default CANNOT resolve. "Found and enforced"
#      can now only be true if the sibling was used.
#
#   2. THE MUTATION IS BAKED IN. Section 2 builds a copy of verify-gate.sh carrying
#      the OLD default — with a working sibling checker sitting right next to it —
#      and asserts that copy reports NOT-FOUND. That is what proves section 1 is
#      capable of failing, permanently and in-suite, rather than in a one-off
#      experiment somebody has to remember to repeat.
# ---------------------------------------------------------------------------

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
GATE="$HOOKS/verify-gate.sh"
pass=0; fail=0

for f in verify-gate.sh stamp-path.sh check-models.sh; do
    if [ ! -r "$HOOKS/$f" ]; then
        echo "FAIL  cannot read $HOOKS/$f — nothing was tested"; exit 1
    fi
done

check() {
    local label="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok    $label"; pass=$((pass + 1))
    else
        echo "FAIL  $label (expected '$want', got '$got')"; fail=$((fail + 1))
    fi
}

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
FAKEHOME="$box/fakehome"; mkdir -p "$FAKEHOME"

mkdir -p "$box/proj/.claude/agents"
git -C "$box/proj" init -q
printf -- '---\nname: broken\nmodel: sonnet-typo-xyz\n---\nbody\n' \
    > "$box/proj/.claude/agents/broken.md"
git -C "$box/proj" add -A

payload='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'

# The three outcomes are distinguished by MESSAGE because two of them share exit 2.
roster_verdict() {
    local out="$1"
    if printf '%s' "$out" | grep -q 'no executable checker'; then
        echo not-found
    elif printf '%s' "$out" | grep -q 'agent roster is invalid'; then
        echo found-and-enforced
    else
        echo "unrecognised: $(printf '%s' "$out" | head -1)"
    fi
}

# run_gate <path-to-gate> [extra env assignments...]
run_gate() {
    local gate="$1"; shift
    printf '%s' "$payload" | ( cd "$box/proj" && env -u CHECK_MODELS \
        HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$box" "$@" bash "$gate" 2>&1 )
}

echo "0. HOME really is isolated — otherwise every control below is meaningless:"
if [ ! -e "$FAKEHOME/.claude/hooks/check-models.sh" ]; then
    echo "ok    \$HOME/.claude/hooks/check-models.sh does not exist under the fake HOME"
    pass=$((pass + 1))
else
    echo "FAIL  the fake HOME contains the old default path — isolation failed"
    fail=$((fail + 1))
fi
echo

echo "1. the fix: with no CHECK_MODELS and HOME isolated, the SIBLING is used:"
check "the sibling checker is found and enforces" \
    "found-and-enforced" "$(roster_verdict "$(run_gate "$GATE")")"
echo

echo "2. THE MUTATION — the same suite against a copy carrying the OLD default."
echo "   A working sibling sits beside it, so not-found proves \$HOME was used:"
mkdir -p "$box/mutant"
cp "$HOOKS/verify-gate.sh" "$HOOKS/stamp-path.sh" "$HOOKS/check-models.sh" "$box/mutant/"
python3 - "$box/mutant/verify-gate.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
new = 'CHECK_MODELS="${CHECK_MODELS:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/check-models.sh}"'
old = 'CHECK_MODELS="${CHECK_MODELS:-$HOME/.claude/hooks/check-models.sh}"'
if new not in s:
    sys.exit("MUTATION TARGET NOT FOUND — the CHECK_MODELS line has changed shape")
open(p, 'w').write(s.replace(new, old))
PY
if [ $? -ne 0 ]; then
    echo "FAIL  could not build the mutant: the CHECK_MODELS line no longer matches."
    echo "      This control cannot prove anything until it is updated to the new shape."
    fail=$((fail + 1))
else
    echo "ok    the mutant was built (the fix's exact line was found and reverted)"
    pass=$((pass + 1))
    check "the old \$HOME default does NOT resolve, even with a sibling present" \
        "not-found" "$(roster_verdict "$(run_gate "$box/mutant/verify-gate.sh")")"
fi
echo

echo "3. fail-closed is intact when the checker genuinely is absent:"
out=$(printf '%s' "$payload" | ( cd "$box/proj" && env \
    CHECK_MODELS="$box/definitely-not-here.sh" HOME="$FAKEHOME" \
    CLAUDE_PROJECT_DIR="$box" bash "$GATE" 2>&1 ))
check "an absent checker still refuses the commit" "not-found" "$(roster_verdict "$out")"
echo

echo "4. vacuity guard — a VALID roster must not be refused by the roster rule:"
printf -- '---\nname: fine\nmodel: opus\n---\nbody\n' \
    > "$box/proj/.claude/agents/broken.md"
git -C "$box/proj" add -A
out=$(run_gate "$GATE")
if printf '%s' "$out" | grep -q 'agent roster is invalid'; then
    got=wrongly-refused
else
    got=not-refused-on-roster
fi
check "a valid roster is not refused (so controls 1-3 are about the model value)" \
    "not-refused-on-roster" "$got"
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
