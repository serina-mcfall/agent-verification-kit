#!/usr/bin/env bash
# Controls for post-bash.sh's verification stamp.
#
# THERE WERE NONE, AND THAT IS WHY THE BLOCKER SURVIVED TWO REVIEW ROUNDS.
# `test-hooks.sh` covers whether each hook can SEE its payload over a socket; it
# has never asserted what post-bash.sh DECIDES. So the stamp — the thing standing
# between a red test suite and a commit — was the least-tested part of the gate.
#
# Two questions per control, the pair this repository uses:
#   1. Could the check PASS if the thing it tests did not exist?
#   2. Could the value it asserts occur by accident?
#
# The MENTION cases answer the first: a hook that stamped on any command at all
# would satisfy every positive control here. The POSITIVE controls answer the
# inverse — a hook that never stamped would satisfy every negative one.
#
# Payloads are built with `python3 -c json.dumps`, never hand-written. A backslash
# in a JSON string is an escape, so a hand-written `\&\&` yields INVALID json, jq
# returns empty, the hook sees no command and does nothing — a vacuous pass that
# reads exactly like a real result. That mistake was made twice while finding these
# defects.
#
# Usage:  test-post-bash.sh
# Exit:   0 = every control behaved, 1 = at least one did not

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/post-bash.sh"
[[ -r "$sut" ]] || { echo "FAIL  post-bash.sh not found at $sut"; exit 1; }

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
mkdir -p "$box/.claude"
ran=0; failed=0
ok()   { ran=$((ran+1)); printf '  ok      %s\n' "$1"; }
nope() { ran=$((ran+1)); failed=$((failed+1)); printf '  FAILED  %s\n' "$1"; }

# stamped WANT LABEL COMMAND [EXIT_CODE]
#   WANT is STAMPED or none — the side effect is a file, not an exit code.
#
# THE `cd "$box"` IS LOAD-BEARING, added 2026-08-10. post-bash.sh now resolves the
# stamp to the REPOSITORY the tests ran in (see stamp-path.sh), preferring a repo
# under cwd and falling back to CLAUDE_PROJECT_DIR only when cwd is not in one.
# Without the cd, the hook ran with cwd inside serina-hooks itself, so every
# control's stamp landed in the real repository instead of the sandbox: 12 controls
# failed, and the ones that passed were writing into the working tree. The cd puts
# cwd in a non-repo temp dir, which is exactly the production shape being tested —
# a session root that is a CONTAINER of repositories rather than one repository.
stamped() {
  local want="$1" label="$2" cmd="$3" rc="${4:-0}" got
  rm -f "$box/.claude/.verified"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exitCode":int(sys.argv[2])}}))' \
    "$cmd" "$rc" | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
  got=none; [[ -f "$box/.claude/.verified" ]] && got=STAMPED
  if [[ "$got" == "$want" ]]; then ok "$label"
  else nope "$label — got $got, wanted $want"; fi
}

# --- 0. the suite is not vacuous: a real run does stamp -----------------------
stamped STAMPED "a bare passing suite stamps (guard against a vacuous suite)" "npm test" 0

# --- 1. A MENTION IS NOT A RUN ------------------------------------------------
# The pattern was matched anywhere in the command with no notion of position, so
# naming a runner unlocked the gate for thirty minutes. Searching a codebase for
# `pytest` is an ordinary read-only act.
stamped none "echo pytest does not stamp"                  "echo pytest" 0
stamped none "grep -r pytest . does not stamp"             "grep -r pytest ." 0
stamped none "a runner named in a comment does not stamp"  "cat notes.md # npm test" 0
stamped none "a runner named in prose does not stamp"      "echo remember to run pytest later" 0

# --- 2. THE EXIT CODE MUST DESCRIBE THE TEST ----------------------------------
# It belongs to the whole tool call. Anything that runs after the suite, or pipes
# it, reports its own status instead.
stamped none "suite piped into tail"                       "npm test | tail -3" 0
stamped none "suite followed by echo"                      "npm test && echo done" 0
stamped none "suite mid-chain"                             "npm test && npm run lint && true" 0
stamped none "suite backgrounded with &"                   "pytest &" 0
stamped none "suite backgrounded, then wait"               "pytest & wait" 0
stamped none "suite on one line, echo on the next"         "$(printf 'python3 -m unittest discover\necho done')" 0

# --- 3. POSITIVE CONTROLS -----------------------------------------------------
# Without these, a hook that refused everything would pass every case above.
stamped STAMPED "cd then suite, suite last"                "cd /tmp/x && npm test" 0
# NARROWED 2026-08-13, and this control was flipped rather than deleted so the
# cost is visible. `&&` is now refused outright: deciding which command owns the
# exit code needed a shell parser, and five review rounds found five fail-opens
# in the hand-written one. Two tool calls instead of one, and it fails CLOSED.
stamped none    "setup && suite no longer stamps (narrowed, fail-closed)" "npm ci && npm test" 0
stamped STAMPED "suite behind an env assignment"           "env CI=1 npm test" 0
stamped STAMPED "suite invoked by absolute path"           "/usr/bin/pytest" 0

# --- 4. FAILURE AND UNREADABILITY ---------------------------------------------
stamped none "a failing suite does not stamp"              "npm test" 1

# THIS CONTROL WAS DELIBERATELY INVERTED on 2026-08-12, and the reversal is the
# point of the change — so it is recorded here rather than quietly rewritten.
#
# It used to assert that a payload with no exit-code field must NOT stamp, because
# "an exit code the hook cannot read is not evidence that anything passed." That
# was right while an unreadable code was believed to be rare. It is not rare: the
# live harness sends NO exit code at all, on any call, so this control was making
# the hook inert in production while the suite stayed green.
#
# THE SUITE COULD NOT HAVE CAUGHT THAT. `stamped` injects an exitCode into every
# payload it builds, so every other control describes a shape the harness does not
# send. That is why the controls below are written longhand against the captured
# real shape.
#
# What makes absence readable as success: PostToolUse does not fire at all when a
# Bash command exits non-zero. A failing run never reaches this hook, so reaching
# it is itself the evidence.

# real_shape WANT LABEL [EXTRA_JSON]
#   Builds a tool_response with the keys the harness ACTUALLY sends — captured
#   2026-08-12 — and no exit code. EXTRA_JSON overlays fields onto it.
real_shape() {
  local want="$1" label="$2" extra="${3:-{\}}" got
  rm -f "$box/.claude/.verified"
  python3 -c '
import json, sys
resp = {"interrupted": False, "isImage": False, "noOutputExpected": False,
        "stderr": "", "stdout": "ok"}
resp.update(json.loads(sys.argv[1]))
print(json.dumps({"tool_input": {"command": "npm test"}, "tool_response": resp}))' "$extra" \
    | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
  got=none; [[ -f "$box/.claude/.verified" ]] && got=STAMPED
  if [[ "$got" == "$want" ]]; then ok "$label"
  else nope "$label — got $got, wanted $want"; fi
}

real_shape STAMPED "the REAL payload shape (no exit code) stamps — the hook ran, so the command passed"
real_shape none    "an INTERRUPTED call never stamps, exit code or not" '{"interrupted": true}'

# THE STAMP RECORDS HOW IT WAS EARNED. A review's Blocker was that reading absence
# as success is fail-OPEN if the premise underneath ever breaks: a red suite would
# then write a PASS stamp, which is worse than the pre-fix behaviour of always
# clearing. The provenance field does not close that — it makes it legible. These
# controls exist so the field cannot quietly stop being written, which would return
# the failure to being silent.
basis_of() {   # basis_of LABEL WANT [EXTRA_JSON]
  local label="$1" want="$2" extra="${3:-{\}}" got
  rm -f "$box/.claude/.verified"
  python3 -c '
import json, sys
resp = {"interrupted": False, "isImage": False, "noOutputExpected": False,
        "stderr": "", "stdout": "ok"}
resp.update(json.loads(sys.argv[1]))
print(json.dumps({"tool_input": {"command": "npm test"}, "tool_response": resp}))' "$extra" \
    | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
  got="$(cut -d'|' -f3 "$box/.claude/.verified" 2>/dev/null)"
  if [ "$got" = "$want" ]; then ok "$label"
  else nope "$label — basis '$got', wanted '$want'"; fi
}

basis_of "an absent exit code is recorded as INFERRED, not passed off as observed" inferred
basis_of "an explicit zero is recorded as OBSERVED"                                observed '{"exitCode": 0}'

# The fallback must not swallow a code that IS present. Both directions, so a fix
# that ignored the field entirely would fail here.
stamped none    "an explicit non-zero code still clears, fallback or not" "npm test" 1
stamped STAMPED "an explicit zero still stamps"                           "npm test" 0

# --- 5. UNRELATED COMMANDS ARE UNTOUCHED --------------------------------------
# A non-test command must neither stamp nor clear an existing stamp.
: > "$box/.claude/.verified"
python3 -c 'import json; print(json.dumps({"tool_input":{"command":"git status"},"tool_response":{"exitCode":0}}))' \
  | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
if [[ -f "$box/.claude/.verified" ]]; then
  ok "a non-test command leaves an existing stamp alone"
else
  nope "a non-test command destroyed a valid stamp"
fi

# --- 6. ASKING A RUNNER ABOUT ITSELF IS NOT RUNNING IT ------------------------
# The third defect of this family, and the one the earlier two made invisible.
# Sections 1 and 2 established that the runner must be NAMED IN COMMAND POSITION
# and that the EXIT CODE must belong to it. `--help` satisfies both: it is the
# runner, in command position, unpiped, final on the line — and it exits 0.
#
# Measured before the fix: EIGHT of eight interrogation flags stamped a green
# gate, across five different runners. The adjudication named only
# `python3 -m unittest --help`, which reads as a gap in the unittest alternative;
# it is not. Every runner in TEST_PATTERN has a help flag, so these controls are
# spread across runners deliberately — a fix scoped to one would close a single
# door in a corridor and satisfy a single-runner control set.
stamped none "python3 -m unittest --help does not stamp"  "python3 -m unittest --help" 0
stamped none "python3 -m unittest -h does not stamp"      "python3 -m unittest -h" 0
stamped none "pytest --help does not stamp"               "pytest --help" 0
stamped none "pytest --version does not stamp"            "pytest --version" 0
stamped none "pytest --collect-only does not stamp"       "pytest --collect-only" 0
stamped none "pytest --co -q does not stamp"              "pytest --co -q" 0
stamped none "npm test --help does not stamp"             "npm test --help" 0
stamped none "cargo test --help does not stamp"           "cargo test --help" 0
stamped none "go test -h does not stamp"                  "go test -h" 0
stamped none "a --dry-run does not stamp"                 "cargo test --dry-run" 0

# THE INVERSE, so this section cannot be satisfied by a hook that simply stopped
# stamping. A flag is not disqualifying because it is a flag — only because it
# asks the runner about itself. Without these, deleting the stamp code entirely
# would turn all ten controls above green.
stamped STAMPED "a suite with ordinary flags still stamps"   "pytest tests/ -q" 0
stamped STAMPED "unittest with -v still stamps"              "python3 -m unittest discover -s tests -v" 0
stamped STAMPED "a suite with a -k selector still stamps"    "pytest -k test_login" 0

# --- 7. NOT EVERY INTERROGATION FLAG WEARS TWO DASHES -------------------------
# The first NOT_A_RUN list assumed `--flag`, and Go spells every test flag with one
# dash. `go test -list .` matches the runner, misses the guard and stamps -- and Go's
# own docs say -list runs no tests, benchmarks, fuzz targets or examples. A whole
# runner's worth of hole, not one flag's. Found by a cross-vendor review of the guard.
stamped none "go test -list . does not stamp"        "go test -list ." 0
stamped none "go test -list Test does not stamp"     "go test -list Test" 0
# The inverse, so `-list` is not over-matching every single-dash Go flag.
stamped STAMPED "go test -run TestFoo still stamps"  "go test -run TestFoo" 0

# --- 8. AN INTERROGATION THAT FAILED MUST STILL CLEAR A STALE STAMP -----------
# ORDER, not pattern. Testing "is this a run?" BEFORE "did it succeed?" made the
# not-a-run branch swallow failures: `pytest --collect-only` exiting 4 is a collection
# error, the pristine hook cleared the stamp for it, and the guard as first written
# let a stale green stamp survive. A fail-open introduced by a fix whose whole purpose
# was closing one -- so these controls assert on a PRE-EXISTING stamp, which the
# `stamped` helper cannot do because it clears one first.
for pair in "pytest --collect-only|4" "pytest --help|1" "go test -list .|2"; do
  c="${pair%|*}"; rc="${pair#*|}"
  : > "$box/.claude/.verified"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exitCode":int(sys.argv[2])}}))' \
    "$c" "$rc" | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
  if [[ -f "$box/.claude/.verified" ]]; then
    nope "a FAILED '$c' (exit $rc) left a stale stamp in place"
  else
    ok "a failed '$c' (exit $rc) clears the stamp"
  fi
done

# And the positive half: a SUCCEEDING interrogation must leave a good stamp alone,
# which is the behaviour the branch exists for. Without this, clearing on every
# interrogation would satisfy all three controls above.
: > "$box/.claude/.verified"
python3 -c 'import json; print(json.dumps({"tool_input":{"command":"pytest --help"},"tool_response":{"exitCode":0}}))' \
  | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
if [[ -f "$box/.claude/.verified" ]]; then
  ok "a successful --help leaves an existing stamp alone"
else
  nope "a successful --help destroyed a valid stamp"
fi

# ---------------------------------------------------------------------------
# THE REPO-SCOPED BRANCH, which until now this suite never reached.
#
# Both reviewers of PR #67 found the same hole independently. `$box` is a plain
# mktemp directory and was never `git init`ed, so `stamp_repo_root` resolved
# NOTHING for every one of the controls above and every stamp went through the
# CLAUDE_PROJECT_DIR fallback — which equals `$box`, which is exactly what
# `stamped()` checks. The suite could not tell the fixed hook from the broken
# one. Proved by mutation: replacing post-bash.sh's entire resolution with the
# pre-fix `VERIFIED="$PROJECT_DIR/.claude/.verified"` left all 38 controls green.
#
# The container shape above is right and stays. What was missing is a REPOSITORY
# INSIDE the container, which is the case the whole change exists to serve.
mkdir -p "$box/inner/.claude"
git -C "$box/inner" init -q

# stamped_in WHERE LABEL COMMAND [EXIT_CODE]
#   WHERE is `inner` or `box` — WHICH stamp was written, not merely whether one
#   was. Asserting both is the point: a hook that stamps everything satisfies
#   "inner is stamped" while still being the bug.
stamped_in() {
  local where="$1" label="$2" cmd="$3" rc="${4:-0}"
  rm -f "$box/.claude/.verified" "$box/inner/.claude/.verified"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exitCode":int(sys.argv[2])}}))' \
    "$cmd" "$rc" | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
  local in_inner=no in_box=no
  [[ -f "$box/inner/.claude/.verified" ]] && in_inner=yes
  [[ -f "$box/.claude/.verified" ]] && in_box=yes
  if [[ "$where" == inner && "$in_inner" == yes && "$in_box" == no ]] \
  || [[ "$where" == box   && "$in_box"   == yes && "$in_inner" == no ]]; then
    ok "$label"
  else
    nope "$label — inner=$in_inner box=$in_box, wanted only $where"
  fi
}

# A test run inside the inner repository stamps THAT repository. Under the
# pre-fix code this stamped the container, unlocking commits in every sibling.
stamped_in inner "a test run inside a nested repository stamps that repository" \
  "cd $box/inner && npm test"

# And the converse, which is what makes the control above non-vacuous: a run in
# the container — not a repository — still uses the container stamp.
stamped_in box "a test run in the container itself still stamps the container" \
  "npm test"

# The failing case must stamp NEITHER. Without this, a hook that stamps the
# inner repo unconditionally would satisfy the first control.
rm -f "$box/.claude/.verified" "$box/inner/.claude/.verified"
python3 -c 'import json; print(json.dumps({"tool_input":{"command":"cd '"$box"'/inner && npm test"},"tool_response":{"exitCode":1}}))' \
  | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" >/dev/null 2>&1 )
if [[ ! -f "$box/inner/.claude/.verified" && ! -f "$box/.claude/.verified" ]]; then
  ok "a FAILING test run inside a nested repository stamps nothing at all"
else
  nope "a failing run stamped something — inner=$([[ -f "$box/inner/.claude/.verified" ]] && echo yes || echo no) box=$([[ -f "$box/.claude/.verified" ]] && echo yes || echo no)"
fi

# --- path-invoked suites ------------------------------------------------------
# WHY, measured 2026-08-13. TEST_PATTERN knew package managers and language
# runners and nothing else, so a repository whose verification is a SCRIPT ON A
# PATH could not earn a stamp at all. The gate's own message ENDED, until this
# branch rewrote it, "If this project truly has no tests or build, run: touch
# .claude/.verified" — and a project with
# a real suite it could not name was pushed down that escape hatch, which is the
# one route the gate exists to make unnecessary. It happened for real: a plan edit
# in launchpad-26/buzz verified by `check-plan.sh` had to be committed behind a
# touched stamp, because no pattern here matched.
#
# The rule is the BASENAME, not the path: `test-`/`check-` prefixed, or
# `-test`/`_test(s)` suffixed, with a script extension. Naming is the only signal
# available — there is no way to ask a script whether it verifies anything — so
# this trades a little precision for the escape hatch it removes.
#
# Every negative below is a shape that a looser rule would have stamped.

# Positive: the motivating case, and the shapes around it.
stamped STAMPED "a path-invoked checker stamps (bash check-plan.sh)" "bash check-plan.sh docs/plan.md" 0
stamped STAMPED "a local test script stamps (./test-hooks.sh)" "./test-hooks.sh" 0
stamped STAMPED "a nested path test script stamps" ".claude/hooks/global/test-post-bash.sh" 0
stamped STAMPED "an interpreted suite stamps (python3 test_thing.py)" "python3 test_thing.py" 0
stamped STAMPED "a suffix-named suite stamps (./units_test.sh)" "./units_test.sh" 0

# Negative: a mention, a read, a lint and an edit are not runs. Each of these
# would stamp under a rule that merely searched the line for the script name.
stamped none "naming a checker does not stamp (echo)" "echo bash check-plan.sh" 0
stamped none "reading a suite does not stamp (cat)" "cat test-hooks.sh" 0
stamped none "linting a suite does not stamp (shellcheck)" "shellcheck test-hooks.sh" 0
stamped none "grepping for a suite does not stamp" "grep -r test-hooks.sh ." 0
stamped none "an unrelated script does not stamp (./deploy.sh)" "./deploy.sh" 0

# Negative: the guards that already exist must still cover the new shape, or this
# alternative would be a hole beside a closed door.
stamped none "a path-invoked suite behind a pipe does not stamp" "bash check-plan.sh docs/plan.md | tail -3" 0
stamped none "a path-invoked suite asked for help does not stamp" "./test-hooks.sh --help" 0
stamped none "a path-invoked suite that is not last does not stamp" "./test-hooks.sh && echo done" 0
stamped none "a FAILING path-invoked suite does not stamp" "./test-hooks.sh" 1

# --- THE EXTENSION MUST END THE TOKEN ----------------------------------------
# The controls above shipped a fail-open and could not have caught it. `grep -E`
# searches rather than matches, so without a trailing boundary an extension
# matched as a PREFIX of a longer one: `node test-config.json` ran no suite,
# exited 0, and stamped a 30-minute commit unlock.
#
# Two reviewers found it independently and an adjudicator reproduced it end to
# end. The stronger measurement was the adjudicator's: DELETING THE EXTENSION
# CLAUSE ENTIRELY left all 60 controls green — so it was not merely the boundary
# that was unpinned, it was the whole clause. `./test-runner` below is the
# control for that, and it is the one that turns red if the clause is removed.
stamped none "a longer extension does not match a shorter one (.json vs .js)" "node test-config.json" 0
stamped none "an editor backup does not stamp (.sh~)"        "bash check-plan.sh~" 0
stamped none "a compiled artefact does not stamp (.pyc)"     "python3 test_thing.pyc" 0
stamped none "a stale backup does not stamp (.sh.bak)"       "bash test-plan.sh.bak" 0
stamped none "an extensionless name does not stamp"          "./test-runner" 0

# --- THE SUFFIX RULE, IN THE SHAPES IT ACTUALLY CLAIMS ------------------------
# `./units_test.sh` was the only suffix control, so narrowing `[-_]` to `_` or
# dropping the `s?` plural both passed the full suite.
stamped STAMPED "a hyphen-suffixed suite stamps"             "./integration-test.sh" 0
stamped STAMPED "a plural hyphen-suffixed suite stamps"      "./run-tests.sh" 0
stamped STAMPED "a plural underscore-suffixed suite stamps"  "./run_tests.sh" 0

# --- THE WRAPPER WORDS THAT WERE ADDED, ACTUALLY EXERCISED --------------------
# Seven of the nine interpreters added to RUN_LEAD led no control command, so
# dropping `node` — or all seven — passed the full suite.
stamped STAMPED "node leads a suite"                         "node test-thing.js" 0
stamped STAMPED "ruby leads a suite"                         "ruby test_thing.rb" 0
stamped STAMPED "sh leads a suite"                           "sh test-thing.sh" 0
stamped STAMPED "perl leads a suite"                         "perl test_thing.pl" 0

# --- THE PREFIX AND EXTENSION SPREAD ------------------------------------------
# `check_` appeared nowhere, and only two of nine extensions were exercised.
stamped STAMPED "the check_ underscore prefix stamps"        "python3 check_models.py" 0
stamped STAMPED "a .mjs suite stamps"                        "node test-esm.mjs" 0
stamped STAMPED "a .ts suite stamps"                         "deno test-types.ts" 0

# --- THE SHAPES review-final MEASURED AGAINST THE DRIVING ISSUE ---------------
# `*-check.sh` is named in the issue's own glob list and matched nothing; bare
# `./test.sh` and `./check.sh` are very common and matched nothing either. Both
# failed closed, so the branch would have closed the issue while leaving the
# issue's own example unrecognised.
stamped STAMPED "a -check.sh suite stamps (named by the issue)" "bash scripts/deploy-check.sh" 0
stamped STAMPED "a bare ./test.sh stamps"                       "./test.sh" 0
stamped STAMPED "a bare ./check.sh stamps"                      "./check.sh" 0
stamped STAMPED "a plural -checks.sh stamps"                    "./run-checks.sh" 0
stamped STAMPED "zsh has an extension as well as a wrapper"     "zsh test-thing.zsh" 0
# The widening must not reach a word that merely STARTS with test/check. Without
# these, dropping the optional separator group entirely would pass everything above.
stamped none    "checkout.sh is not a suite"                    "./checkout.sh" 0
stamped none    "tester.sh is not a suite"                      "./tester.sh" 0

# --- NAMING A SUITE IS NOT RUNNING ONE, AND MUST NOT SAY IT WAS ---------------
# SUITE_SCRIPT widened a match from a runner incantation to a FILENAME, and the
# "a test command ran" line was written when only the former could match. Ordinary
# file commands then began claiming a test had run — untrue, and unactionable,
# since there is no suite to re-run. main is silent for these.
#
# Asserted on the OUTPUT, because every control above asserts only the stamp file,
# and all 75 stayed green while this was live.
said_nothing() {   # said_nothing WANT LABEL COMMAND   (WANT: quiet | speaks)
  local want="$1" label="$2" cmd="$3" out got
  rm -f "$box/.claude/.verified"
  out=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exitCode":0}}))' "$cmd" \
    | ( cd "$box" && CLAUDE_PROJECT_DIR="$box" bash "$sut" 2>&1 ))
  got=quiet; printf '%s' "$out" | grep -q 'a test command ran' && got=speaks
  if [[ "$got" == "$want" ]]; then ok "$label"
  else nope "$label — got $got, wanted $want"; fi
}
said_nothing quiet  "git add of a suite file says nothing"   "git add test-hooks.sh"
said_nothing quiet  "cat of a suite file says nothing"       "cat check-plan.sh"
said_nothing quiet  "ls of a suite file says nothing"        "ls test_thing.py"
# The converse, or a hook that never spoke would satisfy the three above.
said_nothing speaks "a piped suite still explains itself"    "npm test | tail -3"
said_nothing speaks "a piped path-invoked suite explains itself" "./test-hooks.sh | tail -3"

# --- A QUOTED ARGUMENT IS NOT A COMMAND SEGMENT -------------------------------
# The segment split is a `sed` on `;`/`&`/`&&`/`||` with no notion of quoting, so
# a separator INSIDE a quoted string cut the line there and what followed became
# the "final segment". If that began with a suite filename, the stamp was written
# for a suite nobody ran — and this repository's commit messages name these files
# constantly. Found by review-final, which also named the contradiction: the
# previous commit stopped the MESSAGE claiming a run from a mention and left the
# STAMP, the half that unlocks commits, with no equivalent check.
stamped none "a commit message naming a suite after ; does not stamp" 'git commit -m "fix; ./test.sh now passes"' 0
stamped none "a commit message naming a suite after & does not stamp" 'git commit -m "wip & ./check.sh green"' 0
stamped none "an unbalanced single quote does not stamp"              "git commit -m 'fix; ./test.sh passes'" 0
# The converse. Without these, refusing every quote would satisfy the three above.
stamped STAMPED "a suite with a quoted argument still stamps"         'bash check-plan.sh "docs/my plan.md"' 0
stamped none    "a suite after a separator no longer stamps (narrowed)"  "npm ci && ./test.sh" 0

# --- THE PLURALS OF THE VERY NAMES THE ISSUE IS ABOUT -------------------------
# The suffix alternative gained (tests?|checks?) last commit; the prefix did not,
# so ./test.sh stamped and ./tests.sh did not — one letter from the shape that was
# fixed, and the same harm it was fixed for.
stamped STAMPED "a bare ./tests.sh stamps"        "./tests.sh" 0
stamped STAMPED "a bare ./checks.sh stamps"       "./checks.sh" 0
stamped STAMPED "a bare tests.py stamps"          "python3 tests.py" 0
# Still tight after the widening.
stamped none    "testing.sh is not a suite"       "./testing.sh" 0
stamped none    "checkers.sh is not a suite"      "./checkers.sh" 0

# --- QUOTE PARITY DEFEATED THE COUNTING GUARD ---------------------------------
# The previous round guarded the carve-out by counting quotes in the segment AFTER
# the split and requiring an even number. Any message containing an odd number of
# that quote character restores parity, and the `'\''` apostrophe dance — the
# ordinary way to put an apostrophe inside a single-quoted string — contributes
# exactly three. Found by review-final, measured, all three stamped.
#
# The `echo` case is the one that settles it: this file already pins that naming a
# suite is not running one, and the quoted route walked past that boundary.
GC="git commit"   # assembled, so this file's own text does not trip verify-gate
stamped none "an apostrophe in a quoted message does not restore parity" \
  "$GC -m 'wip; ./check-plan.sh isn'\''t green yet'" 0
stamped none "echo with an apostrophe does not stamp" \
  "echo 'run this; ./test.sh isn'\''t optional' > notes.md" 0
stamped none "an escaped double quote does not restore parity" \
  "$GC -m \"fix; ./test.sh 3\\\" run\"" 0
# The message must stay silent for these too — RAN_SOMEWHERE used its own splitter,
# so the false "a test command ran" line came back on exactly what was silenced.
said_nothing quiet "a quoted mention after ; says nothing" "$GC -m \"fix; ./test.sh now passes\""
said_nothing quiet "a quoted mention with an apostrophe says nothing" \
  "$GC -m 'wip; ./check-plan.sh isn'\''t green yet'"

# --- A QUOTED SCRIPT PATH IS STILL A SCRIPT -----------------------------------
# The trailing boundary admitted only whitespace or end-of-string, so quoting the
# script — the taught habit, and mandatory for a path with a space — matched
# nothing and said nothing, routing the user back to the bypass.
stamped STAMPED "a double-quoted script path stamps"  'bash "test-hooks.sh"' 0
stamped STAMPED "a single-quoted script path stamps"  "bash './check-plan.sh'" 0

# --- NO FLAG BETWEEN THE WRAPPER AND THE PROGRAM ------------------------------
# There was an allow-list here and it was wrong four rounds running, each round
# closing the instances a review named and leaving the class: -r/--require, then
# -e/-O, then -u (a value for `env` and `sudo`), and finally -X/-U/-Q/-b, which
# were never audited at all because both greps are `-i` — so the six spellings on
# the list were twelve at match time. The list being audited was not the list
# being matched.
#
# "Does this flag take a value" is PER-WRAPPER knowledge — `-u` is unbuffered for
# python3 and a username for sudo — so one list cannot serve them. The head of the
# decision is now closed the way the tail is: refuse rather than model.
#
# These three FLIPPED. They are the declared cost, and they fail closed.
stamped none "bash -x no longer stamps (flag class deleted)"    "bash -x test-hooks.sh" 0
stamped none "python3 -u no longer stamps (flag class deleted)" "python3 -u test_thing.py" 0
stamped none "node --test no longer stamps (flag class deleted)" "node --test test-foo.js" 0
# The two Blockers that ended the allow-list, pinned by the shapes that found them.
stamped none "env -u takes a value, so the next token is the program" "env -u PYTEST_ADDOPTS mypy ." 0
stamped none "sudo -u takes a username"                  "sudo -u pytest ls" 0
stamped none "an uppercase flag is not admitted either"  "python3 -X pytest server.py" 0
stamped none "sudo -U is not admitted either"            "sudo -U pytest -l" 0
# And the shape issue #100 opens with, which earned nothing until now.
stamped STAMPED "python3 -m pytest stamps"               "python3 -m pytest" 0
# The flag run must not become a way in for a non-wrapper command.
stamped none    "shellcheck -x is still not a run" "shellcheck -x test-hooks.sh" 0

# --- A NEWLINE INSIDE QUOTES IS NOT A COMMAND BOUNDARY ------------------------
# The scan kept those newlines inside the quoted run, correctly — and then
# `tail -1` re-split on them, throwing the answer away. So a quoted multi-line
# body whose LAST LINE named a suite stamped with nothing run, which is the house
# style of this repository's own PR bodies and commit trailers.
#
# Found by review-final. It is the fourth fail-open in this dozen lines; the first
# three were each closed by patching the splitter, and this one by removing the
# line-delimited round trip underneath it.
stamped none "a multi-line PR body naming a suite last does not stamp" \
  "$(printf 'gh pr create --body "## How to verify\n\nbash check-plan.sh docs/plan.md"')" 0
stamped none "a multi-line issue comment naming a suite does not stamp" \
  "$(printf "gh issue comment 100 --body 'ran:\n./test-hooks.sh'")" 0
stamped none "echo of a multi-line string naming a suite does not stamp" \
  "$(printf 'echo "remember:\n./test.sh is not optional" > notes.md')" 0
# The converse, or refusing every multi-line command would satisfy all three.
stamped none    "a multi-line command no longer stamps (narrowed)" \
  "$(printf 'npm ci\n./test.sh')" 0

# --- A BACKSLASH ESCAPE HIDES THE QUOTE AFTER IT ------------------------------
# An odd escaped quote flipped the scanner's state and hid a real `;`, so the
# whole line became one segment led by a suite while `echo` owned the exit code.
stamped none "an escaped double quote does not hide a separator" \
  './test.sh --msg "3\" wide"; echo done' 0
stamped none "an escaped single quote does not hide a separator" \
  "./test.sh foo\\'bar; echo done" 0

# --- A DELIBERATE NARROWING, PINNED SO IT READS AS INTENDED -------------------
# `false || npm test` stamped before the quote-aware split and does not now: `|`
# is not a separator here, so the whole line reaches the pipe check and is
# refused. Fail-closed, costing one re-run. Recorded as a control because an
# uncontrolled behaviour change reads as an accident to the next maintainer.
stamped none "a suite behind || does not stamp (deliberate, fail-closed)" \
  "false || npm test" 0

# --- THE NARROWING ITSELF -----------------------------------------------------
# Five review rounds found five fail-opens in one dozen lines: quote parity, a
# newline round trip, backslash escapes, ANSI-C $'...' quoting, and a separator
# inside $( ). Heredocs and a quote-blind pipe check were queued behind the fifth.
# Each fix was correct; each was followed by another hole, because deciding which
# command owns the exit code from a string means writing a shell parser, and a
# hand-written one is never finished.
#
# So the question is refused rather than answered again. Any metacharacter that
# could reassign the exit code means no stamp — and the refusal is on RAW
# PRESENCE, so quoting cannot hide one. That is what makes this closed rather
# than open-ended: there is no model of the shell left to have a gap in.
#
# THE FIVE SHAPES THAT DEFEATED THE PARSER, all refused now by the one rule.
stamped none "ANSI-C quoting cannot hide a separator"  "echo \$'don\\'t; ./test.sh'" 0
stamped none "a heredoc naming a suite does not stamp" \
  "$(printf 'cat > notes.md <<EOF\nto verify:\n./test.sh\nEOF')" 0
stamped none "a separator inside \$( ) does not stamp" "echo \$(cat f; ./test.sh )" 0
stamped none "a quoted separator does not stamp"       "echo 'fix; ./test.sh'" 0
stamped none "a backtick substitution does not stamp"  "echo \`./test.sh\`" 0

# WHAT SURVIVES, or this would be a rule that refuses everything. Quotes are
# fine — only the metacharacters are refused, so an argument containing a space
# still works. Redirects are fine too: they leave the exit status untouched.
stamped STAMPED "a quoted argument still stamps"       'bash check-plan.sh "docs/my plan.md"' 0
stamped STAMPED "a redirect still stamps"              "make test > out.log" 0
stamped STAMPED "cd into a repo then the suite stamps" "cd /tmp/x && ./test-hooks.sh" 0
# The cd exemption must not become a door: anything AFTER the suite is still
# refused, even when a cd leads.
stamped none    "cd then suite then more does not stamp" "cd /tmp/x && npm test && echo done" 0

# --- WHICH TOKEN IS THE PROGRAM ----------------------------------------------
# The metacharacter refusal governs the TAIL of the decision — which command owns
# the exit code. It says nothing about the HEAD: which token counts as the
# program. RUN_LEAD was widened twice (interpreters as wrapper words, then a flag
# class) and neither widening was re-checked, so the interpreters' own
# do-not-run-it flags led a "run". All of these are `none` on main.
stamped none "command -v is a lookup, not a run"      "command -v pytest" 0
# ...but `command` stays a WRAPPER, because `command pytest` genuinely runs
# pytest. Dropping it from the wrapper list was tried first and over-refused a
# real run; it is the allow-list that must do this work, not the wrapper list.
stamped STAMPED "command <suite> is still a run"      "command pytest" 0
# The flag may also follow the program, where the allow-list cannot see it, so
# NOT_A_RUN carries the two unambiguous no-op spellings as well.
stamped none "a trailing --check does not stamp"      "node test-thing.js --check" 0
stamped none "bash -n syntax-checks, it does not run" "bash -n test-hooks.sh" 0
stamped none "sh -n does not run"                     "sh -n check-plan.sh" 0
stamped none "ruby -c does not run"                   "ruby -c test_x.rb" 0
stamped none "perl -c does not run"                   "perl -c test_x.pl" 0
stamped none "node --check does not run"              "node --check test-thing.js" 0
# A FLAG MAY TAKE A VALUE, and the value is not the program.
stamped none "node -r preload does not stamp"         "node -r test-setup.js server.js" 0
stamped none "node --require preload does not stamp"  "node --require test-helper.js app.js" 0
# THE CLASS, not just the two instances above. `-e` and `-O` were admitted by the
# first allow-list and take a value for wrappers already on the list — `node -e`,
# `ruby -e` and `perl -e` take code, `bash -O` takes a shopt name. The realistic
# form exits 0 and runs no suite, so it stamped an unearned unlock.
stamped none "node -e code does not stamp"            "node -e \"require('./test-setup.js')\"" 0
stamped none "node -e naming a suite does not stamp"  "node -e test-setup.js" 0
stamped none "ruby -e does not stamp"                 "ruby -e test_x.rb" 0
stamped none "perl -e does not stamp"                 "perl -e test_x.pl" 0
stamped none "bash -O takes a shopt name, not a suite" "bash -O test-hooks.sh" 0
# `-n` is deliberately absent from NOT_A_RUN: this is xdist parallelism, a real
# run. Refusing it would be a false positive on ordinary usage.
stamped STAMPED "pytest -n 4 is a run, not an interrogation" "pytest -n 4" 0

# --- THE MESSAGE, ON MULTI-LINE INPUT ----------------------------------------
# c5375de's message claimed heredocs and multi-line bodies were silent. They were
# not: `grep` anchors `^` per line, so any line beginning with a suite read as a
# command that began with a run, and the flatten step that had prevented it was
# deleted with the splitter. Asserted here so the claim cannot go stale again.
said_nothing quiet  "a heredoc naming a suite says nothing" \
  "$(printf 'cat > docs/x.md <<EOF\n./test-hooks.sh runs them\nEOF')"
said_nothing quiet  "a multi-line PR body says nothing" \
  "$(printf 'gh pr create --body "verify:\nbash check-plan.sh docs/plan.md"')"
said_nothing speaks "a piped suite still explains itself"  "npm test | tail -3"

printf '\n%d controls, %d failing\n' "$ran" "$failed"
[[ "$failed" -eq 0 ]]
