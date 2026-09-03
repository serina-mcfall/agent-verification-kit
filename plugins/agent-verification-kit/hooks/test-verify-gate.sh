#!/usr/bin/env bash
# Controls for verify-gate.sh's STAMP decision: which repository's stamp it reads,
# and what it does when its resolver is missing.
#
# WHY THIS FILE EXISTS — two defects, one shipped by the fix for the other.
#
#   1. The stamp path came from CLAUDE_PROJECT_DIR. With a container session root
#      (~/Launchpad, ten repositories) every repo shared one stamp, so tests in one
#      unlocked commits in another. Control: "a stamp in another repo does not
#      unlock this one."
#
#   2. The fix's own fail-closed guard was placed ABOVE the git-commit trigger, so
#      a missing resolver blocked every Bash, Edit, Write and MCP call in two live
#      sessions — a lockout with no way to repair it from inside the session.
#      Control: "a missing resolver does not block a non-commit command."
#
# The second had no control, which is exactly why it shipped. A gate is two claims,
# never one: it must block what it should AND pass what it should. Testing only the
# blocking half is how a gate becomes a lockout.
#
# Two questions per control:
#   1. Could the check PASS if the thing it tests did not exist?
#   2. Could the value it asserts occur by accident?
#
# Question 1: control 0 asserts a bare `echo` is allowed, so a hook that blocked
# unconditionally fails immediately rather than satisfying every block control
# below. Question 2: exit 2 is asserted together with the stderr marker where the
# rule needs distinguishing, because the roster gate also exits 2.
#
# Usage:  test-verify-gate.sh
# Exit:   0 = every control behaved, 1 = at least one did not

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/verify-gate.sh"
lib="$here/stamp-path.sh"
[[ -r "$sut" ]] || { echo "FAIL  verify-gate.sh not found at $sut"; exit 1; }
[[ -r "$lib" ]] || { echo "FAIL  stamp-path.sh not found at $lib"; exit 1; }

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
for r in alpha beta; do
  mkdir -p "$box/$r/.claude"
  git -C "$box/$r" init -q
  git -C "$box/$r" commit -q --allow-empty -m init
done
A=$(cd "$box/alpha" && pwd -P)
B=$(cd "$box/beta"  && pwd -P)

ran=0; failed=0
ok()   { ran=$((ran+1)); printf '  ok      %s\n' "$1"; }
nope() { ran=$((ran+1)); failed=$((failed+1)); printf '  FAILED  %s\n' "$1"; }

# gate WANT_RC LABEL COMMAND [STAMP_LIB_OVERRIDE]
#   Runs the hook with a JSON payload and asserts its exit code.
#   CLAUDE_PROJECT_DIR is deliberately pointed at the CONTAINER ($box) in every
#   control — that is the configuration the defect lived in.
gate() {
  local want="$1" label="$2" cmd="$3" libover="${4:-}" got err
  err="$box/.stderr"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd" \
    | ( cd "$box" && env CLAUDE_PROJECT_DIR="$box" ${libover:+STAMP_LIB="$libover"} bash "$sut" >/dev/null 2>"$err" )
  got=$?
  if [[ "$got" == "$want" ]]; then ok "$label"
  else nope "$label — exit $got, wanted $want$( [[ -s $err ]] && printf ' | stderr: %s' "$(head -1 "$err")" )"; fi
}

echo "0. the suite is not vacuous — an unrelated command must pass:"
gate 0 "a bare echo is allowed" "echo hello"
gate 0 "git log --grep commit is allowed (not a commit)" "git log --grep commit"

echo
echo "1. repository scoping — the original fail-open:"
rm -f "$A/.claude/.verified" "$B/.claude/.verified" "$box/.claude/.verified" 2>/dev/null
mkdir -p "$box/.claude"
touch "$A/.claude/.verified"
gate 0 "a stamp in alpha unlocks a commit in alpha" "git -C $A commit -m x"
# THE CONTROL FOR THE DEFECT. Before the fix this returned 0: the container stamp
# was all the gate ever looked at, so alpha's tests unlocked beta.
gate 2 "a stamp in alpha does NOT unlock a commit in beta" "git -C $B commit -m x"
# And the container's own stamp must not stand in for a repository's.
touch "$box/.claude/.verified"
gate 2 "a stamp at the session root does NOT unlock a commit in beta" "git -C $B commit -m x"
rm -f "$box/.claude/.verified"

echo
echo "2. no stamp anywhere still blocks:"
rm -f "$A/.claude/.verified" "$B/.claude/.verified"
gate 2 "unstamped alpha is blocked" "git -C $A commit -m x"

echo
echo "3. a stale stamp still blocks (>30m):"
touch -d '2 hours ago' "$A/.claude/.verified"
gate 2 "a 2-hour-old stamp in alpha is blocked" "git -C $A commit -m x"
rm -f "$A/.claude/.verified"

echo
echo "4. missing resolver — the lockout regression:"
# THE CONTROL THAT WAS MISSING. A guard above the trigger made all four of these
# exit 2; only the last one should.
gate 0 "a bare echo is allowed when the resolver is missing" "echo hello" "$box/no-such-resolver.sh"
gate 0 "an ls is allowed when the resolver is missing" "ls -l /tmp" "$box/no-such-resolver.sh"
gate 0 "a non-commit git read is allowed when the resolver is missing" "git status --short" "$box/no-such-resolver.sh"
gate 2 "a commit is still refused when the resolver is missing" "git -C $A commit -m x" "$box/no-such-resolver.sh"

# ---------------------------------------------------------------------------
# THE cwd FALLBACK, which until now no control reached.
#
# A reviewer deleted verify-gate.sh's `REPO_ROOT` cwd fallback outright and all
# eleven controls stayed green. The reason: `gate()` always runs from `$box` (the
# container, not a repository) and EVERY control's command carries an explicit,
# resolvable `-C` target — so `TARGET_DIR` was always non-empty and the fallback
# branch was dead code as far as this suite was concerned.
#
# The fallback is not decoration. A plain `git commit`, typed from inside a
# repository with no `-C` at all, is the ordinary case — and it is the ONLY way
# REPO_ROOT gets resolved for it.
mkdir -p "$box/proj/.claude"
git -C "$box/proj" init -q

# gate_in CWD WANT LABEL COMMAND
#   Same as gate(), but runs from a directory of the caller's choosing so the
#   cwd-resolution path is actually exercised.
gate_in() {
  local cwd="$1" want="$2" label="$3" cmd="$4" got err="$box/.stderr"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd" \
    | ( cd "$cwd" && env CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>"$err" )
  got=$?
  if [ "$got" = "$want" ]; then ok "$label"
  else nope "$label — exit $got, wanted $want$( [ -s "$err" ] && printf ' | stderr: %s' "$(head -1 "$err")" )"; fi
}

# THE POSITIVE HALF. A stamped repository, a bare `git commit` from inside it,
# no -C anywhere. Only the cwd fallback can resolve this, so deleting the
# fallback turns this control red.
rm -f "$box/.claude/.verified"; : > "$box/proj/.claude/.verified"
gate_in "$box/proj" 0 "a bare git commit inside a stamped repository is allowed" \
  "git commit -m 'x'"

# THE NEGATIVE HALF, and the reason the control above is not vacuous. The same
# command in the same place with NO stamp must be refused. Without this, a hook
# that allowed everything would satisfy the control above.
rm -f "$box/proj/.claude/.verified" "$box/.claude/.verified"
gate_in "$box/proj" 2 "a bare git commit inside an UNstamped repository is refused" \
  "git commit -m 'x'"

# THE ONE THAT PINS THE DEFECT ITSELF. The container is stamped and the
# repository is not. The pre-fix code read the container's stamp and allowed the
# commit — one repository's test run unlocking another's. It must still be
# refused, which proves the resolution is per-repository and not merely present.
rm -f "$box/proj/.claude/.verified"; mkdir -p "$box/.claude"; : > "$box/.claude/.verified"
gate_in "$box/proj" 2 "a container stamp does not unlock an unstamped repository under it" \
  "git commit -m 'x'"
rm -f "$box/.claude/.verified"

# ---------------------------------------------------------------------------
# THE ROSTER CHECK'S cwd RESOLUTION — the branch line 192 actually governs.
#
# The three controls above turned out NOT to cover it, and finding that out is
# the whole reason they are written down here. `stamp_path_for` has its own cwd
# fallback inside stamp-path.sh, so the stamp resolves correctly even with line
# 192 deleted. REPO_ROOT's only unique consumer is the agent-roster check. A
# control that does not stage an `agents/*.md` file cannot see the difference.
#
# CHECK_MODELS is injectable, so this needs no real checker and no network — the
# stub's exit code stands in for a roster verdict.
mkdir -p "$box/proj/.claude/agents"
printf -- '---\nname: x\nmodel: claude-nonesuch\n---\nbody\n' > "$box/proj/.claude/agents/x.md"
git -C "$box/proj" -c user.email=t@t -c user.name=t add .claude/agents/x.md

roster() { # roster WANT LABEL STUB_EXIT
  local want="$1" label="$2" stub_rc="$3" got err="$box/.stderr"
  printf '#!/bin/sh\nexit %s\n' "$stub_rc" > "$box/stub.sh"; chmod +x "$box/stub.sh"
  : > "$box/proj/.claude/.verified"
  python3 -c 'import json; print(json.dumps({"tool_input":{"command":"git commit -m x"}}))' \
    | ( cd "$box/proj" && env CLAUDE_PROJECT_DIR="$box" CHECK_MODELS="$box/stub.sh" \
        bash "$sut" >/dev/null 2>"$err" )
  got=$?
  if [ "$got" = "$want" ]; then ok "$label"
  else nope "$label — exit $got, wanted $want$( [ -s "$err" ] && printf ' | stderr: %s' "$(head -1 "$err")" )"; fi
}

# A staged agent definition with a roster verdict of INVALID must block. Reaching
# this at all requires REPO_ROOT to have resolved from cwd, because the command
# carries no -C. Delete line 192 and REPO_ROOT is empty, the roster check is
# skipped entirely, and the commit sails through — turning this control red.
roster 2 "a staged agent file with an invalid roster blocks a bare commit" 1

# The positive half, without which the control above is satisfied by a hook that
# blocks everything: the same staged file with a VALID roster verdict is allowed.
roster 0 "a staged agent file with a valid roster allows the commit" 0

git -C "$box/proj" reset -q

# ---------------------------------------------------------------------------
# A SAME-NAMED agents/ DIRECTORY OUTSIDE .claude AND OUTSIDE ANY DECLARED
# PLUGIN SOURCE IS NOT A ROSTER — launchpad-26/buzz issue #703. A corpus
# taxonomy document with no `name:`/`model:` (forbidden by its own schema) sat
# at docs/corpus/capabilities/agents/acp.md and got the roster check's "does
# not belong in an agents directory" refusal meant for a genuinely broken
# agent file. The commit must be ALLOWED here — the roster check must not even
# run — because this agents/ is a content-taxonomy folder, not a load path
# Claude Code recognises.
mkdir -p "$box/proj/docs/corpus/capabilities/agents"
printf -- '---\nid: capabilities-agents-acp\ntype: capabilities\nstatus: draft\n---\nbody\n' \
  > "$box/proj/docs/corpus/capabilities/agents/acp.md"
git -C "$box/proj" -c user.email=t@t -c user.name=t add docs/corpus/capabilities/agents/acp.md
: > "$box/proj/.claude/.verified"
python3 -c 'import json; print(json.dumps({"tool_input":{"command":"git commit -m x"}}))' \
  | ( cd "$box/proj" && env CLAUDE_PROJECT_DIR="$box" CHECK_MODELS="$box/stub.sh" \
      bash "$sut" >/dev/null 2>"$box/.stderr" )
got=$?
if [ "$got" = 0 ]; then ok "a same-named agents/ dir outside .claude and any declared plugin source is not treated as a roster"
else nope "a same-named agents/ dir outside .claude and any declared plugin source is not treated as a roster — exit $got, wanted 0 | stderr: $(head -1 "$box/.stderr")"; fi

git -C "$box/proj" reset -q
rm -f "$box/proj/.claude/.verified" "$box/.claude/.verified"

echo
echo "the unlock names WHICH suite authorised it:"
#
# Issue #100 asks for two things — a stamp recording what was verified, and for
# this gate to REPORT which suite authorised the commit — and calls the second the
# more important half. The command has been written into field 2 since the
# provenance change and was read by nothing, so the unlock said "Verified 3m ago,
# exit code observed" and never named the suite. Closing #100 with that unlanded
# would repeat #22, which was closed with its own stated fix unlanded and is the
# reason #100 exists.
#
# gate() discards stdout, so this needs its own runner.
unlock_says() {   # unlock_says WANT_SUBSTRING LABEL STAMP_CONTENT
  local want="$1" label="$2" content="$3" out
  mkdir -p "$box/.claude"
  printf '%s' "$content" > "$box/.claude/.verified"
  out=$(python3 -c 'import json; print(json.dumps({"tool_input":{"command":"git commit -m x"}}))' \
        | ( cd "$box" && env CLAUDE_PROJECT_DIR="$box" bash "$sut" 2>/dev/null ))
  if printf '%s' "$out" | grep -qF "$want"; then ok "$label"
  else nope "$label — said: $(printf '%s' "$out" | head -1)"; fi
  rm -f "$box/.claude/.verified"
}

unlock_says "by: make test" "the unlock names the suite that earned it" \
  "$(date +%s)|make test|observed"
unlock_says "by: bash check-plan.sh docs/plan.md" "it names a path-invoked suite too" \
  "$(date +%s)|bash check-plan.sh docs/plan.md|inferred"
# A touched stamp is empty: there is no suite to name, and none must be invented.
unlock_says "Commit allowed" "a touched stamp still unlocks and names nothing" ""

echo
if [ "$failed" -eq 0 ]; then
  echo "$ran controls, 0 failing"
else
  echo "$ran controls, $failed FAILING"
fi
[ "$failed" -eq 0 ]
