#!/usr/bin/env bash
# Does edit-tracker.sh clear the stamp of the repository whose notebook was edited?
#
# WHY THIS FILE EXISTS — added 2026-09-04, from Serina's review of the kit.
#
# edit-tracker.sh reads its target from `.tool_input.file_path`. NotebookEdit does
# not use that key; its parameter is `notebook_path`. The hook is wired for
# NotebookEdit in hooks.json, so a notebook edit produced an empty EDITED_FILE and
# fell to the branch that resolves the stamp from the hook's OWN CWD instead.
#
# THE FAILURE IS NOT "THE STAMP SURVIVES", which is what it looks like at first and
# what a single-repository test would report. It is that the WRONG repository's
# stamp is cleared. Measured, with cwd in alpha and a test notebook edited in beta:
#
#   alpha stamp (never touched)   CLEARED    an unnecessary re-run
#   beta  stamp (was edited)      PRESENT    the edit was not invalidated
#
# Fail-open and fail-closed at the same time — the exact pair edit-tracker.sh's own
# header records from 2026-08-10, reintroduced through a different door. And it is
# invisible in a single-repo session, because there cwd and the edited repository
# are the same directory. `~/Launchpad` holds ten repositories and several
# concurrent sessions, which is precisely the shape that exposes it.
#
# THIS IS A SEPARATE FILE, not an addition to test-edit-tracker.sh, so that the
# adopted suite stays byte-identical to the reviewed original and everything the
# plugin added is legible as the plugin's own. Same reasoning as
# test-verify-gate-portability.sh.
#
# The cross-repo shape is the whole control. A same-repo assertion passes against
# the bug.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
TRACKER="$HOOKS/edit-tracker.sh"
pass=0; fail=0

for f in edit-tracker.sh stamp-path.sh; do
    [ -r "$HOOKS/$f" ] || { echo "FAIL  cannot read $HOOKS/$f — nothing was tested"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAIL  jq is required to build these payloads"; exit 1; }

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
for r in alpha beta; do
    mkdir -p "$box/$r/tests" "$box/$r/.claude"
    git -C "$box/$r" init -q
done
echo '{"cells":[]}' > "$box/beta/tests/test_b.ipynb"
echo 'def test_b(): assert 1' > "$box/beta/tests/test_b.py"

stamp_both() {
    printf '%s|pytest|observed\n' "$(date +%s)" > "$box/alpha/.claude/.verified"
    printf '%s|pytest|observed\n' "$(date +%s)" > "$box/beta/.claude/.verified"
}
state() { [ -f "$1/.claude/.verified" ] && echo present || echo cleared; }

# run_from_alpha <tool> <key> <path>
# cwd is ALPHA while the edit lands in BETA. That mismatch is the point: it is the
# only arrangement in which reading the wrong payload key is distinguishable from
# reading the right one.
run_from_alpha() {
    jq -nc --arg t "$1" --arg k "$2" --arg p "$3" \
        '{tool_name:$t, tool_input:({} | .[$k] = $p)}' \
        | ( cd "$box/alpha" && CLAUDE_PROJECT_DIR="$box" bash "$TRACKER" >/dev/null 2>&1 )
}

echo "0. the control is not vacuous — the Edit path must already be correct:"
stamp_both
run_from_alpha Edit file_path "$box/beta/tests/test_b.py"
check "an Edit in beta clears BETA's stamp"        "cleared" "$(state "$box/beta")"
check "an Edit in beta leaves ALPHA's stamp alone" "present" "$(state "$box/alpha")"
echo

echo "1. the finding: a NotebookEdit must behave identically:"
stamp_both
run_from_alpha NotebookEdit notebook_path "$box/beta/tests/test_b.ipynb"
check "a NotebookEdit in beta clears BETA's stamp"        "cleared" "$(state "$box/beta")"
check "a NotebookEdit in beta leaves ALPHA's stamp alone" "present" "$(state "$box/alpha")"
echo

echo "2. a payload carrying neither key still falls back, and says so:"
stamp_both
out=$(jq -nc '{tool_name:"NotebookEdit", tool_input:{new_source:"x"}}' \
    | ( cd "$box/alpha" && CLAUDE_PROJECT_DIR="$box" bash "$TRACKER" 2>&1 ))
if printf '%s' "$out" | grep -q 'falling back'; then
    echo "ok    the fallback is announced rather than silent"; pass=$((pass + 1))
else
    echo "FAIL  a pathless payload was absorbed silently"; fail=$((fail + 1))
fi
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
