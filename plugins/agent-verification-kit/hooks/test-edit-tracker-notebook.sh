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
# GAMMA IS A THIRD REPOSITORY AND IT EXISTS FOR ONE CONTROL.
#
# Every case below fires with cwd in a repository that is NOT the one the payload
# names, because that mismatch is the only arrangement in which reading the wrong
# key is distinguishable from reading the right one. For the precedence case that
# is not enough: if cwd is alpha AND file_path names a file in alpha, then
# "alpha cleared" is satisfied either by file_path being read and preferred, or
# by NOTHING being read and the no-path branch clearing cwd's own repository.
# Firing that case from gamma removes the coincidence.
for r in alpha beta gamma; do
    mkdir -p "$box/$r/tests" "$box/$r/.claude"
    git -C "$box/$r" init -q
done
echo '{"cells":[]}' > "$box/beta/tests/test_b.ipynb"
echo 'def test_b(): assert 1' > "$box/beta/tests/test_b.py"
echo 'def test_a(): assert 1' > "$box/alpha/tests/test_a.py"

stamp_both() {
    printf '%s|pytest|observed\n' "$(date +%s)" > "$box/alpha/.claude/.verified"
    printf '%s|pytest|observed\n' "$(date +%s)" > "$box/beta/.claude/.verified"
    printf '%s|pytest|observed\n' "$(date +%s)" > "$box/gamma/.claude/.verified"
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

# ---------------------------------------------------------------------------
# A BLANK OR FALSE file_path MUST NOT MASK A POPULATED notebook_path — kit#2.
#
# The controls above send exactly one key, so the ORDER of the two in the jq
# fall-through was never exercised. jq's `//` falls through on null and false
# only; an empty string is TRUTHY, so a payload carrying both keys with a blank
# first one returns "" and never reaches the notebook path. EDITED_FILE is then
# empty, the hook takes its no-path branch, and stamp_path_for is called WITH
# the cwd fallback — which is the ORIGINAL bug this whole file exists to close,
# arriving through a different door.
#
# The symptom is the same pair as ever: the WRONG repository's stamp is cleared.
# alpha (cwd, never edited) CLEARED, beta (edited) PRESENT.
#
# THE TWIN. Fixed in serina-learning by PR #143 on 2026-09-04 and not ported
# here for a day. Same commit as guard-test-changes.sh's, which carried the
# identical expression.
# ---------------------------------------------------------------------------
# run_raw_from_alpha <tool> <raw tool_input JSON>
# `--arg` makes every value a string, so there is no way to send a JSON `false`
# through run_from_alpha. That value is exactly what the regression guard needs.
run_raw_from_alpha() {
    run_raw_from "$box/alpha" "$@"
}

# run_raw_from <cwd> <tool> <raw tool_input JSON>
# The precedence case needs cwd in a repository that neither key names.
run_raw_from() {
    local cwd="$1"; shift
    jq -nc --arg t "$1" --argjson ti "$2" '{tool_name:$t, tool_input:$ti}' \
        | ( cd "$cwd" && CLAUDE_PROJECT_DIR="$box" bash "$TRACKER" >/dev/null 2>&1 )
}

echo "4. a blank or false file_path must not mask notebook_path:"

stamp_both
run_raw_from_alpha NotebookEdit "$(jq -nc --arg p "$box/beta/tests/test_b.ipynb" '{file_path:"", notebook_path:$p}')"
check "a BLANK file_path still clears BETA's stamp"        "cleared" "$(state "$box/beta")"
check "a BLANK file_path leaves ALPHA's stamp alone"       "present" "$(state "$box/alpha")"

# THE REGRESSION GUARD. An earlier fix elsewhere used
# `map(select(. != null and . != "")) | .[0] // empty`, which broke this case:
# `false` survives that select, lands in slot 0, and `.[0] // empty` re-applies
# jq's truthiness — where false IS falsy — collapsing to empty. The OLD chain
# handled it correctly. Green before the fix and must stay green after; it
# exists to kill the naive fix, not the bug.
stamp_both
run_raw_from_alpha NotebookEdit "$(jq -nc --arg p "$box/beta/tests/test_b.ipynb" '{file_path:false, notebook_path:$p}')"
check "a FALSE file_path still clears BETA's stamp"        "cleared" "$(state "$box/beta")"
check "a FALSE file_path leaves ALPHA's stamp alone"       "present" "$(state "$box/alpha")"

# Precedence is pinned: with both populated, file_path wins.
#
# FIRED FROM GAMMA, AND THAT IS THE WHOLE POINT. The first version of this control
# fired from alpha while naming a file in alpha, so "alpha cleared" was satisfied
# EITHER by file_path being read and preferred OR by nothing being read at all and
# the no-path branch clearing cwd's own repository. Found by a Codex review of
# this branch and confirmed by mutation: with EDITED_FILE replaced by a constant
# empty string, eight controls in this file went red and THIS PAIR STAYED GREEN.
#
# It is the second time that confound has been written in two days — the same
# defect was caught in serina-learning's suite on 2026-09-04 and fixed there the
# same way. Reading the fix is evidently not the same as not repeating it, which
# is why the third repository is described here rather than left to be inferred.
#
# With cwd in gamma, alpha can only be cleared by the payload actually being read,
# and gamma's own stamp is asserted intact so a cwd fallback cannot hide.
stamp_both
run_raw_from "$box/gamma" NotebookEdit "$(jq -nc --arg f "$box/alpha/tests/test_a.py" --arg n "$box/beta/tests/test_b.ipynb" '{file_path:$f, notebook_path:$n}')"
check "with both populated, file_path wins — ALPHA is cleared" "cleared" "$(state "$box/alpha")"
check "with both populated, BETA is left alone"                "present" "$(state "$box/beta")"
check "with both populated, cwd's own repo is left alone"      "present" "$(state "$box/gamma")"
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
