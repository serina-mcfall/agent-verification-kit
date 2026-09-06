#!/usr/bin/env bash
# Controls for announce.sh — the channel that reaches a human.
#
# Written before the library existed and run against nothing, so the first run
# failed on the missing file.
#
# WHAT THIS LIBRARY IS FOR, MEASURED RATHER THAN ASSERTED.
#
# NOTE-0032 measured six nonces across three channels and two events, reported by
# a human who could not see the tokens in advance. systemMessage reaches a person
# on PreToolUse and PostToolUse. Plain stdout and stderr at exit 0 do not. stderr
# at exit 2 does, and every refusal in this kit already depends on it.
#
# So 40 of this kit's 66 announcement sites reach nobody, and 25 of those are
# fail-open warnings — the messages that say a gate has STOPPED GUARDING YOU.
#
# WHY CONTROL 4 IS THE ONE THAT MATTERS.
#
# 26 sites currently work. They are refusals: raw text on stderr at exit 2. If
# this change routes one of those through announce, a working gate becomes a
# silent one, and the fix has manufactured the defect it was written to remove —
# INC-0025's exact shape. Control 4 exists solely to catch that, and it is the
# reason this suite was written before a line of the library.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
LIB="$HOOKS/announce.sh"
pass=0; fail=0

if [ ! -r "$LIB" ]; then
    echo "FAIL  cannot read $LIB — nothing was tested"; exit 1
fi

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi }

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT

# Run a fragment in a REAL subshell process, because the EXIT trap and the exit
# status are the things under test and neither can be observed in-process.
#   run <body>  -> sets OUT, ERR, RC
run() {
    printf '%s\n' ". \"$LIB\"" "$1" > "$box/script.sh"
    OUT=$(bash "$box/script.sh" 2>"$box/err"); RC=$?
    ERR=$(cat "$box/err")
}

# --- 1. several announcements, ONE json object -----------------------------
# A hook may emit one JSON object on stdout. Sites announce and then continue,
# so the buffer must merge rather than flush per call.
# KILLING MUTATION: flush inside announce() instead of at exit.
run 'announce "first"; announce "second"; announce "third"'
count=$(printf '%s' "$OUT" | grep -c 'systemMessage' || true)
is "three announcements produce exactly one JSON object" "1" "$count"
if printf '%s' "$OUT" | grep -q first && printf '%s' "$OUT" | grep -q third; then
    ok "the single object carries every message"
else
    bad "the single object carries every message" "got: $OUT"
fi

# --- 2. hostile message text still yields valid JSON -----------------------
# KILLING MUTATION: build the JSON by string concatenation instead of a real
# encoder. Quotes and backslashes break it immediately.
run 'announce "he said \"stop\" and \\ then a \$VAR
and a second line"'
if printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    ok "quotes, backslashes, newlines and \$ still produce valid JSON"
else
    bad "quotes, backslashes, newlines and \$ still produce valid JSON" "got: $OUT"
fi

# --- 3. the EXIT trap PRESERVES exit status --------------------------------
# A trap that ends on a successful command silently rewrites a non-zero exit to
# zero. For a hook, exit status is the entire contract with the harness.
# KILLING MUTATION: drop the saved $? and let the trap's own status stand.
run 'announce "warned"; exit 0'
is "exit 0 stays 0 through the trap" "0" "$RC"
run 'announce "warned"; exit 2'
is "exit 2 stays 2 through the trap" "2" "$RC"
run 'announce "warned"; exit 7'
is "an arbitrary status survives the trap" "7" "$RC"

# --- 4. A REFUSAL IS UNTOUCHED --------------------------------------------
# The load-bearing control. Sourcing the library must not disturb a blocking
# path: raw text on stderr, nothing on stdout, exit 2.
# KILLING MUTATION: route a refusal through announce(), or make sourcing the
# library emit anything at all.
run 'echo "COMMIT BLOCKED — the real message" >&2; exit 2'
is "a refusal still exits 2" "2" "$RC"
is "a refusal writes NOTHING to stdout" "" "$OUT"
is "a refusal's text reaches stderr verbatim" "COMMIT BLOCKED — the real message" "$ERR"

# --- 5. silence stays silent ----------------------------------------------
# Emitting an empty systemMessage is output where there was none, and changes
# behaviour that was measured with none.
# KILLING MUTATION: flush unconditionally.
run 'exit 0'
is "a hook with nothing to say writes nothing to stdout" "" "$OUT"

# --- 6. the message ALSO reaches stderr ------------------------------------
# systemMessage is documented for 'some platforms'. Removing the stderr write
# would trade a channel nobody reads for one that might not render, and lose the
# debug-log copy this kit has always had.
run 'announce "keep a copy"'
if printf '%s' "$ERR" | grep -q "keep a copy"; then
    ok "the message is also written to stderr, so the debug log keeps it"
else
    bad "the message is also written to stderr, so the debug log keeps it" "stderr was: $ERR"
fi

# --- 7. no hard dependency on jq ------------------------------------------
# guard-test-changes stops enforcing when jq is absent. If announce needed jq,
# the warning about a missing dependency would itself depend on it.
# KILLING MUTATION: call jq unconditionally.
# bash must be invoked by ABSOLUTE PATH: emptying PATH also hides the shell, and
# the first draft of this control measured 'bash: command not found' rather than
# anything about jq. A control that fails for its own reasons proves nothing.
BASH_ABS=$(command -v bash)
printf '%s\n' ". \"$LIB\"" 'announce "no jq here"' > "$box/nojq.sh"
OUT=$(PATH="/nonexistent" "$BASH_ABS" "$box/nojq.sh" 2>"$box/err2"); RC=$?
ERR2=$(cat "$box/err2")
is "with neither encoder the hook still exits 0" "0" "$RC"
if printf '%s' "$ERR2" | grep -q "no jq here"; then
    ok "with neither encoder the message still reaches stderr"
else
    bad "with neither encoder the message still reaches stderr" "stderr was: $ERR2"
fi

# --- 8. jq ABSENT but python3 PRESENT — the fallback actually runs ---------
# ADDED AFTER MUTATION TESTING. The mutant 'call jq unconditionally' SURVIVED
# control 7, because control 7 removes jq and python3 together: with no encoder
# at all the expected result is 'stderr only, exit 0', which is also what the
# broken version produces. The fallback was never executed by any control.
#
# A control that cannot distinguish the fix from the defect is not a control.
# KILLING MUTATION: call jq unconditionally, or delete the python3 branch.
mkdir -p "$box/bin"
if PY=$(command -v python3); then
    ln -sf "$PY" "$box/bin/python3"
    printf '%s\n' ". \"$LIB\"" 'announce "fallback path"' > "$box/pyonly.sh"
    OUT=$(PATH="$box/bin" "$BASH_ABS" "$box/pyonly.sh" 2>/dev/null); RC=$?
    is "with jq hidden but python3 present, the hook exits 0" "0" "$RC"
    if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "fallback path" in d["systemMessage"] else 1)' 2>/dev/null; then
        ok "with jq hidden, python3 still emits valid JSON carrying the message"
    else
        bad "with jq hidden, python3 still emits valid JSON carrying the message" "got: $OUT"
    fi
else
    bad "python3 fallback control" "python3 not found — this control could not run"
fi

echo
echo "$pass passing, $fail failing"
[ "$fail" -eq 0 ]
