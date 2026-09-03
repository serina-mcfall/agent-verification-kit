#!/usr/bin/env bash
# PreToolUse hook on Edit/Write/MultiEdit/NotebookEdit: refuses to MODIFY an
# existing test file, or test configuration, without a declaration naming it.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS AND IS NOT, STATED FIRST BECAUSE THE DISTINCTION IS THE WHOLE POINT
#
# The declaration file is writable by the agent this hook constrains. So this is
# NOT an integrity control against an agent that has decided to weaken a test. It
# cannot be. Anything a hook checks in the working tree, the thing being hooked can
# also write.
#
# What it IS: the difference between weakening a test SILENTLY, as a side effect of
# chasing a green suite, and weakening it DELIBERATELY, in a named file, one path
# at a time, leaving a record. That is the failure the research actually documents —
# METR's 30.4% of reward-hacking runs, EvilGenie's deleted test files, Clipboard
# Health's agents adding retries to silence flakes. None of those are an adversary
# defeating a guard. They are an optimiser taking the cheapest route to green.
# Making the cheap route cost one explicit line is most of the defence.
#
# The layer with teeth is check-test-changes.sh, which reads the branch diff in CI
# where the agent does not get a vote. This hook is the fast, local half; that is
# the slow, authoritative half. Neither is sufficient. Claiming this one prevents
# test weakening would be the overclaim an adversarial review already caught once
# in this programme's history, and it is not repeated here.
#
# ---------------------------------------------------------------------------
# CREATING A TEST IS NEVER BLOCKED
#
# If the target file does not exist, this hook stands aside. Writing new tests is
# the behaviour we want; taxing it would train agents to avoid adding tests, which
# is worse than anything this guard prevents. Only modification of something that
# already exists needs a reason.
#
# STATED BLIND SPOT, not an oversight: `rm tests/x.py` followed by a fresh Write is
# a bypass, because deletion arrives as a Bash call and this hook watches Edit and
# Write. check-test-changes.sh catches it — a diff shows the file changed however
# it changed. Gating `rm` here as well was considered and rejected: it duplicates
# git-safety.sh's job, and a guard spread across two hooks is the twin-file drift
# this kit's own history warns about.
# ---------------------------------------------------------------------------

INPUT=$(cat)
# Claude Code delivers the hook payload on a SOCKET. `cat /dev/stdin` opens fd 0 by
# path, which a socket cannot do — it fails with ENXIO, and $(...) captures only
# stdout, leaving INPUT empty. That empty payload read as "nothing to check" and a
# sibling hook enforced nothing FOR MONTHS, silently. Plain `cat` reads the
# already-open descriptor. Verified 2026-08-03 in this kit's ancestor.
if [ -z "$INPUT" ]; then
    echo "test-guard: empty payload — this hook cannot see the tool call and is NOT enforcing." >&2
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    # VISIBLE NON-ENFORCEMENT, and deliberately not a block.
    #
    # Without jq there is no file path, so there is nothing to classify — the hook
    # cannot tell a test from a README. Refusing every Edit on that basis is the
    # lockout this kit's ancestor produced once already: a fail-closed check placed
    # where it could be reached by an unrelated call blocked every Bash, Edit, Write
    # and MCP call in two live sessions, with no way back in from inside the session.
    #
    # Fail-closed is right for the act being guarded. It is wrong for every act that
    # merely passes nearby.
    echo "test-guard: jq is not installed, so the tool payload cannot be parsed — this hook is NOT enforcing. Install jq to enable it." >&2
    exit 0
fi

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# THE TARGET KEY IS NOT THE SAME ACROSS TOOLS, and assuming it was left one of the
# four tools in this hook's own matcher completely unguarded.
#
# Found 2026-09-04 by an adversarial review of the code. `hooks.json` matches
# `Edit|Write|MultiEdit|NotebookEdit` and the allow-list below names all four, but
# this line read only `.tool_input.file_path`. NotebookEdit does not use that key —
# its parameter is `notebook_path`, confirmed against the harness's own tool schema
# rather than inferred. So every NotebookEdit call produced an empty TARGET, took
# the "cannot classify it, so this call is allowed" branch, and exited 0. Every
# time, for every notebook, whatever it contained.
#
# Worse than the miss was the message: it blamed a malformed payload, so a total,
# systematic gap in one whole tool read as ordinary occasional noise.
#
# Why the 32 controls could not catch it: all of them build payloads with
# `file_path`, because that is the key this line read. A suite written against the
# implementation tests the implementation's assumptions back to itself. Section 10
# now sends real NotebookEdit payloads, and was confirmed red before this changed.
#
# `file_path` is tried first because three of the four tools use it; the fallback
# costs nothing when it is present.
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

case "$TOOL" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

if [ -z "$TARGET" ]; then
    # Names BOTH keys, because "no file_path" was actively misleading for
    # NotebookEdit: the key was never absent, it was never the one being read.
    # A message that names the wrong cause sends the reader looking in the wrong
    # place, which is how a systematic gap survives as background noise.
    echo "test-guard: $TOOL carried neither .tool_input.file_path nor .tool_input.notebook_path — cannot classify it, so this call is allowed and the hook is NOT enforcing on it." >&2
    exit 0
fi

# CREATION IS FREE. See the header.
[ -e "$TARGET" ] || exit 0

# ---------------------------------------------------------------------------
# Resolve the repository, reusing stamp-path.sh rather than reimplementing it.
#
# `nofallback` is load-bearing for exactly the reason edit-tracker.sh records: this
# is a real filesystem path from the payload, not text parsed from a command, so
# the hook's cwd is not a better guess when it will not resolve — it is a DIFFERENT
# repository. Falling back would attribute one repo's edit to another's declaration
# file.
# ---------------------------------------------------------------------------
STAMP_LIB="${STAMP_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stamp-path.sh}"
PATTERNS_LIB="${PATTERNS_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/test-patterns.sh}"

if [ ! -r "$PATTERNS_LIB" ]; then
    # FAIL CLOSED, but only for a path that already looks like a test on its
    # basename alone. Without the classifier this hook has no opinion about
    # anything else, and must not acquire one.
    case "${TARGET##*/}" in
        test_*|test-*|*_test.*|*.test.*|*.spec.*|*_spec.*)
            echo "EDIT BLOCKED — test-guard cannot read its classifier at $PATTERNS_LIB." >&2
            echo "'$TARGET' looks like a test file by name, and guessing whether it is one" >&2
            echo "would be the fail-open this guard exists to close. Restore the file" >&2
            echo "(it lives beside this script), then retry." >&2
            exit 2 ;;
    esac
    echo "test-guard: classifier missing at $PATTERNS_LIB — this path is not test-shaped by name, so the call is allowed, but the hook is NOT enforcing." >&2
    exit 0
fi
# shellcheck source=/dev/null
. "$PATTERNS_LIB"

REPO=""
if [ -r "$STAMP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$STAMP_LIB"
    if declare -F stamp_repo_root >/dev/null; then
        REPO=$(stamp_repo_root "$(dirname "$TARGET")" nofallback 2>/dev/null)
    fi
fi
if [ -z "$REPO" ]; then
    REPO=$(git -C "$(dirname "$TARGET")" rev-parse --show-toplevel 2>/dev/null)
fi

REL=$(avk_relativise "$TARGET" "$REPO")
CLASS=$(avk_classify_path "$REL" "$REPO")

[ "$CLASS" = other ] && exit 0

# ---------------------------------------------------------------------------
# The declaration.
#
# One line per path, in <repo>/.claude/.test-change. The path must match EXACTLY:
# a blanket declaration is refused by construction, so weakening forty tests costs
# forty lines rather than one. That property is the only reason this file is worth
# having — a single `*` would make it a formality.
#
# TTL matches the verification stamp's 30 minutes, for one reason: consistency of
# expectation. Unlike the stamp, an edit does NOT clear it — clearing on edit would
# make it single-use per call and unusable for a multi-edit refactor of one file.
# ---------------------------------------------------------------------------
DECL_DIR="${REPO:-${CLAUDE_PROJECT_DIR:-.}}"
DECL="$DECL_DIR/.claude/.test-change"
[ -n "$REPO" ] || echo "test-guard: no git repository resolves from '$TARGET' — using $DECL for the declaration." >&2

DECL_LINE=""
if [ -f "$DECL" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$DECL" 2>/dev/null || echo 0) ))
    if [ "$AGE" -gt 1800 ]; then
        echo "test-guard: $DECL is $(( AGE / 60 ))m old (stale after 30m) — treating it as absent." >&2
    else
        # Exact match on the first whitespace-delimited field. `grep -F -x` on the
        # whole line would fail the moment a reason was appended, and matching the
        # path anywhere in the line would let a path inside someone's REASON text
        # authorise an edit it never named.
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|\#*) continue ;; esac
            field=${line%%[[:space:]]*}
            if [ "$field" = "$REL" ]; then DECL_LINE="$line"; break; fi
        done < "$DECL"
    fi
fi

if [ -n "$DECL_LINE" ]; then
    # SAY WHAT AUTHORISED IT, at the moment it is relied upon. Same reasoning as
    # verify-gate.sh reporting which suite earned a stamp: an authorisation nobody
    # sees is indistinguishable from no gate at all.
    reason=${DECL_LINE#"$REL"}
    reason=${reason#"${reason%%[![:space:]]*}"}
    if [ -n "$reason" ]; then
        echo "test-guard: $CLASS change to $REL is declared — \"$reason\". Allowed."
    else
        echo "test-guard: $CLASS change to $REL is declared, with no reason given. Allowed."
    fi
    exit 0
fi

case "$CLASS" in
    test)
        HEADLINE="EDIT BLOCKED — $REL is a test file and this change is not declared."
        WHY="A test is the signal that says whether the code works. Changing it while chasing a green suite is how a suite stops meaning anything."
        ;;
    test-config)
        HEADLINE="EDIT BLOCKED — $REL is test configuration and this change is not declared."
        WHY="Retries, timeouts and reporter settings can make a failing test pass without touching a single assertion. That is the documented flake response this guard exists to slow down: adding retries hides a real race rather than fixing it."
        ;;
esac

cat >&2 << EOF
$HEADLINE

$WHY

If the change is right, declare it — one line, naming this exact path and why:

  mkdir -p "$DECL_DIR/.claude"
  echo '$REL  <why this test must change>' >> "$DECL"

Then retry the edit. The declaration lasts 30 minutes and authorises THIS path
only; a blanket entry will not match.

Creating a NEW test is never blocked — this fires only on modifying one that
already exists. If you are fixing the code rather than the test, leave this file
alone and change the code instead.
EOF
exit 2
