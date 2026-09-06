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
# THE DIRECTION OF STRICTNESS, IN THREE STEPS, and it is not a single dial.
# An earlier draft had one — "clearing is liberal" — and a review showed it clears
# the stamp on a failed `ls test_foo.py` and, worse, clears the WRONG repository's
# stamp on a chained command. Both reproduced. So:
#
#   WHAT COUNTS AS A RUN is exactly what post-bash counts, via the shared
#   classifier. Naming a suite is not running one, in either hook.
#
#   CLEARING is liberal about DOUBT: post-bash refuses to stamp when it cannot
#   attribute an unknown exit code, but here the failure is certain — the event
#   only fires on one — so ambiguity about which command failed still clears.
#   Verification in doubt should not stand.
#
#   RECORDING A FLAKE is the strictest of the three, because it is the most
#   expensive: it costs a declaration and a commit trailer on the next pass, not
#   just a re-run. Only an unambiguous bare command is recorded.
#
# Controls assert all three, including the limitation that a chain is refused.
#
# NOT YET VERIFIED AGAINST A REAL PAYLOAD. Hooks are fixed at session start, so a
# probe registered mid-session cannot fire. The field names come from the harness's
# own /hooks screen — "Input to command is JSON with tool_name, tool_input,
# tool_use_id, error, error_type, is_interrupt, and is_timeout" — which is the
# harness describing its own contract, and is stronger than the assumption that
# produced INC-0024. It is still not a captured payload.
#
# Section 12 is scoped honestly about that: fixtures cannot detect a contract
# change, because a fixture is the contract you already believe in. What it does
# assert is that the hook reads the documented names and no others, so a change
# surfaces as a red control rather than as silence.

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
echo "6. NAMING A SUITE IS NOT RUNNING ONE:"
# The first draft of this hook matched the pattern ANYWHERE in the failing line, so
# every one of these cleared the stamp. A failed `ls` silently wiping verification
# is how a gate gets switched off, which is this project's own false-positive rule.
for c in 'cat test-hooks.sh' 'ls test_foo.py' 'grep -r "npm test" .' 'echo npm test' 'shellcheck test-runner.sh'; do
    d=$(new_repo "names$(echo "$c" | tr -cd '[:alnum:]')"); fire "$d" "$c"
    stamp_exists "$d" && ok "'$c' does not clear the stamp" \
                      || bad "'$c' does not clear the stamp" "stamp was cleared"
done

echo
echo "7. A CHAIN BEYOND A LEADING cd IS REFUSED, and that is a real limitation:"
# Reproduced during review: stamp_target_dir_from_command takes the FIRST textual
# `cd`, so acting on arbitrary chains clears the WRONG repository's stamp while the
# one that actually went red keeps its green one. Refusing chains costs one line;
# resolving them correctly needs a shell parser.
d=$(new_repo chainrefused); fire "$d" 'npm test; cd /elsewhere; false'
stamp_exists "$d" && ok "a semicolon chain does not clear (stated limitation)" \
                  || bad "a semicolon chain does not clear (stated limitation)" "cleared"
d=$(new_repo piperefused); fire "$d" 'npm test | tee out.log'
stamp_exists "$d" && ok "a pipe does not clear (stated limitation)" \
                  || bad "a pipe does not clear (stated limitation)" "cleared"

echo
echo "8. A LEADING cd CLEARS THE REPOSITORY THAT WAS TESTED, AND ONLY THAT ONE:"
# The previous version of this control used `cd /tmp && npm test` and asserted the
# TEMP repo's stamp vanished. /tmp is not a git repository, so the resolver fell
# back to CLAUDE_PROJECT_DIR and cleared the seeded stamp BY ACCIDENT — a control
# passing for a reason other than the behaviour it claimed. Two real repositories
# now, and the untargeted one must be untouched.
a=$(new_repo repoA); b=$(new_repo repoB)
fire "$a" "cd $b && npm test"
stamp_exists "$b" && bad "the tested repository's stamp is cleared" "repo B kept its stamp" \
                  || ok "the tested repository's stamp is cleared"
stamp_exists "$a" && ok "and the OTHER repository is left alone" \
                  || bad "and the OTHER repository is left alone" "repo A was cleared too"

echo
echo "9. RECORDING IS STRICTER THAN CLEARING:"
# Clearing costs one re-run. A flake record costs a declaration AND a commit
# trailer on the next pass. `cd /missing && npm test` fails because the directory
# is absent — no suite ran — so calling the next passing `npm test` flaky would tax
# an innocent commit.
a2=$(new_repo recA); b2=$(new_repo recB)
fire "$a2" "cd $b2 && npm test"
# THIS CONTROL CHANGED EXPECTATION ON 2026-09-06, deliberately. It used to assert
# that a cd-prefixed failure is NEVER recorded. A live session showed that rule
# made the ledger essentially unwritable, because `cd /repo && npm test` is the
# shape agents actually produce — the stamp cleared every time and nothing was
# ever recorded. The rule is now the narrower one that was always meant: record if
# the cd could have SUCCEEDED, which is checkable by whether the directory exists.
ledger_has "$b2" "npm test" \
    && ok "a cd into an EXISTING directory is recorded, in that directory" \
    || bad "a cd into an EXISTING directory is recorded, in that directory" \
           "$(cat "$b2/.claude/.failed-runs" 2>/dev/null || echo empty)"
ledger_has "$a2" "npm test" && bad "and not in the one it was launched from" "recorded in A" \
                            || ok "and not in the one it was launched from"
d=$(new_repo recbare); fire "$d" "npm test"
ledger_has "$d" "npm test" && ok "a bare failure IS recorded" \
                           || bad "a bare failure IS recorded" "nothing in the ledger"

echo
echo "10. A MISSING CLASSIFIER FAILS CLOSED — opposite to post-bash, on purpose:"
# post-bash declines to WRITE a stamp without the classifier, which is safe. If
# this hook declined to CLEAR, a classifier going missing after a green run would
# reopen INC-0025 in silence. So it clears and says why.
d=$(new_repo noclassifier)
ERR=$(printf '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$box/absent.sh" \
      bash "$SUT" 2>&1 >/dev/null ))
stamp_exists "$d" && bad "a missing classifier still clears the stamp" "stamp survived" \
                  || ok "a missing classifier still clears the stamp"
printf '%s' "$ERR" | grep -qi "classifier" \
    && ok "and says the classifier was missing" || bad "and says the classifier was missing" "$ERR"
ledger_has "$d" "npm test" && bad "but records no flake, having classified nothing" "recorded" \
                           || ok "but records no flake, having classified nothing"

echo
echo "11. AN UNREADABLE PAYLOAD ANNOUNCES ITSELF:"
# All three of these once exited quietly, so "the payload broke" and "no test
# failed" were indistinguishable — while a stamp a red suite should have cleared
# stayed put.
for bad_payload in '' 'not json at all' '{"tool_name":"Bash"}'; do
    d=$(new_repo "payload$RANDOM")
    ERR=$(printf '%s' "$bad_payload" | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" \
        STAMP_LIB="$HOOKS/stamp-path.sh" FLAKE_LIB="$HOOKS/flake-ledger.sh" \
        COMMANDS_LIB="$HOOKS/classify-test-commands.sh" bash "$SUT" 2>&1 >/dev/null ))
    [ -n "$ERR" ] && ok "payload ${bad_payload:-(empty)} is announced" \
                  || bad "payload ${bad_payload:-(empty)} is announced" "silent"
done

echo
echo "12. THE PAYLOAD FIELD NAMES THIS HOOK DEPENDS ON:"
# HONEST SCOPE, because the previous version of this section claimed more than it
# could deliver: it manufactured the same payload every time, so it could not
# possibly detect a real payload that disagreed — which was the one thing it was
# written for. It cannot be made to do that from fixtures alone.
#
# What it CAN assert is that the hook reads the documented names and no others, so
# a contract change surfaces as these controls failing rather than as silence.
d=$(new_repo fieldnames)
printf '{"tool_name":"Bash","tool_input":{"cmd":"npm test"}}' \
  | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" STAMP_LIB="$HOOKS/stamp-path.sh" \
      FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
      bash "$SUT" >/dev/null 2>&1 )
stamp_exists "$d" && ok "a payload using .tool_input.cmd is not silently acted on" \
                  || bad "a payload using .tool_input.cmd is not silently acted on" "cleared"
d=$(new_repo bothflags); fire "$d" "npm test" '{"is_interrupt":false,"is_timeout":false}'
stamp_exists "$d" && bad "explicit false for both flags still clears" "stamp survived" \
                  || ok "explicit false for both flags still clears"

echo
# A redirect can fail before the suite starts, so it clears but is not recorded.
d=$(new_repo redirin); fire "$d" "npm test < /definitely-missing-input"
stamp_exists "$d" && bad "a redirected failure still clears" "stamp survived" \
                  || ok "a redirected failure still clears"
ledger_has "$d" "npm test" && bad "but is NOT recorded as a flake" "recorded" \
                           || ok "but is NOT recorded as a flake"

# THE SHAPE AGENTS ACTUALLY PRODUCE. `cd /repo && npm test` is how a suite gets
# invoked in practice — every Bash call in the live session that found this had
# that shape. An earlier version excluded all of them from recording, which was
# correct in principle and left flake triage inert in fact: the stamp cleared every
# time and the ledger was never written once.
d=$(new_repo cdrecord); fire "$d" "cd $d && npm test"
stamp_exists "$d" && bad "a cd-prefixed failure clears" "stamp survived" \
                  || ok "a cd-prefixed failure clears"
ledger_has "$d" "npm test" \
    && ok "AND is recorded, because the directory exists so the cd succeeded" \
    || bad "AND is recorded, because the directory exists so the cd succeeded" \
           "ledger empty — flake triage is inert for the commonest command shape"

# The original objection still holds where it applies: if the directory is absent
# the cd failed, no suite ran, and a later identical pass must not read as flaky.
d=$(new_repo cdmissing); fire "$d" "cd /definitely/not/here && npm test"
ledger_has "$d" "npm test" && bad "a cd to a MISSING directory is not recorded" "recorded" \
                           || ok "a cd to a MISSING directory is not recorded"

echo
echo "13. THE DIRECTORY NEVER COMES FROM ARBITRARY COMMAND TEXT:"
# Both of these were live in the first fix and were found by a second review round.
# stamp_target_dir_from_command SEARCHES the line for a `cd`, which is safe only for
# the shapes post-bash accepts. Here the prefix is parsed strictly instead, and the
# resolver is never handed the raw command.
mkdir -p "$box/twoA/.claude" "$box/twoB/.claude"
( cd "$box/twoA" && git init -q ); ( cd "$box/twoB" && git init -q )
seed_two() {
    printf '%s|npm test|inferred|clean\n' "$(date +%s)" > "$box/twoA/.claude/.verified"
    printf '%s|npm test|inferred|clean\n' "$(date +%s)" > "$box/twoB/.claude/.verified"
}
fire_in_A() {
    AVK_CMD="$1" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["AVK_CMD"]}}))' \
      | ( cd "$box/twoA" && env CLAUDE_PROJECT_DIR="$box/twoA" STAMP_LIB="$HOOKS/stamp-path.sh" \
          FLAKE_LIB="$HOOKS/flake-ledger.sh" COMMANDS_LIB="$HOOKS/classify-test-commands.sh" \
          bash "$SUT" >/dev/null 2>&1 )
}

# A MASKED CHAIN. `cd A; cd B && npm test` — stripping `cd ... &&` with a `[^&]*`
# body swallows the `;` too, so CMD_CORE came out a clean `npm test` and the
# separator check never saw the chain. The resolver then picked A while the suite
# ran in B.
seed_two; fire_in_A "cd $box/twoA; cd $box/twoB && npm test"
{ [ -f "$box/twoA/.claude/.verified" ] && [ -f "$box/twoB/.claude/.verified" ]; } \
    && ok "a chain masked by the cd-prefix strip clears NOTHING" \
    || bad "a chain masked by the cd-prefix strip clears NOTHING" "a stamp was cleared"

# ARGUMENT TEXT. `npm test -- --grep "please cd /repo-B now"` resolved to /repo-B,
# so a failure in A would clear B and leave A verified — fail-open plus collateral
# damage from one grep pattern.
seed_two; fire_in_A "npm test -- --grep \"please cd $box/twoB now\""
[ -f "$box/twoB/.claude/.verified" ] \
    && ok "a directory named in an ARGUMENT does not steer the clear" \
    || bad "a directory named in an ARGUMENT does not steer the clear" "repo B was cleared"
[ -f "$box/twoA/.claude/.verified" ] \
    && bad "and the repository actually under test is the one cleared" "A kept its stamp" \
    || ok "and the repository actually under test is the one cleared"

# The legitimate prefix must still work, or the fix has traded one bug for another.
seed_two; fire_in_A "cd $box/twoB && npm test"
[ -f "$box/twoB/.claude/.verified" ] \
    && bad "an explicit 'cd B && npm test' clears B" "B kept its stamp" \
    || ok "an explicit 'cd B && npm test' clears B"
[ -f "$box/twoA/.claude/.verified" ] \
    && ok "and leaves A alone" || bad "and leaves A alone" "A was cleared"

echo
echo "13. IT CAN NEVER BLOCK, so it must never try:"
d=$(new_repo exitcode); fire "$d" "npm test"
[ "$RC" = 0 ] && ok "exit 0 on the acting path" || bad "exit 0 on the acting path" "rc=$RC"
d=$(new_repo exitcode2); fire "$d" "grep x y"
[ "$RC" = 0 ] && ok "exit 0 on the no-op path" || bad "exit 0 on the no-op path" "rc=$RC"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
