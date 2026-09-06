#!/usr/bin/env bash
# Controls for post-bash-failure.sh — the PostToolUseFailure hook.
#
# WHY IT EXISTS. Two shipped defects, one cause:
#
#   INC-0025  a failing test run does not clear the stamp, so a commit is allowed
#             after a red suite. post-bash.sh:501 was written to clear it and that
#             branch has never executed.
#   INC-0024  a failing test run is never recorded, so a re-run pass is
#             indistinguishable from a first pass and flake triage cannot fire.
#
# Both because Claude Code does not fire `PostToolUse` for a Bash call that exits
# non-zero. It fires `PostToolUseFailure`, and the kit never registered for it.
#
# THE DIRECTION OF STRICTNESS IS DELIBERATELY OPPOSITE TO post-bash.sh, and that is
# the design decision most worth reviewing here.
#
#   STAMPING is strict: if there is any doubt the exit code belongs to the test
#   command, write no stamp. A wrong stamp unlocks a commit.
#
#   CLEARING is liberal: if a failing command looks like a test run at all, clear.
#   A wrong clear costs one re-run of the suite. A wrong keep costs a commit on a
#   red suite.
#
# Same safety goal, opposite thresholds, because the two errors do not cost the
# same thing. A control below asserts the liberal direction explicitly so nobody
# "fixes" it into symmetry later.
#
# NOT YET VERIFIED AGAINST A REAL PAYLOAD. Hooks are fixed at session start, so a
# probe registered mid-session cannot fire. The field names below come from the
# harness's own /hooks screen — "Input to command is JSON with tool_name,
# tool_input, tool_use_id, error, error_type, is_interrupt, and is_timeout" — which
# is the harness describing its own contract, and is stronger than the assumption
# that produced INC-0024. It is still not a captured payload. Section 9 exists to
# fail the moment a real one disagrees.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SUT="$HOOKS/post-bash-failure.sh"
pass=0; fail=0

[ -r "$SUT" ] || { echo "FAIL  cannot read $SUT — nothing was tested"; exit 1; }

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

box=$(mktemp -d); trap 'rm -rf "$box"' EXIT

# new_repo <name> — a git repo with a fresh CLEAN stamp already in place.
new_repo() {
    local d="$box/$1"; mkdir -p "$d/.claude"; cd "$d" || return 1
    git init -q 2>/dev/null
    printf '%s|npm test|inferred|clean\n' "$(date +%s)" > "$d/.claude/.verified"
    printf '%s\n' "$d"
}
# fire <repo> <command> [extra-json]
fire() {
    local repo="$1" cmd="$2" extra="${3:-{\}}"
    OUT=$(python3 -c '
import json,sys,os
p = {"tool_name":"Bash","tool_input":{"command":os.environ["AVK_CMD"]},
     "tool_use_id":"toolu_x","error":"exit 1","error_type":"execution_error"}
p.update(json.loads(os.environ["AVK_EXTRA"]))
print(json.dumps(p))' 2>/dev/null <<<"" )
    AVK_CMD="$cmd" AVK_EXTRA="$extra" OUT=$(AVK_CMD="$cmd" AVK_EXTRA="$extra" python3 -c '
import json,os
p = {"tool_name":"Bash","tool_input":{"command":os.environ["AVK_CMD"]},
     "tool_use_id":"toolu_x","error":"exit 1","error_type":"execution_error"}
p.update(json.loads(os.environ["AVK_EXTRA"]))
print(json.dumps(p))')
    RC=0
    ERR=$(printf '%s' "$OUT" | ( cd "$repo" && env CLAUDE_PROJECT_DIR="$repo" \
        STAMP_LIB="$HOOKS/stamp-path.sh" FLAKE_LIB="$HOOKS/flake-ledger.sh" \
        COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
        bash "$SUT" 2>&1 >/dev/null )) || RC=$?
}
stamp_exists() { [ -f "$1/.claude/.verified" ]; }
ledger_has()   { grep -qF "$2" "$1/.claude/.failed-runs" 2>/dev/null; }

echo "0. NOT VACUOUS — a failing NON-test command changes nothing:"
d=$(new_repo ordinary); fire "$d" "grep somepattern somefile.txt"
stamp_exists "$d" && ok "a failed grep leaves the stamp alone" \
                  || bad "a failed grep leaves the stamp alone" "stamp was cleared"
ledger_has "$d" "grep" && bad "and records no flake" "grep landed in the ledger" \
                       || ok "and records no flake"
# Without this the hook would wipe verification on every failed ls in a session,
# and the first thing anyone would do is switch it off.

echo
echo "1. INC-0025 — a failing TEST command clears the stamp:"
d=$(new_repo failing); fire "$d" "npm test"
stamp_exists "$d" && bad "a failed 'npm test' clears the stamp" "stamp survived" \
                  || ok "a failed 'npm test' clears the stamp"

echo
echo "2. INC-0024 — and records the command in the flake ledger:"
ledger_has "$d" "npm test" && ok "the failed command is recorded for flake triage" \
                           || bad "the failed command is recorded for flake triage" \
                                  "$(cat "$d/.claude/.failed-runs" 2>/dev/null)"

echo
echo "3. a suite invoked by PATH is a test run too:"
d=$(new_repo bypath); fire "$d" "python3 test_thing.py"
stamp_exists "$d" && bad "a failed 'python3 test_thing.py' clears the stamp" "stamp survived" \
                  || ok "a failed 'python3 test_thing.py' clears the stamp"

echo
echo "4. AN INTERRUPTED CALL IS NOT A TEST FAILURE:"
# The strongest objection to the withdrawn PreToolUse design was that an interrupt
# is indistinguishable from a failure. On this event it is a field.
d=$(new_repo interrupted); fire "$d" "npm test" '{"is_interrupt": true}'
stamp_exists "$d" && ok "is_interrupt keeps the stamp" || bad "is_interrupt keeps the stamp" "cleared"
ledger_has "$d" "npm test" && bad "and records no flake" "interrupt recorded as a flake" \
                           || ok "and records no flake"

echo
echo "5. NOR IS A TIMEOUT:"
d=$(new_repo timedout); fire "$d" "npm test" '{"is_timeout": true}'
stamp_exists "$d" && ok "is_timeout keeps the stamp" || bad "is_timeout keeps the stamp" "cleared"
ledger_has "$d" "npm test" && bad "and records no flake" "timeout recorded as a flake" \
                           || ok "and records no flake"
# A timed-out suite tells you nothing about the code. Treating it as a failure
# would train people to re-run until the timeout stops, which is the exact
# behaviour flake triage exists to discourage.

echo
echo "6. CLEARING IS DELIBERATELY MORE LIBERAL THAN STAMPING:"
# post-bash refuses to stamp a chained command, because the exit code describes the
# whole line. This hook still CLEARS on one, because the costs are asymmetric: a
# wrong clear costs a re-run, a wrong keep costs a commit on a red suite.
d=$(new_repo chained); fire "$d" "cd /tmp && npm test"
stamp_exists "$d" && bad "a chained command containing a test still clears" "stamp survived" \
                  || ok "a chained command containing a test still clears"

echo
echo "7. THE TWO FIXES ARE NOT COUPLED:"
# INC-0025 must be closed even if the flake ledger is unavailable. If clearing the
# stamp depended on the ledger loading, one missing file would reopen the fail-open.
d=$(new_repo noledger)
RC=0
ERR=$(AVK_CMD="npm test" python3 -c '
import json,os
print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["AVK_CMD"]},
  "tool_use_id":"t","error":"exit 1","error_type":"execution_error"}))' \
  | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$box/definitely-absent.sh" COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
      bash "$SUT" 2>&1 >/dev/null )) || RC=$?
stamp_exists "$d" && bad "the stamp is cleared even with no flake ledger" "stamp survived" \
                  || ok "the stamp is cleared even with no flake ledger"
printf '%s' "$ERR" | grep -qi "ledger" \
    && ok "and it says the ledger was missing rather than failing silently" \
    || bad "and it says the ledger was missing rather than failing silently" "$ERR"

echo
echo "8. FAILURE MODES ANNOUNCE THEMSELVES:"
d=$(new_repo noclassifier)
RC=0
ERR=$(printf '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$box/absent.sh" \
      bash "$SUT" 2>&1 >/dev/null )) || RC=$?
printf '%s' "$ERR" | grep -qi "classifier\|classify" \
    && ok "a missing classifier is announced" || bad "a missing classifier is announced" "$ERR"
stamp_exists "$d" && ok "and nothing is cleared on a guess" \
                  || bad "and nothing is cleared on a guess" "stamp cleared without a classifier"

d=$(new_repo emptypayload)
RC=0
ERR=$(printf '' | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
      bash "$SUT" 2>&1 >/dev/null )) || RC=$?
printf '%s' "$ERR" | grep -qi "empty payload\|cannot see" \
    && ok "an empty payload is announced, not treated as 'no test failed'" \
    || bad "an empty payload is announced, not treated as 'no test failed'" "$ERR"

echo
echo "9. THE PAYLOAD CONTRACT THIS HOOK DEPENDS ON:"
# These names come from the harness's /hooks screen, NOT from a captured payload.
# If a real payload ever uses different names, this section is where it surfaces —
# INC-0024 happened because nothing checked the shape the harness actually sends.
d=$(new_repo contract); fire "$d" "npm test"
stamp_exists "$d" && bad "tool_input.command is where the command lives" "not read" \
                  || ok "tool_input.command is where the command lives"
d=$(new_repo contract2)
RC=0
printf '{"tool_name":"Bash","tool_input":{"command":"npm test"},"is_interrupt":false,"is_timeout":false}' \
  | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
      bash "$SUT" >/dev/null 2>&1 )
stamp_exists "$d" && bad "explicit false for both flags still clears" "stamp survived" \
                  || ok "explicit false for both flags still clears"

echo
echo "10. IT CAN NEVER BLOCK, so it must never try:"
# Per the harness: exit 2 shows stderr to the model; the tool already failed.
# Nothing this hook does should look like an attempt to veto.
d=$(new_repo exitcode); fire "$d" "npm test"
[ "$RC" = 0 ] && ok "exit code is 0 on the acting path" || bad "exit code is 0 on the acting path" "rc=$RC"
d=$(new_repo exitcode2); fire "$d" "grep x y"
[ "$RC" = 0 ] && ok "exit code is 0 on the no-op path" || bad "exit code is 0 on the no-op path" "rc=$RC"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
