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
# The existing roster controls in test-verify-gate.sh cannot catch a regression here,
# because every one of them injects CHECK_MODELS explicitly (see its lines 176 and 210).
# A default that no control exercises is a default nobody has ever seen run.
#
# THE DISTINCTION THAT MAKES THIS A TEST RATHER THAN THEATRE: "checker found, model
# rejected" and "checker not found, refusing anyway" are BOTH `exit 2`. Asserting on the
# exit code would pass whether the fix worked or not. These controls assert on which
# message came out.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
GATE="$HOOKS/verify-gate.sh"
pass=0; fail=0

if [ ! -r "$GATE" ]; then
    echo "FAIL  cannot read $GATE — nothing was tested"
    exit 1
fi

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
mkdir -p "$box/proj/.claude/agents"
git -C "$box/proj" init -q
printf -- '---\nname: broken\nmodel: sonnet-typo-xyz\n---\nbody\n' \
    > "$box/proj/.claude/agents/broken.md"
git -C "$box/proj" add -A

payload='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'

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

# 1. The fix itself: no CHECK_MODELS in the environment at all.
out=$(printf '%s' "$payload" | ( cd "$box/proj" && env -u CHECK_MODELS \
    CLAUDE_PROJECT_DIR="$box" bash "$GATE" 2>&1 ))
check "with no CHECK_MODELS set, the sibling checker is found and enforces" \
    "found-and-enforced" "$(roster_verdict "$out")"

# 2. Fail-closed is intact. Guards against the fix having quietly turned a
#    refusal into a pass for the genuinely-absent case.
out=$(printf '%s' "$payload" | ( cd "$box/proj" && env \
    CHECK_MODELS="$box/definitely-not-here.sh" \
    CLAUDE_PROJECT_DIR="$box" bash "$GATE" 2>&1 ))
check "an absent checker still refuses the commit (fail-closed intact)" \
    "not-found" "$(roster_verdict "$out")"

# 3. Vacuity guard. If a VALID roster also produced the refusal, controls 1 and 2
#    would prove nothing about the model value — only that the branch runs.
printf -- '---\nname: fine\nmodel: opus\n---\nbody\n' \
    > "$box/proj/.claude/agents/broken.md"
git -C "$box/proj" add -A
out=$(printf '%s' "$payload" | ( cd "$box/proj" && env -u CHECK_MODELS \
    CLAUDE_PROJECT_DIR="$box" bash "$GATE" 2>&1 ))
if printf '%s' "$out" | grep -q 'agent roster is invalid'; then
    got=wrongly-refused
else
    got=not-refused-on-roster
fi
check "a VALID roster is not refused by the roster rule (suite is not vacuous)" \
    "not-refused-on-roster" "$got"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
