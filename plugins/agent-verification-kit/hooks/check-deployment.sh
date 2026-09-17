#!/usr/bin/env bash
# Compares the hooks DEPLOYED on this machine against the ones this kit SHIPS.
#
#   bash check-deployment.sh [DEPLOY_DIR] [REF]
#     DEPLOY_DIR  default $HOME/.claude/hooks   (or $AVK_DEPLOY_DIR)
#     REF         default main                  (or $AVK_SOURCE_REF)
#
# ---------------------------------------------------------------------------
# WHY. INC-0033 merged to main on 2026-09-07 and governed nothing on the author's
# machine until 2026-09-17. Ten days. Every session in that window — several of them
# concurrent — was gated by a verify-gate.sh from a different repository, which was
# not stale so much as current in the wrong lineage.
#
# It was found by accident, as INC-0034 and INC-0031 and INC-0014 were before it.
# This kit gates a commit on a test stamp, a test edit on a declaration and a flaky
# pass on a commit trailer, and had nothing whatsoever comparing the copy that
# ENFORCES against the copy it SHIPS. Same gap check-record.sh exists to close, one
# layer down: the thing everything else is read out of had no check on it.
#
# ---------------------------------------------------------------------------
# WHAT IT CHECKS, AND WHY EACH ONE IS HERE
#
#   drift     a deployed file whose bytes differ from the ref. The ten-day failure.
#
#   absence   a deployed hook that SOURCES a sibling which was never deployed. This
#             is the one that nearly got missed on 2026-09-17: announce.sh was
#             absent from the deploy directory entirely, and every hook in this kit
#             resolves siblings with dirname/readlink and then FALLS BACK rather
#             than failing. A missing library does not error. It degrades — into
#             the channel NOTE-0032 measured as reaching nobody. The gate looks
#             fixed and announces into the void.
#
# ---------------------------------------------------------------------------
# THE SOURCE OF TRUTH IS A COMMITTED REF, NOT THE WORKING TREE.
#
# Comparing against the working tree would turn every in-progress hook edit red,
# and a control that is red during ordinary work is a control that gets switched
# off — INC-0033's lesson, where the documented workflow WAS the bypass. Against a
# ref, an uncommitted edit is invisible and a MERGED-BUT-UNDEPLOYED fix is loud,
# which is exactly the failure being guarded.
#
# ---------------------------------------------------------------------------
# THREE EXIT CODES, NEVER TWO
#
#   0  deployed copies match, or this machine deploys none of them
#   1  drift or a missing sibling — every problem is listed, not just the first
#   3  could not check
#
# A machine that deploys nothing is an adopter using the plugin, and that is fine.
# A ref that ships NO hooks is a wrong prefix or a wrong ref, and reporting that as
# clean would be the INC-0006 mistake: could-not-check quietly becoming it-is-fine.
# The mutation trial made the same point from the other side — a harness that fails
# to mutate reports a perfect score. A check that checks nothing must never pass.
# ---------------------------------------------------------------------------

set -u

die() { printf 'check-deployment: CANNOT DETERMINE — %s\n' "$1" >&2; exit 3; }

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SELF_DIR=$(dirname "$SELF")

DEPLOY_DIR="${1:-${AVK_DEPLOY_DIR:-$HOME/.claude/hooks}}"
REF="${2:-${AVK_SOURCE_REF:-main}}"

ROOT=$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || die "$SELF_DIR is not inside a git repository, so there is no shipped copy to compare against."
[ -n "$ROOT" ] || die "could not resolve the repository root from $SELF_DIR."

# The prefix this script itself lives at. Derived rather than hardcoded: the check
# is "are the deployed copies the ones the kit that ships ME ships", and a constant
# would quietly stop meaning that if the layout moved.
PREFIX=${SELF_DIR#"$ROOT"/}
[ "$PREFIX" != "$SELF_DIR" ] || PREFIX=""

LIST_PATH=${PREFIX:+$PREFIX/}
SHIPPED=$(git -C "$ROOT" ls-tree --name-only "$REF" "$LIST_PATH" 2>/dev/null) \
    || die "ref '$REF' does not resolve in $ROOT."

# Deployable artefacts only. A control suite is not deployed and its absence from a
# deploy directory is never a finding; controls.list and hooks.json are not hooks.
SHIPPED=$(printf '%s\n' "$SHIPPED" \
    | while IFS= read -r p; do [ -n "$p" ] && basename "$p"; done \
    | grep -E '\.sh$' | grep -vE '^test-' | sort -u)

[ -n "$SHIPPED" ] \
    || die "ref '$REF' ships no deployable hooks at '${PREFIX:-the repository root}'. That is a wrong ref or a moved layout, and reporting it as clean would be a check of nothing."

if [ ! -d "$DEPLOY_DIR" ]; then
    printf 'check-deployment: no deployment at %s — nothing to check.\n' "$DEPLOY_DIR"
    exit 0
fi

# Somewhere to land the shipped bytes so the read that produces them can be tested
# for success. Created after the cheap refusals above, so a wrong ref or a missing
# deployment costs nothing.
SCRATCH=$(mktemp -d) || die "could not create a temporary directory to read the shipped copies into."
trap 'rm -rf "$SCRATCH"' EXIT

problems=""
checked=0
deployed=""

add() { problems="${problems}${problems:+
}  $1"; }

# --- drift ------------------------------------------------------------------
while IFS= read -r name; do
    [ -n "$name" ] || continue
    live="$DEPLOY_DIR/$name"

    # THREE STATES AT A DEPLOY PATH, NOT TWO.
    #
    # This was `[ -e "$live" ] || continue`, and `-e` FOLLOWS a symlink — it is
    # false when the target is gone. So a hook deployed as a symlink whose target
    # had vanished was indistinguishable from a hook nobody ever deployed, and took
    # the same silent `continue`. It was never hashed, never named, never counted.
    #
    # Reproduced during adjudication against the real deployed hook set:
    #
    #   verify-gate.sh alone dangling → "checked 7 deployed file(s) … all match", 0
    #   all eight dangling            → "nothing deployed, nothing to check",      0
    #
    # Eight symlinks physically present at those paths, the commit gate not running,
    # and this script calling it clean. THAT IS INC-0014 EXACTLY — a branch checkout
    # dangled all eight global hook symlinks and the verification layer failed open,
    # silently, for about 102 minutes. The check written to catch silent deployment
    # failure could not see the silent deployment failure already in the record.
    #
    # `-L` is the distinction that was missing, and it must be tested BEFORE `-e`,
    # because a dangling link satisfies `-L` and fails every other test.
    #
    #   absent entirely   not deployed. A legitimate choice — controls 4 and 6.
    #   dangling symlink  DEPLOYED AND BROKEN. Never a legitimate state.
    #   present           compare it.
    #
    # Not counted in `checked`, because nothing was compared, and a count that
    # includes files it never read is the same lie in a smaller font.
    if [ ! -e "$live" ]; then
        if [ -L "$live" ]; then
            add "$name — DANGLING SYMLINK. Deployed, but its target does not exist, so this hook cannot run. This is not the same as 'not deployed'."
        fi
        continue
    fi

    deployed="${deployed}${name}
"
    checked=$((checked + 1))

    if [ ! -r "$live" ]; then
        add "$name — deployed but not readable, so it cannot be compared."
        continue
    fi

    # Read through a symlink deliberately: check-models.sh is deployed as one, and
    # what runs is the content at the far end.
    live_sum=$(sha1sum < "$live" | cut -d' ' -f1)

    # THE READ IS CHECKED, NOT INFERRED FROM ITS OUTPUT.
    #
    # This was `ship_sum=$(git show … | sha1sum | cut …)` guarded by
    # `[ -n "$ship_sum" ]`, and that guard could never fire. sha1sum of EMPTY input
    # is da39a3ee5e6b4b0d3255bfef95601890afd80709 — a fixed, non-empty, 40-character
    # string — so a failed `git show` produced a perfectly respectable-looking hash
    # and the emptiness test was true unconditionally.
    #
    # Reproduced end to end during adjudication rather than argued: with the shipped
    # blob deleted from the object store and a ZERO-BYTE file deployed, both sides
    # hashed to that same constant, they matched, and this script printed
    #
    #   check-deployment: checked 2 deployed file(s) … — all match.   EXIT 0
    #
    # on a file it had never read. That is the exact outcome the header above
    # forbids in capitals, produced by the guard written to prevent it.
    #
    # The lesson generalises past this line: a command's SUCCESS cannot be inferred
    # from the shape of what came out of the pipe, because every stage downstream of
    # the failure still runs and still produces well-formed output. Ask the command.
    #
    # A temporary file rather than a command substitution, because `$(…)` strips
    # trailing newlines — the hash of the captured text would differ from the hash
    # of the file for every hook ending in one, which is all of them.
    if ! git -C "$ROOT" show "$REF:${LIST_PATH}$name" > "$SCRATCH/ship" 2>/dev/null; then
        add "$name — COULD NOT READ the shipped copy at $REF, so no comparison was made. This is not a pass."
        continue
    fi
    ship_sum=$(sha1sum < "$SCRATCH/ship" | cut -d' ' -f1)

    if [ "$live_sum" != "$ship_sum" ]; then
        add "$name — DRIFT. Deployed bytes differ from $REF. The deployed copy is what enforces."
    fi
done <<EOF
$SHIPPED
EOF

# --- absence ----------------------------------------------------------------
# Siblings are resolved at runtime relative to the deployed file, so what matters
# is what sits beside the DEPLOYED copy, not beside the shipped one. Only siblings
# this kit actually ships are considered: a reference to anything else is not ours.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    live="$DEPLOY_DIR/$name"
    [ -r "$live" ] || continue

    needs=$(grep -h 'BASH_SOURCE' "$live" 2>/dev/null \
        | grep -oE '/[A-Za-z0-9._-]+\.sh' | sed 's|^/||' | sort -u)

    while IFS= read -r req; do
        [ -n "$req" ] || continue
        printf '%s\n' "$SHIPPED" | grep -qx "$req" || continue   # not ours to judge
        [ -e "$DEPLOY_DIR/$req" ] && continue
        add "$req — MISSING, and $name sources it. These hooks fall back rather than fail, so this does not error: it degrades in silence."
    done <<REQ
$needs
REQ
done <<EOF
$deployed
EOF

if [ -n "$problems" ]; then
    printf 'DEPLOYMENT DOES NOT MATCH %s — %s\n\n' "$REF" "$ROOT" >&2
    printf '%s\n\n' "$problems" >&2
    printf '  The copy under %s is the one that enforces. Refresh it:\n\n' "$DEPLOY_DIR" >&2
    printf "    git -C %s show %s:%s<name> > %s/<name>\n" "$ROOT" "$REF" "$LIST_PATH" "$DEPLOY_DIR" >&2
    printf '    chmod 755 %s/<name>\n\n' "$DEPLOY_DIR" >&2
    printf '  Deploy the closure, not the file: a sibling left behind does not error.\n' >&2
    exit 1
fi

if [ "$checked" -eq 0 ]; then
    printf 'check-deployment: %s holds none of this kit'"'"'s hooks — nothing deployed, nothing to check.\n' "$DEPLOY_DIR"
    exit 0
fi

printf 'check-deployment: checked %d deployed file(s) in %s against %s — all match.\n' \
    "$checked" "$DEPLOY_DIR" "$REF"
exit 0
