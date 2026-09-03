#!/bin/bash
# Sourceable. THE one place that decides where a verification stamp lives, and
# which repository a command is aimed at.
#
# WHY THIS FILE EXISTS. verify-gate.sh, post-bash.sh and edit-tracker.sh each
# computed the stamp as "${CLAUDE_PROJECT_DIR:-.}/.claude/.verified". When the
# session root is a CONTAINER of repositories rather than a repository — the
# measured case is ~/Launchpad, which holds ten — that is ONE stamp shared by all
# of them, and it fails in both directions at once:
#
#   fail-open    `npm test` in nextjs-project unlocks a commit in buzz. Nothing
#                ever tested buzz. The gate prints "Verified 0m ago" and means
#                nothing by it.
#   fail-closed  a second concurrent session's Edit runs edit-tracker, which
#                deletes the shared stamp out from under the first session's
#                commit. Measured 2026-08-10 with two sessions active: a stamp
#                created and verified seconds earlier was gone by the next call.
#
# verify-gate.sh already resolved a correct REPO_ROOT for its roster check, with
# 55 lines of comments recording the bypasses that shaped the parser — and then
# used CLAUDE_PROJECT_DIR for the stamp anyway. The resolution was right there
# and the stamp check did not read it.
#
# THE THREE HOOKS MUST AGREE ON THIS PATH. If the writer stamps one file and the
# reader checks another, no commit is ever possible again — a worse outcome than
# the fail-open being fixed. That is why this lives in one file instead of three
# copies, and it is the failure verify-gate.sh's own comments name: "a fix applied
# to the file where the defect was reported, and not to its twin."

# A git global option's value may be quoted and may contain spaces. Kept
# character-identical to the VAL/GITOPT construct in verify-gate.sh and
# git-safety.sh — read verify-gate.sh's header for the ten measured bypasses that
# produced this shape. Prefixed to avoid colliding with a sourcing script's own.
STAMP_VAL='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)'
STAMP_GITOPT="([[:space:]]+(-C[[:space:]]+$STAMP_VAL|-c[[:space:]]+$STAMP_VAL|--[a-zA-Z-]+=$STAMP_VAL|--[a-zA-Z-]+|-P|-p))*"

# stamp_target_dir_from_command COMMAND [GIT_VERB]
#
# Emits the directory the command names, or nothing. Two forms are recognised,
# because they are the two ways an agent actually reaches another repository:
#
#   git -C /path/to/repo commit -m x     (only when GIT_VERB is given)
#   cd /path/to/repo && <anything>
#
# GIT_VERB IS REQUIRED FOR THE -C FORM AND DELIBERATELY HAS NO DEFAULT. The -C
# extraction works by first matching the `git <options> <verb>` span and reading
# -C out of that span alone, so that a value appearing later in the line — a
# commit message containing the text `-C /somewhere` is routine in this
# repository — cannot be picked up instead. A caller with no verb to bound the
# span (post-bash.sh sees test commands, not git verbs) gets the cd form only,
# which is the shape a test command actually uses. Guessing a verb for it would
# reintroduce the unbounded match this bounding exists to prevent.
stamp_target_dir_from_command() {
    local command="$1" verb="${2:-}" target="" gitspan=""

    if [ -n "$verb" ] && echo "$command" | grep -qE "git${STAMP_GITOPT}[[:space:]]+-C[[:space:]]"; then
        gitspan=$(echo "$command" | grep -oE "git${STAMP_GITOPT}[[:space:]]+$verb" | head -1)
        target=$(printf '%s' "$gitspan" \
          | sed -nE "s/.*[[:space:]]-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p")
    elif echo "$command" | grep -qE '(^|[[:space:]]|;|&&)cd[[:space:]]'; then
        # THE cd BRANCH NEEDED THE SAME BOUNDING AS THE -C BRANCH AND DID NOT
        # HAVE IT. Confirmed 2026-08-10:
        #
        #   cd /realtarget && git commit -m "please cd /decoy first"  ->  /decoy
        #
        # Two independent causes, both fixed here.
        #
        # 1. `sed`'s leading `.*` is GREEDY, so it matched the LAST `cd` in the
        #    string rather than the first. The `cd` that actually determines the
        #    working directory is the FIRST one at a command boundary; anything
        #    later is either a subsequent chdir or, as here, prose.
        #
        # 2. Nothing excluded the commit message. A message is DATA, not command
        #    text, and this repository's messages routinely contain paths and
        #    shell fragments — the -C branch's header already calls that case
        #    "routine in this repository", which is why THAT branch was bounded
        #    to the `git <options> <verb>` span. Its twin was left unbounded.
        #    One defect, one fix applied to one of the two places it lived: the
        #    exact failure this file's header warns about, inside one function.
        #
        # The message is cut off at the first -m/--message, then the FIRST cd in
        # what remains is taken. A `cd` that appears only inside a message is
        # therefore invisible, and a real `cd "/path with spaces"` still parses
        # because the quoted form survives the truncation ahead of it.
        local before_msg
        before_msg=$(printf '%s' "$command" | sed -E 's/[[:space:]]--?(m|message)([[:space:]=]).*//')
        target=$(printf '%s' "$before_msg" \
          | grep -oE "(^|[[:space:]]|;|&&|\|\|)cd[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:]&;|]+)" \
          | head -1 \
          | sed -E "s/.*cd[[:space:]]+//; s/^\"//; s/\"$//; s/^'//; s/'$//")
    fi

    # THE HOOK SEES THE COMMAND UNEXPANDED — the payload carries raw text and the
    # shell has not run, so `$HOME` arrives literally. Only the two forms that
    # actually appear are expanded; general shell expansion here would mean
    # evaluating arbitrary text to decide whether to permit a commit.
    case "$target" in "~"|"~/"*) target="$HOME${target#\~}" ;; esac
    target="${target//\$\{HOME\}/$HOME}"
    target="${target//\$HOME/$HOME}"
    printf '%s' "$target"
}

# stamp_repo_root [DIR_HINT] [fallback|nofallback]
#
# Emits the git toplevel for DIR_HINT, or nothing.
#
# THE HINT DIRECTORY NEED NOT EXIST YET, and assuming it did was a live bug.
# `git -C <missing-dir>` does not return empty — it fails outright with "cannot
# change to". edit-tracker.sh passes `dirname "$EDITED_FILE"`, and a Write
# creating `src/newdir/new.py` names a directory that does not exist at the
# moment the hook runs. So the hint failed, the cwd fallback below fired, and the
# hook cleared the stamp of WHATEVER REPOSITORY THE HOOK HAPPENED TO BE STANDING
# IN — reproduced 2026-08-10: an edit inside `alpha` cleared `beta`'s stamp and
# left `alpha`'s in place. That is precisely the cross-repository substitution
# this file was written to eliminate, arriving through a narrower door.
#
# Walking up to the nearest EXISTING ancestor fixes it for every caller: the
# nearest existing ancestor of a path inside a repository is still inside that
# repository.
#
# TWO CALLERS NEED OPPOSITE THINGS FROM AN UNRESOLVABLE HINT, which is why the
# fallback is now a parameter rather than a policy baked into one function.
#
#   fallback     (default, and what post-bash.sh and verify-gate.sh want)
#                Their hint comes from PARSING A COMMAND STRING, which may be a
#                variable this file does not expand, a typo, or a path the
#                command itself creates. Garbage in the hint must not throw away
#                a perfectly good repository under cwd. That is the original
#                justification and it still holds — for them.
#
#   nofallback   (what edit-tracker.sh wants)
#                Its hint is a REAL FILESYSTEM PATH out of the tool payload, not
#                parsed text. If that will not resolve, cwd is not a better
#                guess — it is a DIFFERENT REPOSITORY, and acting on it corrupts
#                a repository the user never touched. Resolving nothing is the
#                correct answer, and the caller decides what to do with it.
#
# An unrecognised mode takes the SAFER branch and says so. Defaulting a typo to
# the permissive option is how a guard gets quietly disabled.
stamp_repo_root() {
    local hint="${1:-}" mode="${2:-fallback}" root="" probe=""

    case "$mode" in
        fallback|nofallback) : ;;
        *) printf 'stamp_repo_root: unknown mode %s - using nofallback\n' "$mode" >&2
           mode=nofallback ;;
    esac

    if [ -n "$hint" ]; then
        probe="$hint"
        # Terminates: dirname strictly shortens until it reaches / or . , both
        # of which are tested for. A path of any depth converges.
        while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ] && [ ! -d "$probe" ]; do
            probe=$(dirname "$probe")
        done
        [ -d "$probe" ] && root=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null)
    fi

    if [ -z "$root" ] && [ "$mode" = fallback ]; then
        root=$(git rev-parse --show-toplevel 2>/dev/null)
    fi
    printf '%s' "$root"
}

# stamp_path_for [DIR_HINT]
#
# The stamp path: repo-scoped when a repository resolves, otherwise the old
# CLAUDE_PROJECT_DIR location.
#
# THE FALLBACK IS NOT A HOLE, and it is worth saying why rather than leaving a
# reader to wonder. It is reached only when nothing resolves as a git repository
# — and a `git commit` outside a repository fails on its own without any help
# from this gate. Keeping the old path for that case means a non-git project
# still gets the gate it had before, instead of silently losing it.
stamp_path_for() {
    local root
    root=$(stamp_repo_root "${1:-}" "${2:-fallback}")
    if [ -n "$root" ]; then
        printf '%s/.claude/.verified' "$root"
    else
        printf '%s/.claude/.verified' "${CLAUDE_PROJECT_DIR:-.}"
    fi
}
