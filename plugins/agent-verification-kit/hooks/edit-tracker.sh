#!/bin/bash
# PostToolUse hook on Edit/Write: clears verification stamp and nudges after repeated edits

# announce() puts a message on the ONE channel NOTE-0032 observed reaching a
# human. Sourced defensively: if the library is missing this hook keeps working
# and falls back to the old stderr behaviour, because a verification hook that
# breaks over a missing MESSAGE FORMATTER would be a worse defect than the
# silence being fixed.
ANNOUNCE_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/announce.sh"
if [ -r "$ANNOUNCE_LIB" ]; then . "$ANNOUNCE_LIB"; else announce() { printf '%s\n' "$*" >&2; }; fi

INPUT=$(cat)
# Claude Code delivers the hook payload on a SOCKET. `cat /dev/stdin` opens fd 0
# BY PATH, and a socket cannot be opened by path — it fails with ENXIO ("No such
# device or address"), writes to stderr, and $(...) captures only stdout. The
# result was an empty INPUT, which this script's own logic read as "not a git
# command" and allowed. Verified 2026-08-03: /proc/self/fd/0 -> socket:[...].
#
# Plain `cat` reads the already-open descriptor and works on a socket.
#
# The warning below exists because the original failure was SILENT for months.
# An empty payload is never normal; say so on stderr, which is visible without
# blocking the tool.
if [ -z "$INPUT" ]; then
  announce "edit-tracker: empty payload — this hook cannot see the tool call and is not enforcing."
fi
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
COUNTER="$PROJECT_DIR/.claude/.edit-count"

# CLEAR THE EDITED REPOSITORY'S STAMP, NOT EVERY REPOSITORY'S.
#
# This used "${CLAUDE_PROJECT_DIR:-.}/.claude/.verified", which with a container
# session root (~/Launchpad, ten repositories) is one stamp for all of them. So an
# edit to any file anywhere cleared the verification of every repo at once — and
# with two sessions live, one session's edit deleted the other's stamp mid-commit.
# Observed 2026-08-10.
#
# The file path is in the payload, so this hook can be exact where post-bash has to
# infer from command text. `dirname` of the edited file, then its git toplevel.
#
# OVER-CLEARING WOULD BE THE SAFE DIRECTION AND IS STILL NOT FREE: a cleared stamp
# only costs a re-run, but a stamp cleared by unrelated work in another repository
# trains you to reach for `touch .claude/.verified`, which is the habit that
# actually defeats the gate. Precision here is about keeping the override rare.
# NOTEBOOKEDIT USES A DIFFERENT KEY, and reading only file_path sent every notebook
# edit down the cwd-fallback path below. Fixed 2026-09-04, on adoption into this
# plugin, from Serina's review.
#
# This hook is wired for NotebookEdit, whose parameter is `notebook_path`, not
# `file_path` — confirmed against the harness's own tool schema. With the key
# missing, EDITED_FILE was empty and the fallback resolved the stamp from the
# hook's CWD.
#
# THE SYMPTOM IS NOT "THE STAMP SURVIVES", which is what a same-repository test
# reports and why this went unnoticed. It is that the WRONG repository's stamp is
# cleared. Measured, cwd in alpha and a test notebook edited in beta:
#
#   alpha (never touched)   CLEARED    an unnecessary re-run
#   beta  (was edited)      PRESENT    the edit was not invalidated
#
# Fail-open and fail-closed at once — which is the same pair this file's header
# already records from 2026-08-10, arriving through a different door. The header
# says "the file path is in the payload, so this hook can be exact"; that was true
# only for the three tools that put it under file_path.
#
# Covered by test-edit-tracker-notebook.sh, confirmed red before this line changed.
#
# ---------------------------------------------------------------------------
# AND WHY IT IS NOT `a // b // empty` EITHER — kit#2, 2026-09-05.
#
# Reading the right key is not enough if the wrong one can still shadow it.
# jq's `//` falls through on null and false ONLY; an empty string is TRUTHY, so
# {"file_path":"","notebook_path":"beta/x.ipynb"} yields "" and never reaches
# the notebook path. EDITED_FILE is empty, the else branch below calls
# stamp_path_for WITH the cwd fallback, and the WRONG repository is cleared —
# the same alpha-CLEARED / beta-PRESENT pair this file already documents twice,
# arriving through a third door.
#
# The select keeps jq's own fall-through set (null, false) and adds the empty
# string. `. != false` is load-bearing, not tidiness: the first version of this
# fix, written in serina-learning, omitted it and REGRESSED a case the old chain
# got right — `false` survives a `!= null and != ""` select, lands in slot 0,
# and `.[0] // empty` re-applies jq's truthiness and collapses to empty. That
# was caught by an adversarial review, and the regression guard for it is in
# test-edit-tracker-notebook.sh, green both before and after this change.
#
# THE TWIN, AND WHY IT WAS LATE. serina-learning PR #143 fixed this on
# 2026-09-04. This plugin's copy was NOT updated in that change, so the public,
# installable copy carried the defect for a further day while two other copies
# of the same file did not. guard-test-changes.sh carried the identical
# expression and is fixed in the same commit as this one. The other seven `//`
# sites in this hook layer were checked and are safe — their falsy values are
# either unreachable or benign, and `exitCode: 0` is truthy in jq, so the
# post-bash chain is correct as written.
# ---------------------------------------------------------------------------
EDITED_FILE=$(echo "$INPUT" | jq -r '[.tool_input.file_path, .tool_input.notebook_path] | map(select(. != null and . != false and . != "")) | .[0] // empty')
STAMP_LIB="${STAMP_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stamp-path.sh}"
if [ -r "$STAMP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$STAMP_LIB"
    if [ -n "$EDITED_FILE" ]; then
        # NOFALLBACK IS LOAD-BEARING HERE. This hint is a real filesystem path
        # from the tool payload, not text parsed out of a command, so cwd is not
        # a better guess when it will not resolve — it is a DIFFERENT REPOSITORY.
        # With the fallback, a Write creating `alpha/newdir/new.py` (a directory
        # that does not exist when this hook runs) resolved to the hook's cwd and
        # deleted `beta`'s stamp while leaving `alpha`'s intact. Reproduced
        # 2026-08-10; see stamp_repo_root's header.
        VERIFIED=$(stamp_path_for "$(dirname "$EDITED_FILE")" nofallback)
    else
        # No path in the payload is not normal — say so rather than silently
        # clearing the wrong stamp, following this file's empty-payload precedent.
        announce "edit-tracker: no file_path in payload — falling back to the session-root stamp."
        VERIFIED=$(stamp_path_for)
    fi
else
    announce "edit-tracker: stamp resolver missing at $STAMP_LIB — clearing the old shared path."
    VERIFIED="$PROJECT_DIR/.claude/.verified"
fi

mkdir -p "$PROJECT_DIR/.claude"

# Clear verification stamp — edits invalidate previous test runs
if [ -f "$VERIFIED" ]; then
    rm -f "$VERIFIED"
fi

# --- Clear the flake ledger too — Stage 3 ------------------------------------
#
# WHY THIS IS LOAD-BEARING AND NOT HOUSEKEEPING.
#
# The flake detector calls a pass "flaky" when the SAME command failed recently
# and nothing has changed since. Write a failing test -> implement -> pass is
# also fail-then-pass, so without this line every legitimate red-green cycle
# would be reported as a flake. This kit's own false-positive rule says a
# mechanism that cries wolf is `fix` or `drop` however correct it is in
# principle, and that is what it would become.
#
# Measured end to end on 2026-09-05 BEFORE this landed: with the ledger
# uncleared, fail -> edit -> pass produced a stamp reading `flaky` — a false
# positive on the most ordinary workflow there is.
#
# SAME SCOPE AS THE STAMP, deliberately. It is the ledger of the EDITED file's
# repository, derived from the same $VERIFIED this hook just cleared rather than
# resolved a second time — two resolutions of one question are two things that
# can disagree, and getting it wrong here is a silent false negative in the
# repository that was edited and a silent false positive in the one that was not.
#
# The bypass this creates is real and is stated rather than hidden: touching any
# file forgets every recorded failure. It is not cheaper than compliance, though.
# An edit lands in the diff where a reviewer sees it; the declaration is one line.
FLAKE_LIB="${FLAKE_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/flake-ledger.sh}"
if [ -r "$FLAKE_LIB" ]; then
    # shellcheck source=/dev/null
    . "$FLAKE_LIB" && flake_clear "${VERIFIED%/.claude/.verified}"
else
    # Soft, like everything else in this hook: it runs after the tool and cannot
    # block. A stale ledger causes a false FLAKY later, which the gate reports
    # and a human can clear — worse than correct, better than silent.
    announce "edit-tracker: flake ledger missing at $FLAKE_LIB — a recorded failure will not be forgotten by this edit, so a later pass may report flaky. NOT enforcing correctly."
fi

# Increment edit counter
COUNT=0
if [ -f "$COUNTER" ]; then
    COUNT=$(cat "$COUNTER" 2>/dev/null || echo 0)
fi
COUNT=$(( COUNT + 1 ))
echo "$COUNT" > "$COUNTER"

# Nudge every 5 edits
if [ $(( COUNT % 5 )) -eq 0 ]; then
    echo "REMINDER: ${COUNT} file changes since last verification. Run tests before committing. The commit gate WILL block you."
fi

exit 0
