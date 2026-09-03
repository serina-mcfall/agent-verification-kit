#!/bin/bash
# PostToolUse hook on Edit/Write: clears verification stamp and nudges after repeated edits

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
  echo "edit-tracker: empty payload — this hook cannot see the tool call and is not enforcing." >&2
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
EDITED_FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
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
        echo "edit-tracker: no file_path in payload — falling back to the session-root stamp." >&2
        VERIFIED=$(stamp_path_for)
    fi
else
    echo "edit-tracker: stamp resolver missing at $STAMP_LIB — clearing the old shared path." >&2
    VERIFIED="$PROJECT_DIR/.claude/.verified"
fi

mkdir -p "$PROJECT_DIR/.claude"

# Clear verification stamp — edits invalidate previous test runs
if [ -f "$VERIFIED" ]; then
    rm -f "$VERIFIED"
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
